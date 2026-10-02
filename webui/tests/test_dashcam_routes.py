"""Dashcam REST API (api.dashcam_routes): the JSON dispatcher, raw chunk/thumbnail POSTs,
and the binary GETs (thumbnail, Range stream, GPX).

A real DashcamStore on tmp_path, a stub relay, and a fake request handler. Run from webui/:
    TZ=UTC LANG=C.UTF-8 python3 -m pytest -o addopts="" -q -p no:cacheprovider tests/test_dashcam_routes.py
"""
from __future__ import annotations

import hashlib
import io
import json
import xml.etree.ElementTree as ET

import pytest

from api import dashcam_routes as dr
from api.dashcam_relay import RelayError, RelayUnavailable
from api.dashcam_store import DashcamStore, now_iso

CAM = "A4-1234"
T0 = 1790000000.0
JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 64 + b"\xff\xd9"
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64
CHUNK = 8


class StubRelay:
    def __init__(self):
        self.calls = []
        self.fail = None
        self.test_result = (True, None)
        self.stream = (206, {"Content-Type": "video/mp4", "Content-Range": "bytes 0-9/100", "Content-Length": "10",
                             "Accept-Ranges": "bytes"}, [b"01234", b"56789"])

    def binary(self):
        return "/usr/local/bin/rclone"

    def create_remote(self, dest_id, dtype, fields):
        self.calls.append(("create", dest_id, dtype, dict(fields)))
        if self.fail:
            raise self.fail
        return "jc_" + dest_id

    def delete_remote(self, remote):
        self.calls.append(("delete", remote))

    def test_remote(self, remote, path):
        self.calls.append(("test", remote, path))
        if isinstance(self.test_result, Exception):
            raise self.test_result
        return self.test_result

    def open_stream(self, remote, remote_path, range_header):
        self.calls.append(("stream", remote, remote_path, range_header))
        status, headers, blocks = self.stream
        return status, dict(headers), iter(blocks)


class FakeHandler:
    """Just enough of BaseHTTPRequestHandler for j(), _serve_file_bytes and the raw readers."""

    def __init__(self, headers=None, body=b""):
        self.headers = dict(headers or {})
        if body and "Content-Length" not in self.headers:
            self.headers["Content-Length"] = str(len(body))
        self.rfile = io.BytesIO(body)
        self.wfile = io.BytesIO()
        self.status = None
        self.sent = {}
        self.close_connection = False

    def send_response(self, code, message=None):
        self.status = code

    def send_header(self, key, value):
        self.sent[key] = value

    def end_headers(self):
        pass

    def json(self):
        return json.loads(self.wfile.getvalue())


@pytest.fixture(autouse=True)
def small_chunks(monkeypatch):
    monkeypatch.setattr(dr, "CHUNK_SIZE", CHUNK)
    monkeypatch.setattr(dr, "_rebuild_last", {})
    monkeypatch.setattr(dr, "_rebuild_timers", {})


@pytest.fixture()
def store(tmp_path):
    return DashcamStore(tmp_path)


@pytest.fixture()
def relay():
    return StubRelay()


@pytest.fixture()
def H(store, relay):
    def call(method, path, body=None, query=None):
        return dr.handle_dashcam_request(method, path, query or {}, body, store, relay=relay)
    return call


def inventory(H, *names, size=20, kind="normal", start=None):
    clips = [{"path": f"/sd/Normal/F/{n}", "kind": kind, "lens": "front",
              "start": start or "2026-10-01T20:40:12Z", "duration": 60, "size": size} for n in names]
    status, payload = H("POST", "/inventory", {"camera_id": CAM, "clips": clips})
    assert status == 200, payload
    return [row["id"] for row in payload["clips"]]


def add_dest(H, **extra):
    status, payload = H("POST", "/destinations", {"type": "sftp", "name": "NAS", "host": "h", "user": "u", **extra})
    assert status == 200, payload
    return payload["destination"]


def chunk(store, upload_id, n, data):
    h = FakeHandler({"Content-Type": "application/octet-stream"}, data)
    assert dr.handle_dashcam_raw_post(h, f"/api/dashcam/uploads/{upload_id}/chunk?n={n}", store) is True
    return h


def upload(H, store, cid, data):
    status, up = H("POST", "/uploads", {"clip_id": cid, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()})
    assert status == 200, up
    for n in range(up["chunks"]):
        assert chunk(store, up["upload_id"], n, data[n * CHUNK:(n + 1) * CHUNK]).status == 200
    status, done = H("POST", f"/uploads/{up['upload_id']}/complete", {})
    assert status == 200, done
    return up


# ── state, cameras, settings ─────────────────────────────────────────────────

def test_state(H):
    status, payload = H("GET", "/state")
    assert status == 200
    assert set(payload) >= {"cameras", "settings", "destinations", "counts", "staging"}
    assert payload["relay"] == {"installed": True}


def test_cameras(H):
    status, payload = H("POST", "/cameras", {"id": CAM, "model": "A4", "wifi_password": "12345678"})
    assert status == 200 and payload["camera"]["model"] == "A4" and "wifi_password" not in payload["camera"]
    status, payload = H("POST", "/cameras", {"camera": {"id": CAM, "firmware": "2"}})
    assert payload["camera"]["firmware"] == "2" and payload["camera"]["model"] == "A4"
    assert H("POST", "/cameras", {"model": "x"})[0] == 400


def test_settings(H):
    status, payload = H("POST", "/settings", {"rules": {"normal": "all"}})
    assert status == 200 and payload["settings"]["rules"]["normal"] == "all"
    status, payload = H("POST", "/settings", {"normal_when": "parked"})  # flat rule keys work too
    assert status == 200 and payload["settings"]["rules"]["normal_when"] == "parked"
    status, payload = H("POST", "/settings", {"rules": {"normal": "rear"}})
    assert status == 400 and payload["ok"] is False and payload["errors"]


# ── inventory, clips ─────────────────────────────────────────────────────────

def test_inventory(H, store):
    status, payload = H("POST", "/inventory", {"camera_id": CAM, "clips": [
        {"path": "/sd/a.MP4", "kind": "normal", "lens": "front", "start": "2026-10-01T20:40:12Z", "duration": 60,
         "size": 10},
        {"path": "/sd/bad.MP4", "kind": "nope", "size": 1}]})
    assert status == 200 and payload["ok"] is True
    assert [r["path"] for r in payload["clips"]] == ["/sd/a.MP4"] and len(payload["warnings"]) == 1
    assert set(payload["clips"][0]) >= {"id", "path", "has_gps", "has_thumb", "uploaded", "size_stable"}
    assert store.cameras()[0]["id"] == CAM
    assert H("POST", "/inventory", {"clips": []})[0] == 400
    assert H("POST", "/inventory", {"camera_id": CAM, "clips": "x"})[0] == 400


def test_list_and_get_clips(H, store):
    ids = inventory(H, "a.MP4", "b.MP4")
    inventory(H, "e.MP4", kind="event")
    status, payload = H("GET", "/clips", query={"kind": ["normal"], "limit": ["1"]})
    assert status == 200 and len(payload["clips"]) == 1 and payload["next"]
    assert "uploaded" in payload["clips"][0]
    status, payload = H("GET", "/clips", query={"kind": ["normal"], "limit": ["1"], "cursor": [payload["next"]]})
    assert len(payload["clips"]) == 1 and payload["next"] is None
    assert H("GET", "/clips", query={"state": ["weird"]})[0] == 400
    assert H("GET", "/clips", query={"kind": ["weird"]})[0] == 400
    assert H("GET", "/clips", query={"limit": ["x"]})[0] == 400
    status, payload = H("GET", f"/clips/{ids[0]}")
    assert status == 200 and payload["clip"]["id"] == ids[0] and payload["fixes"] == []
    assert payload["destinations"] == []
    assert H("GET", "/clips/c_00000000000000000000")[0] == 404


def test_gps_rebuilds_drives(H, store):
    a, b = inventory(H, "a.MP4", "b.MP4")
    fixes = [[T0 + i, 30.0 + i * 1e-4, -97.7, 11.0, 0.0] for i in range(60)]
    status, payload = H("POST", f"/clips/{a}/gps", {"fixes": fixes + [[T0, 0, 0, 0, 0]]})
    assert status == 200 and payload["ok"] is True and payload["has_gps"] is True and payload["warnings"]
    status, payload = H("GET", "/drives")
    assert status == 200 and len(payload["drives"]) == 1
    drive = payload["drives"][0]
    assert drive["clip_ids"] == [a] and drive["distance_m"] > 0
    status, payload = H("GET", f"/drives/{drive['id']}")
    assert status == 200 and len(payload["polyline"]) == 60 and payload["clips"][0]["id"] == a
    assert H("GET", "/drives", query={"from": [now_iso(T0 + 3600)]})[1]["drives"] == []
    assert H("GET", "/drives/dr_1_nope")[0] == 404
    assert H("POST", "/clips/c_00000000000000000000/gps", {"fixes": []})[0] == 404
    assert H("POST", f"/clips/{b}/gps", {"fixes": "x"})[0] == 400
    assert store.get_clip(a)["drive_id"] == drive["id"]


def test_phone_state(H, store):
    (cid,) = inventory(H, "a.MP4")
    status, payload = H("POST", f"/clips/{cid}/phone", {"state": "local"})
    assert status == 200 and payload["ok"] is True and store.get_clip(cid)["phone"]["state"] == "local"
    assert H("POST", f"/clips/{cid}/phone", {"state": "lost"})[0] == 400
    assert H("POST", "/clips/c_00000000000000000000/phone", {"state": "local"})[0] == 404


def test_retry_resets_failed_destinations(H, store):
    status, d = H("POST", "/destinations", {"type": "sftp", "name": "NAS", "host": "h", "user": "u", "password": "p"})
    (cid,) = inventory(H, "a.MP4", size=10)
    upload(H, store, cid, b"0123456789")
    store.set_destination_state(cid, d["destination"]["id"], "failed", "bad password", attempts=3)
    status, payload = H("POST", f"/clips/{cid}/retry", {})
    assert status == 200 and payload == {"ok": True, "requeued": 1}
    entry = store.get_clip(cid)["destinations"][d["destination"]["id"]]
    assert entry["state"] == "pending" and entry["attempts"] == 0 and entry["error"] is None
    assert H("POST", "/clips/c_00000000000000000000/retry", {})[0] == 404


# ── uploads ──────────────────────────────────────────────────────────────────

def test_chunked_upload_resumes_from_received(H, store):
    add_dest(H)
    data = bytes(range(20))
    (cid,) = inventory(H, "a.MP4", size=20)
    sha = hashlib.sha256(data).hexdigest()
    status, up = H("POST", "/uploads", {"clip_id": cid, "size": 20, "sha256": sha})
    assert status == 200 and up["chunk_size"] == CHUNK and up["chunks"] == 3 and up["received"] == []
    assert up["complete"] is False
    assert chunk(store, up["upload_id"], 0, data[0:8]).json() == {"ok": True, "received": [0], "chunks": 3}
    assert chunk(store, up["upload_id"], 2, data[16:20]).json()["received"] == [0, 2]
    # Wi-Fi dropped: the phone asks again and is told what the server already has.
    status, again = H("POST", "/uploads", {"clip_id": cid, "size": 20, "sha256": sha})
    assert again["upload_id"] == up["upload_id"] and again["received"] == [0, 2]
    status, missing = H("POST", f"/uploads/{up['upload_id']}/complete", {})
    assert status == 400 and missing["error"] == "missing_chunks" and missing["missing"] == [1]
    chunk(store, up["upload_id"], 1, data[8:16])
    assert H("GET", f"/uploads/{up['upload_id']}")[1]["received"] == [0, 1, 2]
    status, done = H("POST", f"/uploads/{up['upload_id']}/complete", {})
    assert status == 200 and done["clip"]["upload"]["state"] == "staged"
    status, again = H("POST", "/uploads", {"clip_id": cid, "size": 20, "sha256": sha})
    assert status == 200 and again["complete"] is True


def test_upload_after_release_is_already_uploaded(H, store):
    status, d = H("POST", "/destinations", {"type": "sftp", "name": "NAS", "host": "h", "user": "u"})
    (cid,) = inventory(H, "a.MP4", size=10)
    upload(H, store, cid, b"0123456789")
    store.set_destination_state(cid, d["destination"]["id"], "done")
    store.release_staging_if_done(cid)
    status, payload = H("POST", "/uploads", {"clip_id": cid, "size": 10,
                                             "sha256": hashlib.sha256(b"0123456789").hexdigest()})
    assert status == 200 and payload["complete"] is True and payload["already_uploaded"] is True
    assert payload["upload_id"] is None


def test_upload_without_a_destination_for_the_kind_is_409(H, store):
    (cid,) = inventory(H, "a.MP4", size=10)
    body = {"clip_id": cid, "size": 10, "sha256": hashlib.sha256(b"0123456789").hexdigest()}
    assert H("POST", "/uploads", body) == (409, {"ok": False, "error": "no_destination"})
    add_dest(H, kinds=["event"])
    assert H("POST", "/uploads", body) == (409, {"ok": False, "error": "no_destination"})
    add_dest(H, kinds=["normal"])
    assert H("POST", "/uploads", body)[0] == 200


def test_upload_errors(H, store):
    (cid,) = inventory(H, "a.MP4", size=20)
    assert H("POST", "/uploads", {"clip_id": "c_00000000000000000000", "size": 1, "sha256": "a" * 64})[0] == 404
    assert H("POST", "/uploads", {"clip_id": cid, "size": "big", "sha256": "a" * 64})[0] == 400
    assert H("POST", "/uploads", {"clip_id": cid, "size": 20})[0] == 400
    assert H("GET", "/uploads/u_0000000000000000")[0] == 404
    assert H("POST", "/uploads/u_0000000000000000/complete", {})[0] == 404


def test_sha256_mismatch_is_400(H, store):
    add_dest(H)
    (cid,) = inventory(H, "a.MP4", size=10)
    status, up = H("POST", "/uploads", {"clip_id": cid, "size": 10, "sha256": "b" * 64})
    chunk(store, up["upload_id"], 0, b"01234567")
    chunk(store, up["upload_id"], 1, b"89")
    status, payload = H("POST", f"/uploads/{up['upload_id']}/complete", {})
    assert status == 400 and payload["error"] == "sha256_mismatch"


def test_staging_full_is_507_and_too_large_is_413(H, store):
    add_dest(H)
    store.update_settings({"staging_cap_bytes": 256 * 1024 * 1024})
    a, b, c = inventory(H, "a.MP4", "b.MP4", "c.MP4")
    mib = 1024 * 1024
    assert H("POST", "/uploads", {"clip_id": a, "size": 200 * mib, "sha256": "a" * 64})[0] == 200
    status, payload = H("POST", "/uploads", {"clip_id": b, "size": 100 * mib, "sha256": "b" * 64})
    assert status == 507 and payload == {"ok": False, "error": "staging_full", "retry_after": 60}
    status, payload = H("POST", "/uploads", {"clip_id": c, "size": 300 * mib, "sha256": "c" * 64})
    assert status == 413 and payload["error"] == "too_large"


def test_low_free_disk_is_507(H, store, monkeypatch):
    from api import dashcam_store
    add_dest(H)
    (cid,) = inventory(H, "a.MP4")
    monkeypatch.setattr(dashcam_store, "DISK_RESERVE_BYTES", 1 << 62)
    status, payload = H("POST", "/uploads", {"clip_id": cid, "size": 20, "sha256": "a" * 64})
    assert status == 507 and payload == {"ok": False, "error": "staging_full", "retry_after": 60}


def test_raw_chunk_limits(store, H):
    add_dest(H)
    (cid,) = inventory(H, "a.MP4", size=20)
    status, up = H("POST", "/uploads", {"clip_id": cid, "size": 20, "sha256": "a" * 64})
    big = FakeHandler({}, b"x" * (CHUNK + 1))
    assert dr.handle_dashcam_raw_post(big, f"/api/dashcam/uploads/{up['upload_id']}/chunk?n=0", store)
    assert big.status == 413 and big.close_connection is True
    short = FakeHandler({}, b"x" * 3)
    dr.handle_dashcam_raw_post(short, f"/api/dashcam/uploads/{up['upload_id']}/chunk?n=0", store)
    assert short.status == 400 and short.json()["error"] == "bad_chunk_length"
    no_n = FakeHandler({}, b"x" * 8)
    dr.handle_dashcam_raw_post(no_n, f"/api/dashcam/uploads/{up['upload_id']}/chunk", store)
    assert no_n.status == 400
    gone = FakeHandler({}, b"x" * 8)
    dr.handle_dashcam_raw_post(gone, "/api/dashcam/uploads/u_0000000000000000/chunk?n=0", store)
    assert gone.status == 404
    no_len = FakeHandler({}, b"")
    dr.handle_dashcam_raw_post(no_len, f"/api/dashcam/uploads/{up['upload_id']}/chunk?n=0", store)
    assert no_len.status == 411
    truncated = FakeHandler({"Content-Length": "8"}, b"x" * 5)
    dr.handle_dashcam_raw_post(truncated, f"/api/dashcam/uploads/{up['upload_id']}/chunk?n=0", store)
    assert truncated.status == 400
    other = FakeHandler({}, b"{}")
    assert dr.handle_dashcam_raw_post(other, "/api/dashcam/inventory", store) is False
    assert other.rfile.tell() == 0  # a JSON route's body is left for read_body


# ── thumbnails ───────────────────────────────────────────────────────────────

def test_thumbnail_upload_and_get(store, H):
    (cid,) = inventory(H, "a.MP4")
    png = FakeHandler({"Content-Type": "image/png"}, PNG)
    dr.handle_dashcam_raw_post(png, f"/api/dashcam/clips/{cid}/thumb", store)
    assert png.status == 400
    big = FakeHandler({"Content-Type": "image/jpeg"}, b"\xff\xd8" + b"\x00" * (512 * 1024))
    dr.handle_dashcam_raw_post(big, f"/api/dashcam/clips/{cid}/thumb", store)
    assert big.status == 413
    ok = FakeHandler({"Content-Type": "image/jpeg"}, JPEG)
    dr.handle_dashcam_raw_post(ok, f"/api/dashcam/clips/{cid}/thumb", store)
    assert ok.status == 200 and ok.json() == {"ok": True}
    get = FakeHandler()
    assert dr.handle_dashcam_binary_get(get, f"/clips/{cid}/thumb", store) is True
    assert get.status == 200 and get.sent["Content-Type"] == "image/jpeg" and get.wfile.getvalue() == JPEG
    missing = FakeHandler()
    dr.handle_dashcam_binary_get(missing, "/clips/c_00000000000000000000/thumb", store)
    assert missing.status == 404


# ── streaming ────────────────────────────────────────────────────────────────

def test_stream_from_staging_honours_range(store, H, relay):
    add_dest(H)
    data = bytes(range(200))
    (cid,) = inventory(H, "a.MP4", size=200)
    upload(H, store, cid, data)
    h = FakeHandler({"Range": "bytes=0-99"})
    assert dr.handle_dashcam_binary_get(h, f"/clips/{cid}/stream", store, relay=relay) is True
    assert h.status == 206 and h.wfile.getvalue() == data[:100]
    assert h.sent["Content-Range"] == "bytes 0-99/200" and h.sent["Content-Type"] == "video/mp4"
    assert not [c for c in relay.calls if c[0] == "stream"]


def test_stream_from_a_done_destination(store, H, relay):
    status, d = H("POST", "/destinations", {"type": "sftp", "name": "NAS", "host": "h", "user": "u"})
    (cid,) = inventory(H, "a.MP4", size=10)
    upload(H, store, cid, b"0123456789")
    store.set_destination_state(cid, d["destination"]["id"], "done", remote_path="dashcam/A4-1234/x/a.MP4")
    store.release_staging_if_done(cid)
    h = FakeHandler({"Range": "bytes=0-9"})
    dr.handle_dashcam_binary_get(h, f"/clips/{cid}/stream", store, relay=relay)
    assert h.status == 206 and h.wfile.getvalue() == b"0123456789"
    assert h.sent["Content-Range"] == "bytes 0-9/100"
    assert relay.calls[-1] == ("stream", "jc_" + d["destination"]["id"], "dashcam/A4-1234/x/a.MP4", "bytes=0-9")
    relay.stream = None
    relay.open_stream = lambda *a: (_ for _ in ()).throw(RelayUnavailable("rclone is not installed"))
    h = FakeHandler()
    dr.handle_dashcam_binary_get(h, f"/clips/{cid}/stream", store, relay=relay)
    assert h.status == 503


def test_stream_before_upload_is_404(store, H, relay):
    (cid,) = inventory(H, "a.MP4")
    h = FakeHandler()
    dr.handle_dashcam_binary_get(h, f"/clips/{cid}/stream", store, relay=relay)
    assert h.status == 404 and h.json()["error"] == "clip is not uploaded yet"


def test_gpx_download(store, H):
    (a,) = inventory(H, "a.MP4")
    H("POST", f"/clips/{a}/gps", {"fixes": [[T0 + i, 30.0 + i * 1e-4, -97.7, 11.0, 0.0] for i in range(10)]})
    drive = H("GET", "/drives")[1]["drives"][0]
    h = FakeHandler()
    assert dr.handle_dashcam_binary_get(h, f"/drives/{drive['id']}.gpx", store) is True
    assert h.status == 200 and h.sent["Content-Type"] == "application/gpx+xml"
    assert f'{drive["id"]}.gpx' in h.sent["Content-Disposition"]
    root = ET.fromstring(h.wfile.getvalue())
    assert len(root.findall(".//{http://www.topografix.com/GPX/1/1}trkpt")) == 10
    missing = FakeHandler()
    dr.handle_dashcam_binary_get(missing, "/drives/dr_1_x.gpx", store)
    assert missing.status == 404
    assert dr.handle_dashcam_binary_get(FakeHandler(), "/state", store) is False


# ── destinations ─────────────────────────────────────────────────────────────

def test_create_destination_never_echoes_secrets(H, store, relay):
    status, payload = H("POST", "/destinations", {"type": "sftp", "name": "NAS", "path": "/volume1/dashcam",
                                                  "host": "nas.local", "port": 2222, "user": "pk",
                                                  "password": "hunter2", "kinds": ["event", "photo"]})
    assert status == 200 and payload["ok"] is True
    dest = payload["destination"]
    assert dest["remote"] == "jc_" + dest["id"] and dest["kinds"] == ["event", "photo"] and dest["port"] == 2222
    assert "hunter2" not in json.dumps(payload)
    assert relay.calls[0][:3] == ("create", dest["id"], "sftp") and relay.calls[0][3]["password"] == "hunter2"
    token = '{"access_token":"ya29.secret","refresh_token":"1//secret"}'
    status, payload = H("POST", "/destinations", {"type": "drive", "name": "Drive", "token": token})
    assert status == 200 and "secret" not in json.dumps(payload) and payload["destination"]["path"] == "dashcam"
    listing = json.dumps(H("GET", "/destinations")[1])
    assert "hunter2" not in listing and "ya29" not in listing
    assert len(H("GET", "/destinations")[1]["destinations"]) == 2


def test_create_destination_errors(H, store, relay):
    assert H("POST", "/destinations", {"type": "webdav", "name": "x"})[0] == 400
    assert H("POST", "/destinations", {"type": "sftp", "name": ""})[0] == 400
    assert H("POST", "/destinations", {"type": "sftp", "name": "x", "kinds": ["video"]})[0] == 400
    relay.fail = ValueError("a sftp destination needs a host")
    status, payload = H("POST", "/destinations", {"type": "sftp", "name": "x"})
    assert status == 400 and "host" in payload["error"]
    relay.fail = RelayUnavailable("rclone is not installed on the server")
    status, payload = H("POST", "/destinations", {"type": "sftp", "name": "x", "host": "h", "user": "u"})
    assert status == 503 and "not installed" in payload["error"]
    relay.fail = RelayError("couldn't connect")
    assert H("POST", "/destinations", {"type": "sftp", "name": "x", "host": "h", "user": "u"})[0] == 400
    assert store.destinations() == []


def test_local_destination_needs_the_test_switch(H, monkeypatch):
    assert H("POST", "/destinations", {"type": "local", "name": "L", "path": "/tmp/x"})[0] == 400
    monkeypatch.setenv("JC_DASHCAM_ALLOW_LOCAL", "1")
    assert H("POST", "/destinations", {"type": "local", "name": "L", "path": "/tmp/x"})[0] == 200


def test_update_test_and_delete_destination(H, store, relay):
    did = H("POST", "/destinations", {"type": "ftp", "name": "F", "host": "h", "user": "u"})[1]["destination"]["id"]
    status, payload = H("POST", f"/destinations/{did}", {"enabled": False, "kinds": ["event"], "name": "FTP"})
    assert status == 200 and payload["destination"]["enabled"] is False and payload["destination"]["kinds"] == ["event"]
    assert H("POST", f"/destinations/{did}", {"kinds": ["video"]})[0] == 400
    status, payload = H("POST", f"/destinations/{did}/test", {})
    assert status == 200 and payload == {"ok": True}
    assert store.get_destination(did)["status"] == "ok" and store.get_destination(did)["tested_at"]
    relay.test_result = (False, "ftp: login failed")
    status, payload = H("POST", f"/destinations/{did}/test", {})
    assert status == 200 and payload == {"ok": False, "error": "ftp: login failed"}
    assert store.get_destination(did)["status"] == "error"
    relay.test_result = RelayUnavailable("rclone is not installed on the server")
    assert H("POST", f"/destinations/{did}/test", {})[0] == 503
    assert H("POST", f"/destinations/{did}/delete", {}) == (200, {"ok": True})
    assert ("delete", "jc_" + did) in relay.calls and store.destinations() == []
    assert H("POST", f"/destinations/{did}/delete", {})[0] == 404
    did2 = H("POST", "/destinations", {"type": "ftp", "name": "F", "host": "h", "user": "u"})[1]["destination"]["id"]
    assert H("DELETE", f"/destinations/{did2}") == (200, {"ok": True})
    assert H("POST", "/destinations/d_00000000/test", {})[0] == 404


# ── dispatch ─────────────────────────────────────────────────────────────────

def test_unknown_paths_and_methods(H):
    assert H("GET", "/nope")[0] == 404
    assert H("POST", "/nope", {})[0] == 404
    assert H("DELETE", "/state")[0] == 404
    assert H("PATCH", "/state")[0] == 405
    assert H("GET", "/clips/../../etc")[0] == 404


def test_paths_may_carry_the_query_and_a_trailing_slash(H):
    inventory(H, "a.MP4")
    status, payload = H("GET", "/clips/?limit=1")
    assert status == 200 and len(payload["clips"]) == 1
