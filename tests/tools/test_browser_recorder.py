"""Browser replays and the session store behind the chat's browser card.

The recorder screencasts a session over its own CDP client and encodes an MP4 when
the session ends; any failure only marks the replay failed. The store's view is
Contract A (``GET /api/browser/sessions/<id>``)."""
import base64
import json
import shutil
import subprocess
import time

import pytest

from tools import browser_recorder, browser_sessions

CONTRACT_KEYS = {
    "id", "engine", "provider", "provider_name", "status", "url", "title", "live_url",
    "live_interactive_url", "takeover", "move_requested", "replay_url", "replay_status",
    "can_move_to_cloud", "cloud_ready", "cloud_hint", "updated_at",
}


def _jpeg(width=64, height=48) -> bytes:
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        pytest.skip("ffmpeg not installed")
    out = subprocess.run([ffmpeg, "-loglevel", "error", "-f", "lavfi", "-i", f"color=c=blue:s={width}x{height}",
                          "-frames:v", "1", "-f", "image2pipe", "-vcodec", "mjpeg", "-"],
                         capture_output=True, check=True)
    return out.stdout


@pytest.fixture
def no_cloud(monkeypatch):
    monkeypatch.setattr(browser_sessions, "live_provider", lambda: None)
    monkeypatch.delenv("STEEL_API_KEY", raising=False)


# -- the store ---------------------------------------------------------------

def test_view_matches_contract_a(no_cloud):
    sid = browser_sessions.ensure("chat1")
    browser_sessions.update(sid, url="https://example.com/", title="Example")
    v = browser_sessions.view(sid)
    assert CONTRACT_KEYS <= set(v)
    assert v["engine"] == "lightpanda" and v["status"] == "running"
    assert v["can_move_to_cloud"] is True and v["cloud_ready"] is False
    assert v["cloud_hint"] == "Add a Steel key in Settings → Providers"
    assert v["replay_status"] == "none" and v["replay_url"] is None
    assert v["updated_at"].endswith("Z")


def test_ensure_reuses_the_running_session_and_starts_a_new_one_after_end(no_cloud):
    a = browser_sessions.ensure("chat1")
    assert browser_sessions.ensure("chat1") == a
    browser_sessions.end(a)
    b = browser_sessions.ensure("chat1")
    assert b != a and browser_sessions.view(a)["status"] == "ended"


def test_run_on_cloud_after_the_turn_carries_to_the_next_session(no_cloud):
    a = browser_sessions.ensure("chat1")
    browser_sessions.end(a)
    browser_sessions.request_move(a)
    b = browser_sessions.ensure("chat1")
    assert browser_sessions.get(b)["move_requested"] == 1
    assert browser_sessions.get(a)["move_requested"] == 0


def test_a_dead_process_session_reads_as_ended(no_cloud, monkeypatch):
    sid = browser_sessions.ensure("chat1")
    browser_sessions.update(sid, updated_at=time.time() - browser_sessions.STALE_AFTER_S - 5)
    assert browser_sessions.view(sid)["status"] == "ended"


def test_ending_drops_takeover(no_cloud):
    sid = browser_sessions.ensure("chat1")
    browser_sessions.update(sid, engine="cloud", live_interactive_url="https://x.steel.dev/p")
    browser_sessions.set_takeover(sid, True)
    assert browser_sessions.takeover_active(sid)
    browser_sessions.end(sid)
    assert not browser_sessions.takeover_active(sid)
    assert browser_sessions.view(sid)["takeover"] is False


def test_live_provider_name_rules(monkeypatch):
    monkeypatch.setattr(browser_sessions, "_browser_config", lambda: {})
    monkeypatch.delenv("STEEL_API_KEY", raising=False)
    assert browser_sessions.live_provider_name() is None
    monkeypatch.setenv("STEEL_API_KEY", "ste-12345678")
    assert browser_sessions.live_provider_name() == "steel"
    monkeypatch.setattr(browser_sessions, "_browser_config", lambda: {"cloud_provider": "local"})
    assert browser_sessions.live_provider_name() is None
    monkeypatch.setattr(browser_sessions, "_browser_config", lambda: {"cloud_provider": "browserbase"})
    assert browser_sessions.live_provider_name() == "browserbase"


def test_prune_removes_replays_older_than_14_days():
    old = browser_sessions.replay_path("b_old000000000")
    new = browser_sessions.replay_path("b_new000000000")
    old.write_bytes(b"x")
    new.write_bytes(b"x")
    past = time.time() - 15 * 86400
    import os
    os.utime(old, (past, past))
    assert browser_sessions.prune_replays() == 1
    assert not old.exists() and new.exists()


# -- the recorder ------------------------------------------------------------

def test_jpeg_size_reads_the_frame_dimensions():
    assert browser_recorder.jpeg_size(_jpeg(64, 48)) == (64, 48)
    assert browser_recorder.jpeg_size(b"not a jpeg") is None


def test_concat_list_holds_each_frame_for_its_time_and_caps_idle(tmp_path, no_cloud):
    sid = browser_sessions.ensure("chat1")
    rec = browser_recorder.SessionRecorder(sid)
    rec.add_frame(b"a", 100.0)
    rec.add_frame(b"b", 100.05)        # too soon: dropped
    rec.add_frame(b"c", 100.5)
    rec.add_frame(b"d", 160.0)         # a minute idle before it
    text = rec.concat_list()
    durations = [float(line.split()[1]) for line in text.splitlines() if line.startswith("duration")]
    assert text.splitlines()[-2] == "file 'f00002.jpg'"      # the closing repeat
    assert durations[:3] == [0.5, browser_recorder.MAX_FRAME_HOLD_S, browser_recorder.LAST_FRAME_HOLD_S]
    assert browser_sessions.view(sid)["replay_status"] == "recording"
    shutil.rmtree(rec.frames_dir, ignore_errors=True)


def test_encodes_an_mp4_the_card_can_play(no_cloud):
    frame = _jpeg(320, 200)
    sid = browser_sessions.ensure("chat1")
    rec = browser_recorder.SessionRecorder(sid)
    for i in range(5):
        rec.add_frame(frame, 10.0 + i * 0.4)
    rec.finish(background=False)
    out = browser_sessions.replay_path(sid)
    assert out.exists() and out.stat().st_size > 0
    probe = shutil.which("ffprobe")
    if probe:
        secs = float(subprocess.run([probe, "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0",
                                     str(out)], capture_output=True, text=True).stdout.strip())
        assert abs(secs - (4 * 0.4 + browser_recorder.LAST_FRAME_HOLD_S)) < 0.35
    v = browser_sessions.view(sid)
    assert v["replay_status"] == "ready" and v["replay_url"] == f"/api/browser/replays/{sid}.mp4"
    assert not rec.frames_dir.exists()


def test_no_ffmpeg_marks_the_replay_failed_without_raising(no_cloud, monkeypatch):
    sid = browser_sessions.ensure("chat1")
    rec = browser_recorder.SessionRecorder(sid)
    rec.add_frame(b"\xff\xd8junk", 1.0)
    monkeypatch.setattr(browser_recorder.shutil, "which", lambda name: None)
    rec.finish(background=False)
    v = browser_sessions.view(sid)
    assert v["replay_status"] == "failed" and "ffmpeg" in v["replay_error"]


def test_a_refused_cdp_client_marks_failed(no_cloud):
    sid = browser_sessions.ensure("chat1")

    def refuse(url):
        raise ConnectionRefusedError("one client only")

    rec = browser_recorder.SessionRecorder(sid, connect=refuse)
    rec.attach("wss://connect.steel.dev?sessionId=x")
    rec._source._thread.join(timeout=5)
    v = browser_sessions.view(sid)
    assert v["replay_status"] == "failed" and "recorder" in v["replay_error"]
    rec.finish(background=False)
    assert browser_sessions.view(sid)["replay_status"] == "failed"


class _FakeWs:
    def __init__(self):
        self.sent = []

    def send(self, raw):
        self.sent.append(json.loads(raw))


def test_screencast_attaches_to_pages_and_acks_frames(no_cloud):
    sid = browser_sessions.ensure("chat1")
    rec = browser_recorder.SessionRecorder(sid)
    src = browser_recorder._CdpSource(rec, "wss://x", connect=lambda u: None)
    ws = _FakeWs()
    targets_id = src._send(ws, "Target.getTargets", purpose="targets")
    src.handle(ws, {"id": targets_id, "result": {"targetInfos": [
        {"targetId": "T1", "type": "page"}, {"targetId": "W1", "type": "service_worker"}]}})
    attach = ws.sent[-1]
    assert attach["method"] == "Target.attachToTarget" and attach["params"]["targetId"] == "T1"
    src.handle(ws, {"id": attach["id"], "result": {"sessionId": "S1"}})
    start = ws.sent[-1]
    assert start["method"] == "Page.startScreencast" and start["sessionId"] == "S1"
    assert start["params"]["format"] == "jpeg" and start["params"]["maxWidth"] == 1280
    frame = base64.b64encode(b"\xff\xd8frame").decode()
    src.handle(ws, {"method": "Page.screencastFrame", "sessionId": "S1",
                    "params": {"data": frame, "sessionId": 7, "metadata": {"timestamp": 5.0}}})
    ack = ws.sent[-1]
    assert ack["method"] == "Page.screencastFrameAck" and ack["params"] == {"sessionId": 7}
    assert ack["sessionId"] == "S1"
    assert len(rec.frames) == 1 and rec.frames[0][1] == 5.0
    shutil.rmtree(rec.frames_dir, ignore_errors=True)


def test_a_replay_left_unfinished_by_a_dead_process_reads_as_failed(no_cloud):
    sid = browser_sessions.ensure("chat1")
    browser_sessions.update(sid, replay_status="encoding")
    browser_sessions.end(sid)
    assert browser_sessions.view(sid)["replay_status"] == "encoding"
    long_ago = time.time() - browser_sessions.STUCK_REPLAY_S - 5
    browser_sessions.update(sid, ended_at=long_ago, updated_at=long_ago)
    v = browser_sessions.view(sid)
    assert v["replay_status"] == "failed" and v["replay_error"]


def test_old_frame_dirs_from_a_restart_are_swept(tmp_path, monkeypatch):
    import os
    import tempfile
    monkeypatch.setattr(tempfile, "gettempdir", lambda: str(tmp_path))
    old = tmp_path / "jc-replay-b_old-x"
    new = tmp_path / "jc-replay-b_new-y"
    other = tmp_path / "something-else"
    for d in (old, new, other):
        d.mkdir()
    past = time.time() - browser_recorder.STALE_FRAME_DIR_S - 60
    os.utime(old, (past, past))
    os.utime(other, (past, past))
    assert browser_recorder.sweep_stale_frame_dirs() == 1
    assert not old.exists() and new.exists() and other.exists()
