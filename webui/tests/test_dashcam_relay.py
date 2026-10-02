"""Dashcam rclone relay (api.dashcam_relay): rc client, remotes, copy jobs, the worker that
moves staged clips to every destination, streaming, and the rclone rcd supervisor.

A fake rc server (threaded http.server on 127.0.0.1) mirrors what a real rclone v1.75
answers - including Drive's non-interactive config questions. Run from webui/:
    TZ=UTC LANG=C.UTF-8 python3 -m pytest -o addopts="" -q -p no:cacheprovider tests/test_dashcam_relay.py
"""
from __future__ import annotations

import base64
import hashlib
import json
import logging
import os
import re
import socketserver
import stat
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote

import pytest

from api import dashcam_relay as dr
from api.dashcam_relay import Relay, RelayError, RelayUnavailable, RelayWorker, remote_path_for
from api.dashcam_store import DashcamStore

CAM = "A4-1234"
USER, PASS = "jc", "rc-secret-123"

DRIVE_QUESTIONS = [  # what rclone v1.75 asks after config/create for drive with a token
    ("client_id_warning", "config_shared_client_id"),
    ("*oauth-confirm,teamdrive,oauth,", "config_refresh_token"),
    ("teamdrive_ok", "config_change_team_drive"),
]


class FakeRclone:
    """State behind the fake rc server."""

    def __init__(self):
        self.requests = []          # (path, body)
        self.remotes = {}           # name -> {"type", "parameters"}
        self.files = {}             # "remote:dir/name" -> bytes
        self.jobs = {}              # id -> {"polls_left", "success", "error"}
        self.next_job = 1
        self.failing = set()        # remote names whose copies/lists fail
        self.polls_to_finish = 0
        self.extra_question = None  # a question no one should answer
        self.drive_step = {}
        self.stopped = []           # job ids passed to job/stop

    def restart(self):
        """What a fresh rclone rcd process looks like: no jobs, ids from 1 again."""
        self.jobs = {}
        self.next_job = 1

    def unrelated_finished_call(self):
        """rclone gives every rc call - sync ones too - a job id in the default group ``job/<id>``."""
        jid = self.next_job
        self.next_job += 1
        self.jobs[jid] = {"polls_left": 0, "success": True, "error": "", "group": f"job/{jid}"}
        return jid


def make_handler(fake: FakeRclone):
    auth_ok = "Basic " + base64.b64encode(f"{USER}:{PASS}".encode()).decode()

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _send(self, status, payload=None, raw=None, headers=None):
            body = raw if raw is not None else json.dumps(payload or {}).encode()
            self.send_response(status)
            for k, v in (headers or {"Content-Type": "application/json"}).items():
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.headers.get("Authorization") != auth_ok:
                return self._send(401, {"error": "unauthorized"})
            m = re.match(r"^/\[([^:\]]+):([^\]]*)\]/(.+)$", unquote(self.path))
            key = f"{m.group(1)}:{m.group(2).rstrip('/')}/{m.group(3)}" if m else None
            data = fake.files.get(key)
            if data is None:
                return self._send(404, {"error": "object not found"})
            rng = self.headers.get("Range")
            if rng:
                a, b = re.match(r"bytes=(\d+)-(\d*)", rng).groups()
                a, b = int(a), int(b) if b else len(data) - 1
                return self._send(206, raw=data[a:b + 1], headers={
                    "Content-Type": "video/mp4", "Accept-Ranges": "bytes",
                    "Content-Range": f"bytes {a}-{b}/{len(data)}"})
            return self._send(200, raw=data, headers={"Content-Type": "video/mp4", "Accept-Ranges": "bytes"})

        def do_POST(self):
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
            path = self.path.lstrip("/")
            fake.requests.append((path, body))
            if self.headers.get("Authorization") != auth_ok:
                return self._send(401, {"error": "unauthorized"})
            if path == "core/version":
                return self._send(200, {"version": "v1.75.1-fake"})
            if path == "config/create":
                params = body.get("parameters") or {}
                if params.get("host") == "fail.example":
                    # rclone echoes the input under "input"; the relay must never surface it.
                    return self._send(500, {"error": f"couldn't connect: pass={params.get('pass')}",
                                            "input": body, "status": 500})
                fake.remotes[body["name"]] = {"type": body["type"], "parameters": params}
                if body["type"] == "drive":
                    fake.drive_step[body["name"]] = 0
                    state, q = DRIVE_QUESTIONS[0]
                    return self._send(200, {"State": state, "Option": {"Name": q}, "Error": "", "Result": ""})
                return self._send(200, {"State": "", "Option": None, "Error": "", "Result": ""})
            if path == "config/update":
                opt = body.get("opt") or {}
                name = body["name"]
                step = fake.drive_step.get(name, 0)
                if opt.get("state") != DRIVE_QUESTIONS[step][0]:
                    return self._send(500, {"error": "bad state"})
                step += 1
                fake.drive_step[name] = step
                if fake.extra_question and step == 1:
                    return self._send(200, {"State": "x", "Option": {"Name": fake.extra_question}})
                if step < len(DRIVE_QUESTIONS):
                    state, q = DRIVE_QUESTIONS[step]
                    return self._send(200, {"State": state, "Option": {"Name": q}})
                return self._send(200, {"State": "", "Option": None, "Error": "", "Result": ""})
            if path == "config/delete":
                fake.remotes.pop(body["name"], None)
                return self._send(200, {})
            if path in ("operations/mkdir", "operations/list"):
                remote = body["fs"].split(":", 1)[0]
                if remote in fake.failing:
                    return self._send(500, {"error": "ssh: handshake failed: unable to authenticate"})
                return self._send(200, {"list": []} if path == "operations/list" else {})
            if path == "operations/copyfile":
                jid = fake.next_job
                fake.next_job += 1
                remote = body["dstFs"].split(":", 1)[0]
                ok = remote not in fake.failing
                if ok:
                    src = Path("/" + body["srcRemote"]).read_bytes()
                    fake.files[f"{body['dstFs'].rstrip('/')}/{body['dstRemote']}"] = src
                fake.jobs[jid] = {"polls_left": fake.polls_to_finish, "success": ok,
                                  "error": "" if ok else "ssh: handshake failed: unable to authenticate",
                                  "group": body.get("_group") or f"job/{jid}"}
                return self._send(200, {"jobid": jid, "executeId": "x"})
            if path == "job/status":
                job = fake.jobs.get(body.get("jobid"))
                if job is None:
                    return self._send(500, {"error": "job not found"})
                if job["polls_left"] > 0:
                    job["polls_left"] -= 1
                    return self._send(200, {"finished": False, "success": False, "error": "", "id": body["jobid"],
                                            "group": job["group"]})
                return self._send(200, {"finished": True, "success": job["success"], "error": job["error"],
                                        "id": body["jobid"], "group": job["group"]})
            if path == "job/stop":
                if body.get("jobid") not in fake.jobs:
                    return self._send(500, {"error": "job not found"})
                fake.stopped.append(body["jobid"])
                return self._send(200, {})
            return self._send(404, {"error": "unknown method"})

    return H


class QuickServer(ThreadingHTTPServer):
    """Skips http.server's reverse-DNS lookup of the bind address (seconds on some Macs)."""

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "127.0.0.1", self.server_address[1]


@pytest.fixture()
def fake():
    state = FakeRclone()
    server = QuickServer(("127.0.0.1", 0), make_handler(state))
    t = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
    t.start()
    state.url = f"http://127.0.0.1:{server.server_address[1]}"
    yield state
    server.shutdown()
    server.server_close()


@pytest.fixture()
def relay(fake, tmp_path):
    return Relay(tmp_path, url=fake.url, user=USER, password=PASS)


@pytest.fixture()
def store(tmp_path):
    return DashcamStore(tmp_path)


class Clock:
    def __init__(self, t=1_800_000_000.0):
        self.t = t

    def __call__(self):
        return self.t


def staged_clip(store, data=b"0123456789" * 10, name="2026_1001_154012_F.MP4", kind="normal"):
    path = f"/sd/Normal/F/{name}"
    store.apply_inventory(CAM, [{"path": path, "kind": kind, "lens": "front", "start": "2026-10-01T20:40:12Z",
                                 "duration": 60, "size": len(data)}])
    cid = DashcamStore.clip_id(CAM, path)
    up, err = store.create_upload(cid, len(data), hashlib.sha256(data).hexdigest(), 64)
    assert err is None
    for n in range(up["chunks"]):
        store.write_chunk(up["id"], n, data[n * 64:(n + 1) * 64])
    clip, err = store.complete_upload(up["id"])
    assert err is None, err
    return cid, up


def dest(store, name, remote, path="dashcam"):
    d = store.add_destination({"type": "sftp", "name": name, "path": path})
    return store.update_destination(d["id"], {"remote": remote})


# ── rc client ────────────────────────────────────────────────────────────────

def test_rc_sends_basic_auth_and_unwraps_errors(fake, relay, tmp_path):
    assert relay.rc("core/version")["version"] == "v1.75.1-fake"
    bad = Relay(tmp_path, url=fake.url, user=USER, password="wrong")
    with pytest.raises(RelayError) as e:
        bad.rc("core/version")
    assert "unauthorized" in str(e.value)
    with pytest.raises(RelayError, match="unknown method"):
        relay.rc("nope/nope")


# ── remotes ──────────────────────────────────────────────────────────────────

def test_create_sftp_remote_obscures_the_password(fake, relay):
    name = relay.create_remote("d_0000abcd", "sftp", {"host": "nas.local", "user": "pk", "port": 2222,
                                                      "password": "hunter2"})
    assert name == "jc_d_0000abcd"
    path, body = [r for r in fake.requests if r[0] == "config/create"][0]
    assert body == {"name": "jc_d_0000abcd", "type": "sftp",
                    "parameters": {"host": "nas.local", "user": "pk", "port": "2222", "pass": "hunter2"},
                    "opt": {"obscure": True, "nonInteractive": True}}


@pytest.mark.parametrize("dtype,port", [("ftp", "21"), ("smb", "445"), ("sftp", "22")])
def test_default_ports(fake, relay, dtype, port):
    relay.create_remote("d_0000abcd", dtype, {"host": "h", "user": "u"})
    assert fake.remotes["jc_d_0000abcd"]["parameters"]["port"] == port
    assert "pass" not in fake.remotes["jc_d_0000abcd"]["parameters"]


def test_create_drive_remote_answers_only_the_safe_questions(fake, relay):
    token = {"access_token": "ya29.x", "token_type": "Bearer", "refresh_token": "1//x", "expiry": "2026-10-01T10:00:00Z"}
    assert relay.create_remote("d_0000abcd", "drive", {"token": token}) == "jc_d_0000abcd"
    params = fake.remotes["jc_d_0000abcd"]["parameters"]
    assert params["scope"] == "drive" and json.loads(params["token"]) == token
    answers = [(b["opt"]["state"], b["opt"]["result"]) for p, b in fake.requests if p == "config/update"]
    # Keep the pasted token (never refresh: that starts a browser OAuth flow) and no shared drive.
    assert answers == [("client_id_warning", "true"), ("*oauth-confirm,teamdrive,oauth,", "false"),
                       ("teamdrive_ok", "false")]
    for _, b in fake.requests:
        if b.get("opt", {}).get("continue"):
            assert b["opt"]["nonInteractive"] is True


def test_create_drive_remote_with_own_client(fake, relay):
    relay.create_remote("d_0000abcd", "drive", {"token": "{\"access_token\":\"a\"}", "client_id": "cid",
                                                "client_secret": "csecret"})
    params = fake.remotes["jc_d_0000abcd"]["parameters"]
    assert params["client_id"] == "cid" and params["client_secret"] == "csecret"


def test_an_unexpected_config_question_aborts_and_removes_the_remote(fake, relay):
    fake.extra_question = "config_is_local"
    with pytest.raises(RelayError, match="config_is_local"):
        relay.create_remote("d_0000abcd", "drive", {"token": "{}"})
    assert "jc_d_0000abcd" not in fake.remotes
    assert not any(b.get("opt", {}).get("state") == "x" for _, b in fake.requests)


def test_bad_fields_are_rejected_before_rclone(fake, relay):
    for dtype, fields in [("sftp", {"user": "u"}), ("sftp", {"host": "h"}), ("drive", {}),
                          ("drive", {"token": "not json"}), ("webdav", {"host": "h", "user": "u"}),
                          ("local", {})]:
        with pytest.raises(ValueError):
            relay.create_remote("d_0000abcd", dtype, fields)
    assert fake.requests == []


def test_local_remotes_need_the_test_switch(fake, relay, monkeypatch):
    monkeypatch.setenv("JC_DASHCAM_ALLOW_LOCAL", "1")
    assert relay.create_remote("d_0000abcd", "local", {}) == "jc_d_0000abcd"


def test_password_never_reaches_errors_or_logs(fake, relay, caplog):
    caplog.set_level(logging.DEBUG)
    with pytest.raises(RelayError) as e:
        relay.create_remote("d_0000abcd", "sftp", {"host": "fail.example", "user": "u", "password": "hunter2"})
    assert "hunter2" not in str(e.value)
    assert "hunter2" not in caplog.text


def test_delete_and_test_remote(fake, relay):
    relay.create_remote("d_0000abcd", "sftp", {"host": "h", "user": "u"})
    assert relay.test_remote("jc_d_0000abcd", "dashcam") == (True, None)
    calls = [(p, b) for p, b in fake.requests if p.startswith("operations/")]
    assert calls == [("operations/mkdir", {"fs": "jc_d_0000abcd:dashcam", "remote": ""}),
                     ("operations/list", {"fs": "jc_d_0000abcd:dashcam", "remote": ""})]
    fake.failing.add("jc_d_0000abcd")
    ok, err = relay.test_remote("jc_d_0000abcd", "dashcam")
    assert ok is False and "authenticate" in err
    relay.delete_remote("jc_d_0000abcd")
    assert fake.remotes == {}


# ── paths, copies, jobs ──────────────────────────────────────────────────────

@pytest.mark.parametrize("base,expected", [
    ("dashcam", "dashcam/A4-1234/2026-10-01/normal/front/2026_1001_154012_F.MP4"),
    ("/volume1/dashcam/", "/volume1/dashcam/A4-1234/2026-10-01/normal/front/2026_1001_154012_F.MP4"),
    ("/", "/A4-1234/2026-10-01/normal/front/2026_1001_154012_F.MP4"),
    ("", "A4-1234/2026-10-01/normal/front/2026_1001_154012_F.MP4"),
])
def test_remote_path_for(base, expected):
    clip = {"camera_id": CAM, "start": "2026-10-01T20:40:12Z", "kind": "normal", "lens": "front",
            "name": "2026_1001_154012_F.MP4"}
    assert remote_path_for({"path": base}, clip) == expected


def test_front_and_rear_clips_with_the_same_name_never_collide():
    def clip(lens):
        return {"camera_id": CAM, "start": "2026-10-01T20:40:00Z", "kind": "normal", "lens": lens,
                "name": "20261001_154000.ts"}
    front, rear = remote_path_for({"path": "dashcam"}, clip("front")), remote_path_for({"path": "dashcam"}, clip("rear"))
    assert front == "dashcam/A4-1234/2026-10-01/normal/front/20261001_154000.ts"
    assert rear == "dashcam/A4-1234/2026-10-01/normal/rear/20261001_154000.ts"
    assert remote_path_for({"path": "dashcam"}, dict(clip(None))) == front   # no lens means front


def test_remote_path_for_sanitises_and_handles_no_start():
    clip = {"camera_id": "../evil/cam", "start": None, "kind": "event", "name": "../x.MP4"}
    p = remote_path_for({"path": "d"}, clip)
    assert ".." not in p.split("/") and p.startswith("d/") and "/undated/event/front/" in p


def test_start_copy_puts_the_folder_in_the_destination_fs(fake, relay, tmp_path):
    src = tmp_path / "u_1.part"
    src.write_bytes(b"abc")
    jid = relay.start_copy(str(src), "jc_d_1", "/volume1/dashcam/A4/2026-10-01/normal/A.MP4")
    body = [b for p, b in fake.requests if p == "operations/copyfile"][0]
    assert body == {"srcFs": "/", "srcRemote": str(src).lstrip("/"), "dstFs": "jc_d_1:/volume1/dashcam/A4/2026-10-01/normal",
                    "dstRemote": "A.MP4", "_async": True}
    assert relay.job_status(jid) == {"finished": True, "success": True, "error": None, "lost": False}
    # A job rclone doesn't know (it restarted, or the job expired) is lost, not failed.
    assert relay.job_status(999)["lost"] is True


def test_job_status_only_trusts_a_job_from_the_same_group(fake, relay, tmp_path):
    src = tmp_path / "u_1.part"
    src.write_bytes(b"abc")
    group = "dashcam/c_1/d_1/u_1"
    jid = relay.start_copy(str(src), "jc_d_1", "dashcam/A.MP4", group=group)
    assert [b for p, b in fake.requests if p == "operations/copyfile"][0]["_group"] == group
    assert relay.job_status(jid, group=group) == {"finished": True, "success": True, "error": None, "lost": False}
    # rclone restarted: the same id now names some other call that succeeded.
    fake.restart()
    assert fake.unrelated_finished_call() == jid
    status = relay.job_status(jid, group=group)
    assert status["lost"] is True and status["success"] is False


def test_open_stream_passes_range_through(fake, relay):
    fake.files["jc_d_1:dashcam/A4/2026-10-01/normal/A B.MP4"] = bytes(range(256)) * 4
    status, headers, body = relay.open_stream("jc_d_1", "dashcam/A4/2026-10-01/normal/A B.MP4", "bytes=0-99")
    assert status == 206 and headers["Content-Range"] == "bytes 0-99/1024"
    assert headers["Content-Type"] == "video/mp4" and headers["Content-Length"] == "100"
    assert b"".join(body) == (bytes(range(256)) * 4)[:100]
    status, headers, body = relay.open_stream("jc_d_1", "dashcam/missing.MP4", None)
    assert status == 404
    b"".join(body)


# ── worker ───────────────────────────────────────────────────────────────────

def test_worker_copies_a_staged_clip_and_releases_staging(fake, relay, store):
    d = dest(store, "NAS", "jc_d_nas")
    data = os.urandom(300)
    cid, up = staged_clip(store, data)
    fake.polls_to_finish = 1
    w = RelayWorker(lambda: store, relay, clock=Clock())
    w.tick()
    entry = store.get_clip(cid)["destinations"][d["id"]]
    assert entry["state"] == "uploading"
    assert entry["remote_path"] == "dashcam/A4-1234/2026-10-01/normal/front/2026_1001_154012_F.MP4"
    w.tick()  # still running
    assert store.get_clip(cid)["destinations"][d["id"]]["state"] == "uploading"
    w.tick()
    clip = store.get_clip(cid)
    assert clip["destinations"][d["id"]]["state"] == "done"
    assert clip["upload"]["state"] == "done"
    assert not store.staging_path(up["id"]).exists() and store.staged_clip_ids() == []
    assert fake.files["jc_d_nas:dashcam/A4-1234/2026-10-01/normal/front/2026_1001_154012_F.MP4"] == data


def test_a_failing_destination_backs_off_then_fails_while_the_other_completes(fake, relay, store):
    good = dest(store, "Drive", "jc_d_good")
    bad = dest(store, "NAS", "jc_d_bad")
    fake.failing.add("jc_d_bad")
    cid, up = staged_clip(store)
    clock = Clock()
    w = RelayWorker(lambda: store, relay, clock=clock)
    w.tick()  # both start
    w.tick()  # good done; bad fails once -> pending, retry in 30 s
    clip = store.get_clip(cid)
    assert clip["destinations"][good["id"]]["state"] == "done"
    entry = clip["destinations"][bad["id"]]
    assert entry["state"] == "pending" and entry["attempts"] == 1 and "authenticate" in entry["error"]
    assert entry["next_at"] == pytest.approx(clock.t + 30)
    starts = len([1 for p, _ in fake.requests if p == "operations/copyfile"])
    w.tick()  # inside the back-off: nothing new starts
    assert len([1 for p, _ in fake.requests if p == "operations/copyfile"]) == starts
    clock.t += 31
    w.tick(); w.tick()  # attempt 2 fails -> back-off 120 s
    entry = store.get_clip(cid)["destinations"][bad["id"]]
    assert entry["attempts"] == 2 and entry["next_at"] == pytest.approx(clock.t + 120)
    clock.t += 121
    w.tick(); w.tick()  # attempt 3 fails -> failed
    clip = store.get_clip(cid)
    entry = clip["destinations"][bad["id"]]
    assert entry["state"] == "failed" and entry["attempts"] == 3 and "authenticate" in entry["error"]
    assert clip["upload"]["state"] == "staged" and store.staging_path(up["id"]).exists()
    # Retry after the password is fixed, then everything completes and staging goes.
    fake.failing.discard("jc_d_bad")
    assert store.retry_destinations(cid) == 1
    w.tick(); w.tick()
    clip = store.get_clip(cid)
    assert clip["destinations"][bad["id"]]["state"] == "done" and clip["upload"]["state"] == "done"
    assert not store.staging_path(up["id"]).exists()


def test_uploading_without_a_job_after_restart_goes_back_to_pending(fake, relay, store):
    d = dest(store, "NAS", "jc_d_nas")
    cid, _ = staged_clip(store)
    fake.polls_to_finish = 5
    RelayWorker(lambda: store, relay, clock=Clock()).tick()
    assert store.get_clip(cid)["destinations"][d["id"]]["state"] == "uploading"
    fake.polls_to_finish = 0
    fresh = RelayWorker(lambda: store, relay, clock=Clock())  # a new process knows no job ids
    fresh.tick()
    assert store.get_clip(cid)["destinations"][d["id"]]["state"] == "uploading"
    fresh.tick()
    assert store.get_clip(cid)["destinations"][d["id"]]["state"] == "done"


def copies(fake):
    return [b for p, b in fake.requests if p == "operations/copyfile"]


def test_an_old_job_id_after_an_rclone_restart_never_marks_the_clip_done(fake, relay, store):
    d = dest(store, "NAS", "jc_d_nas")
    cid, up = staged_clip(store)
    fake.polls_to_finish = 10 ** 6            # the copy is slow (or the host is a black hole)
    w = RelayWorker(lambda: store, relay, clock=Clock())
    w.tick()
    assert store.get_clip(cid)["destinations"][d["id"]]["state"] == "uploading"
    # rclone rcd restarts; its first rc call reuses the copy's job id and finishes fine.
    fake.restart()
    fake.unrelated_finished_call()
    w.tick()
    clip = store.get_clip(cid)
    entry = clip["destinations"][d["id"]]
    assert entry["state"] == "uploading" and entry["attempts"] == 0   # lost: copied again, no attempt counted
    assert clip["upload"]["state"] == "staged" and store.staging_path(up["id"]).exists()
    assert len(copies(fake)) == 2
    for job in fake.jobs.values():
        job["polls_left"] = 0
    w.tick()
    assert store.get_clip(cid)["upload"]["state"] == "done"


def test_a_job_from_an_older_rclone_generation_is_lost_without_asking(fake, relay, store):
    d = dest(store, "NAS", "jc_d_nas")
    cid, _ = staged_clip(store)
    fake.polls_to_finish = 10 ** 6
    w = RelayWorker(lambda: store, relay, clock=Clock())
    w.tick()
    first = copies(fake)[0]
    relay.generation += 1                     # what a respawn of rclone rcd does
    polls = len([1 for p, _ in fake.requests if p == "job/status"])
    w.tick()
    assert len([1 for p, _ in fake.requests if p == "job/status"]) == polls
    entry = store.get_clip(cid)["destinations"][d["id"]]
    assert entry["state"] == "uploading" and entry["attempts"] == 0
    assert len(copies(fake)) == 2 and copies(fake)[1]["_group"] == first["_group"]


def test_a_copy_of_an_older_upload_never_completes_the_new_one(fake, relay, store):
    d = dest(store, "NAS", "jc_d_nas")
    cid, old = staged_clip(store)
    fake.polls_to_finish = 10 ** 6
    w = RelayWorker(lambda: store, relay, clock=Clock())
    w.tick()
    old_job = max(fake.jobs)
    # The phone re-sends the clip (new bytes): a new upload replaces the staged one.
    data = b"9876543210" * 10
    up, err = store.create_upload(cid, len(data), hashlib.sha256(data).hexdigest(), 64)
    assert err is None and up["id"] != old["id"]
    for n in range(up["chunks"]):
        store.write_chunk(up["id"], n, data[n * 64:(n + 1) * 64])
    assert store.complete_upload(up["id"])[1] is None
    fake.jobs[old_job]["polls_left"] = 0      # the old copy finishes
    w.tick()
    clip = store.get_clip(cid)
    assert clip["upload"]["upload_id"] == up["id"] and clip["upload"]["state"] == "staged"
    assert clip["destinations"][d["id"]]["state"] == "uploading"
    assert copies(fake)[-1]["srcRemote"] == str(store.staging_path(up["id"])).lstrip("/")
    # ...and even when a stale finish slips through, the store ignores it.
    assert store.set_destination_state(cid, d["id"], "done", upload_id=old["id"]) is None
    assert store.get_clip(cid)["destinations"][d["id"]]["state"] == "uploading"


def test_deleting_a_destination_mid_copy_frees_its_job_slots(fake, relay, store):
    bad = dest(store, "Wrong folder", "jc_d_bad")
    fake.polls_to_finish = 10 ** 6
    w = RelayWorker(lambda: store, relay, clock=Clock())
    cids = [staged_clip(store, os.urandom(100), name=f"2026_1001_15400{i}_F.MP4")[0]
            for i in range(dr.MAX_ACTIVE_JOBS)]
    w.tick()
    assert len(w._jobs) == dr.MAX_ACTIVE_JOBS
    bad_jobs = sorted(fake.jobs)
    store.delete_destination(bad["id"])
    good = dest(store, "NAS", "jc_d_good")
    fake.polls_to_finish = 0
    w.tick(); w.tick()
    assert all(store.get_clip(c)["upload"]["state"] == "done" for c in cids)
    assert not any(k[1] == bad["id"] for k in w._jobs)
    assert sorted(fake.stopped) == bad_jobs   # best effort: the abandoned copies are stopped
    assert all(store.get_clip(c)["destinations"][good["id"]]["state"] == "done" for c in cids)


def test_disabling_a_destination_or_dropping_the_upload_frees_its_job(fake, relay, store):
    a = dest(store, "A", "jc_d_a")
    b = dest(store, "B", "jc_d_b")
    fake.polls_to_finish = 10 ** 6
    w = RelayWorker(lambda: store, relay, clock=Clock())
    cid, _ = staged_clip(store)
    w.tick()
    assert {k[1] for k in w._jobs} == {a["id"], b["id"]}
    store.update_destination(b["id"], {"enabled": False})
    w.tick()
    assert {k[1] for k in w._jobs} == {a["id"]}
    # The next camera listing shows a new size: the staged upload is thrown away.
    store.apply_inventory(CAM, [{"path": store.get_clip(cid)["path"], "kind": "normal", "lens": "front",
                                 "start": "2026-10-01T20:40:12Z", "duration": 60, "size": 999}])
    w.tick()
    assert w._jobs == {}
    assert len(fake.stopped) == 2


def test_a_destination_added_later_gets_the_staged_clips(fake, relay, store):
    slow = dest(store, "Drive", "jc_d_slow")
    fake.polls_to_finish = 10 ** 6
    cid, _ = staged_clip(store)
    w = RelayWorker(lambda: store, relay, clock=Clock())
    w.tick()
    assert store.get_clip(cid)["destinations"][slow["id"]]["state"] == "uploading"
    d = dest(store, "NAS", "jc_d_nas")
    fake.polls_to_finish = 0
    w.tick(); w.tick()
    clip = store.get_clip(cid)
    assert clip["destinations"][d["id"]]["state"] == "done"
    assert clip["upload"]["state"] == "staged"            # still waiting for the slow one


@pytest.mark.parametrize("how", ["delete", "disable", "kinds"])
def test_a_staged_clip_no_destination_takes_any_more_goes_back_to_the_phone(fake, relay, store, how):
    d = dest(store, "NAS", "jc_d_nas")
    fake.polls_to_finish = 10 ** 6
    cid, up = staged_clip(store)
    w = RelayWorker(lambda: store, relay, clock=Clock())
    w.tick()
    if how == "delete":
        store.delete_destination(d["id"])
    elif how == "disable":
        store.update_destination(d["id"], {"enabled": False})
    else:
        store.update_destination(d["id"], {"kinds": ["event"]})
    w.tick()
    clip = store.get_clip(cid)
    # Not uploaded: the upload is reset so the phone keeps its copy and sends it again later.
    assert clip["upload"]["state"] == "none" and clip["destinations"] == {}
    assert store.is_uploaded(clip) is False and store.list_clips(state="uploaded")[0] == []
    assert not store.staging_path(up["id"]).exists() and store.staging_bytes() == 0
    w.tick()
    assert w._jobs == {}


def test_worker_idles_without_rclone(store, tmp_path, monkeypatch):
    dest(store, "NAS", "jc_d_nas")
    staged_clip(store)
    monkeypatch.delenv("JC_RCLONE_BIN", raising=False)
    monkeypatch.setenv("PATH", str(tmp_path / "empty"))
    w = RelayWorker(lambda: store, Relay(tmp_path), clock=Clock())
    w.tick()  # must not raise
    clip = store.get_clip(store.staged_clip_ids()[0])
    assert all(e["state"] == "pending" for e in clip["destinations"].values())


def test_worker_does_not_touch_rclone_when_nothing_is_staged(store, tmp_path):
    class Boom:
        def __getattr__(self, name):
            raise AssertionError("relay used")
    RelayWorker(lambda: store, Boom(), clock=Clock()).tick()


# ── supervisor ───────────────────────────────────────────────────────────────

def test_missing_binary_is_relay_unavailable(tmp_path, monkeypatch):
    monkeypatch.delenv("JC_RCLONE_BIN", raising=False)
    monkeypatch.setenv("PATH", str(tmp_path / "empty"))
    with pytest.raises(RelayUnavailable, match="not installed"):
        Relay(tmp_path).ensure_running()
    monkeypatch.setenv("JC_RCLONE_BIN", str(tmp_path / "nope"))
    with pytest.raises(RelayUnavailable):
        Relay(tmp_path).rc("core/version")


FAKE_RCLONE = r'''#!{python}
import base64, json, os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
args = sys.argv[1:]
with open(os.environ["FAKE_RCLONE_RECORD"], "a") as f:
    f.write(json.dumps({{"argv": args, "pid": os.getpid(), "has_env_pass": bool(os.environ.get("RCLONE_RC_PASS"))}}) + "\n")
if os.environ.get("FAKE_RCLONE_EXIT"):
    sys.exit(int(os.environ["FAKE_RCLONE_EXIT"]))
host, port = args[args.index("--rc-addr") + 1].rsplit(":", 1)
want = "Basic " + base64.b64encode((os.environ["RCLONE_RC_USER"] + ":" + os.environ["RCLONE_RC_PASS"]).encode()).decode()
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path == "/slow/call":
            time.sleep(2)             # e.g. operations/list on an unreachable SFTP host
        ok = self.headers.get("Authorization") == want
        body = json.dumps({{"version": "fake", "pid": os.getpid()}} if ok else {{"error": "unauthorized"}}).encode()
        self.send_response(200 if ok else 401)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
ThreadingHTTPServer((host, int(port)), H).serve_forever()
'''


@pytest.fixture()
def fake_rclone_bin(tmp_path, monkeypatch):
    exe = tmp_path / "rclone"
    exe.write_text(FAKE_RCLONE.format(python=sys.executable))
    exe.chmod(exe.stat().st_mode | stat.S_IEXEC)
    record = tmp_path / "record.jsonl"
    monkeypatch.setenv("FAKE_RCLONE_RECORD", str(record))
    monkeypatch.setenv("JC_RCLONE_BIN", str(exe))
    return record


def test_a_slow_call_times_out_without_killing_rclone(fake_rclone_bin, tmp_path, monkeypatch):
    r = Relay(tmp_path / "state")
    try:
        pid = r.rc("core/version")["pid"]
        monkeypatch.setattr(dr, "RC_TIMEOUT_S", 0.5)
        with pytest.raises(RelayError, match="timed out"):
            r.rc("slow/call")
        # Same process, same generation: the copies it is running are still there.
        assert r.rc("core/version")["pid"] == pid and r.generation == 1
        assert len(fake_rclone_bin.read_text().splitlines()) == 1
    finally:
        r.shutdown()


def test_testing_a_destination_waits_longer_than_rclones_connect_timeout(fake, relay):
    seen = []
    post = relay._post

    def spy(method, params, timeout=None):
        seen.append((method, timeout))
        return post(method, params, timeout)

    relay._post = spy
    relay.test_remote("jc_d_1", "dashcam")
    assert [m for m, _ in seen] == ["operations/mkdir", "operations/list"]
    assert all(t == dr.TEST_TIMEOUT_S for _, t in seen) and dr.TEST_TIMEOUT_S > 60


def test_rclone_that_will_not_start_is_retried_at_most_every_30_s(fake_rclone_bin, tmp_path, monkeypatch):
    monkeypatch.setenv("FAKE_RCLONE_EXIT", "3")
    r = Relay(tmp_path / "state")
    with pytest.raises(RelayUnavailable, match="exited with code 3"):
        r.rc("core/version")
    with pytest.raises(RelayUnavailable, match="exited with code 3"):
        r.rc("core/version")
    assert len(fake_rclone_bin.read_text().splitlines()) == 1     # no second spawn yet
    assert dr.RESPAWN_BACKOFF_S == 30
    monkeypatch.setattr(dr, "RESPAWN_BACKOFF_S", 0)
    with pytest.raises(RelayUnavailable):
        r.rc("core/version")
    assert len(fake_rclone_bin.read_text().splitlines()) == 2


def test_supervisor_spawns_restarts_and_keeps_the_password_off_argv(fake_rclone_bin, tmp_path):
    record = fake_rclone_bin
    r = Relay(tmp_path / "state")
    try:
        first = r.rc("core/version")["pid"]
        runs = [json.loads(line) for line in record.read_text().splitlines()]
        argv = runs[0]["argv"]
        assert argv[0] == "rcd" and "--rc-serve" in argv
        assert argv[argv.index("--config") + 1] == str(tmp_path / "state" / "dashcam" / "rclone.conf")
        assert argv[argv.index("--rc-addr") + 1].startswith("127.0.0.1:")
        assert runs[0]["has_env_pass"] and "--rc-pass" not in argv and "--rc-user" not in argv
        assert not any(re.fullmatch(r"[0-9a-f]{32}", a) for a in argv)
        # Finished jobs stay answerable long after a slow tick would poll them.
        assert argv[argv.index("--rc-job-expire-duration") + 1] == "6h"
        assert r.generation == 1
        os.kill(first, 9)
        time.sleep(0.2)
        second = r.rc("core/version")["pid"]
        assert second != first
        assert r.generation == 2              # job ids from the first process mean nothing now
    finally:
        r.shutdown()
