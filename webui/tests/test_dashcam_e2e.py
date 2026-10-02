"""End to end through a real ``rclone rcd``: inventory → GPS → chunked upload → the relay worker
copies the clip to a destination → the staged copy is released → the clip streams back through
rclone with Range; and a camera ``.ts`` the same way, remuxed to MP4 by a real ffmpeg. Skipped when
rclone (or, for the remux, ffmpeg) isn't installed; run on a Mac with ``brew install rclone ffmpeg``."""
from __future__ import annotations

import hashlib
import io
import json
import os
import shutil
import subprocess
import time

import pytest

from api import dashcam_relay
from api import dashcam_routes as dr
from api.dashcam_relay import Relay, RelayWorker
from api.dashcam_store import DashcamStore

pytestmark = pytest.mark.skipif(shutil.which("rclone") is None and not os.environ.get("JC_RCLONE_BIN"),
                                reason="rclone not installed")

CHUNK = 64 * 1024


class Handler:
    def __init__(self, headers=None, body=b""):
        self.headers = dict(headers or {})
        if body:
            self.headers.setdefault("Content-Length", str(len(body)))
        self.rfile = io.BytesIO(body)
        self.wfile = io.BytesIO()
        self.status = None
        self.sent = {}
        self.close_connection = False

    def send_response(self, code, message=None):
        self.status = code

    def send_header(self, k, v):
        self.sent[k] = v

    def end_headers(self):
        pass


@pytest.fixture()
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("JC_DASHCAM_ALLOW_LOCAL", "1")
    monkeypatch.setattr(dr, "CHUNK_SIZE", CHUNK)
    monkeypatch.setattr(dr, "_rebuild_last", {})
    monkeypatch.setattr(dr, "_rebuild_timers", {})
    relay = Relay(state_dir=tmp_path / "state")
    relay.ensure_running()
    store = DashcamStore(tmp_path / "state")
    yield store, relay, tmp_path
    relay.shutdown()


def call(store, relay, method, path, body=None):
    return dr.handle_dashcam_request(method, path, {}, body, store, relay=relay)


def test_a_clip_goes_from_the_phone_to_a_destination_and_streams_back(env):
    store, relay, tmp = env
    dest_dir = tmp / "nas"
    status, out = call(store, relay, "POST", "/destinations",
                       {"type": "local", "name": "Test NAS", "path": str(dest_dir)})
    assert status == 200, out
    dest_id = out["destination"]["id"]

    payload = os.urandom(3 * CHUNK + 1234)          # four chunks, the last one short
    path = "/mnt/card/emr/20261001_154000_F.mp4"
    status, out = call(store, relay, "POST", "/inventory", {"camera_id": "CAM", "clips": [
        {"path": path, "kind": "event", "lens": "front", "start": "2026-10-01T20:40:00Z", "duration": 20,
         "size": len(payload)}]})
    assert status == 200, out
    clip_id = out["clips"][0]["id"]
    t0 = 1_790_887_200
    status, _ = call(store, relay, "POST", f"/clips/{clip_id}/gps",
                     {"fixes": [[t0 + i, 41.88, -87.63 + i * 1e-4, 13.4, 90.0] for i in range(20)]})
    assert status == 200

    sha = hashlib.sha256(payload).hexdigest()
    status, up = call(store, relay, "POST", "/uploads", {"clip_id": clip_id, "size": len(payload), "sha256": sha})
    assert status == 200, up
    for n in range(up["chunks"]):
        h = Handler(body=payload[n * CHUNK:(n + 1) * CHUNK])
        assert dr.handle_dashcam_raw_post(h, f"/api/dashcam/uploads/{up['upload_id']}/chunk?n={n}", store)
        assert h.status == 200, h.wfile.getvalue()
    status, done = call(store, relay, "POST", f"/uploads/{up['upload_id']}/complete")
    assert status == 200, done

    worker = RelayWorker(lambda: store, relay)
    deadline = time.time() + 60
    while time.time() < deadline:
        worker.tick()
        clip = store.get_clip(clip_id)
        if (clip.get("destinations") or {}).get(dest_id, {}).get("state") == "done":
            break
        time.sleep(0.5)
    clip = store.get_clip(clip_id)
    entry = clip["destinations"][dest_id]
    assert entry["state"] == "done", entry
    copies = [p for p in dest_dir.rglob("*") if p.is_file()]
    assert len(copies) == 1 and hashlib.sha256(copies[0].read_bytes()).hexdigest() == sha
    worker.tick()                                       # releases the staged copy
    assert store.staging_bytes() == 0

    h = Handler(headers={"Range": "bytes=100-199"})
    assert dr.handle_dashcam_binary_get(h, f"/api/dashcam/clips/{clip_id}/stream", store, relay=relay)
    assert h.status == 206
    assert h.wfile.getvalue() == payload[100:200]

    status, drives = call(store, relay, "GET", "/drives")
    assert status == 200 and len(drives["drives"]) == 1
    status, listed = call(store, relay, "GET", "/clips")
    assert listed["clips"][0]["uploaded"] is True


def test_a_ts_clip_reaches_the_destination_as_a_playable_mp4(env):
    if not (shutil.which("ffmpeg") and shutil.which("ffprobe")):
        pytest.skip("ffmpeg not installed")
    store, relay, tmp = env
    ts = tmp / "front.ts"
    made = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=160x90:rate=15",
                           "-f", "lavfi", "-i", "sine=f=440:sample_rate=16000", "-t", "2", "-c:v", "libx264",
                           "-c:a", "aac", "-f", "mpegts", str(ts)], capture_output=True, text=True)
    if made.returncode != 0:
        pytest.skip(f"ffmpeg can't make the fixture: {made.stderr.strip()[:200]}")
    payload = ts.read_bytes()
    dest_dir = tmp / "drive"
    status, out = call(store, relay, "POST", "/destinations", {"type": "local", "name": "Drive", "path": str(dest_dir)})
    assert status == 200, out
    dest_id = out["destination"]["id"]
    status, out = call(store, relay, "POST", "/inventory", {"camera_id": "A4", "clips": [
        {"path": "/mnt/card/video_front/2026-10-02_13_19_31_f.ts", "kind": "normal", "lens": "front",
         "start": "2026-10-02T13:19:31Z", "duration": 2, "size": len(payload)}]})
    clip_id = out["clips"][0]["id"]
    status, up = call(store, relay, "POST", "/uploads", {"clip_id": clip_id, "size": len(payload),
                                                         "sha256": hashlib.sha256(payload).hexdigest()})
    for n in range(up["chunks"]):
        h = Handler(body=payload[n * CHUNK:(n + 1) * CHUNK])
        assert dr.handle_dashcam_raw_post(h, f"/api/dashcam/uploads/{up['upload_id']}/chunk?n={n}", store)
    status, done = call(store, relay, "POST", f"/uploads/{up['upload_id']}/complete")
    assert status == 200 and done["clip"]["container"] == "mp4", done

    worker = RelayWorker(lambda: store, relay)
    deadline = time.time() + 60
    while time.time() < deadline:
        worker.tick()
        if store.get_clip(clip_id)["destinations"][dest_id]["state"] == "done":
            break
        time.sleep(0.5)
    entry = store.get_clip(clip_id)["destinations"][dest_id]
    assert entry["state"] == "done", entry
    copies = [p for p in dest_dir.rglob("*") if p.is_file()]
    assert [p.relative_to(dest_dir).as_posix() for p in copies] == ["A4/2026-10-02/normal/front/2026-10-02_13_19_31_f.mp4"]
    probe = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=format_name", "-of", "csv=p=0",
                            str(copies[0])], capture_output=True, text=True)
    assert "mp4" in probe.stdout
    worker.tick()                                       # releases the staged MP4
    assert store.staging_bytes() == 0 and not any((store.base / "staging").iterdir())

    h = Handler(headers={"Range": "bytes=0-99"})        # now through rclone, from the destination
    assert dr.handle_dashcam_binary_get(h, f"/api/dashcam/clips/{clip_id}/stream", store, relay=relay)
    assert h.status == 206 and h.sent["Content-Type"] == "video/mp4"
    assert h.wfile.getvalue() == copies[0].read_bytes()[:100]
