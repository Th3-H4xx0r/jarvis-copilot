"""Unit tests for the SERVER side of the Mac's coding file sync and folder listing.

Everything here runs with a FAKE transport (records sent frames; lets the test
inject inbound frames) — no real WebSocket, device or Mutagen is touched.

Coverage: starting / reusing / refusing a folder-pair Mutagen sync, the status
the Mac reports, stopping a project's sync, the device-bridge allow-list and
routing of coding frames, and the Mac folder listing for the typeahead.
"""
from __future__ import annotations

import os
import sys

import pytest

# webui dir (for ``api.*``) and the repo root (for ``agent.*``) on the path.
_WEBUI_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
_REPO_ROOT = os.path.abspath(os.path.join(_WEBUI_DIR, ".."))
for _p in (_WEBUI_DIR, _REPO_ROOT):
    if _p not in sys.path:
        sys.path.insert(0, _p)

from api import coding_desktop as cd  # noqa: E402


@pytest.fixture(autouse=True)
def _permissive_sync_roots(monkeypatch):
    """The sync safeguards restrict syncs to an allowlist of roots; these tests use
    illustrative paths (/root/proj, /Users/me/proj). Make the SERVER allowlist
    permissive so they exercise the sync plumbing rather than the guard. Refusal
    of dangerous/blocked syncs is covered by the dedicated tests, which use
    HARD-blocked paths (home/system) that fail regardless of the allowlist."""
    monkeypatch.setenv("JC_SYNC_ALLOWED_SERVER_ROOTS",
                       "/root:/Users:/private:/var:/tmp:/work:/w:/l:/r:/home")


class FakeTransport:
    """Records every frame sent to a device; ``connected`` gates send success."""

    def __init__(self, connected=True):
        self.sent = []  # list[(device_id, frame)]
        self.connected = connected

    def send(self, device_id, frame):
        if not self.connected:
            return False
        self.sent.append((device_id, dict(frame)))
        return True

    def frames(self, ftype):
        return [f for (_d, f) in self.sent if f.get("type") == ftype]


def make_bridge(connected=True):
    t = FakeTransport(connected=connected)
    return cd.DesktopBridge(transport=t), t


def test_start_sync_for_launch_sends_start(tmp_path):
    bridge, t = make_bridge()
    s = cd.start_sync_for_launch(
        "dev-L", session_id="cs_L", cwd="/root/proj",
        sync={"enabled": True, "remote_path": "/Users/me/proj"}, bridge=bridge)
    assert s is not None
    starts = t.frames("coding_sync_start")
    assert len(starts) == 1
    f = starts[0]
    # sync id is keyed by the FOLDER-PAIR (device+local+remote), not the session
    pair = cd.repo_sync_id("dev-L", "/Users/me/proj", "/root/proj")
    assert f["sync_id"] == pair
    assert f["local_path"] == "/Users/me/proj"   # the DESKTOP's folder
    assert f["remote_path"] == "/root/proj"       # the server's cwd
    assert bridge.sync_for(pair) is s


def test_start_sync_for_launch_noop_when_disabled(tmp_path):
    bridge, t = make_bridge()
    assert cd.start_sync_for_launch("dev-N", session_id="cs_N",
                                    cwd=str(tmp_path), sync=None,
                                    bridge=bridge) is None
    assert cd.start_sync_for_launch("dev-N", session_id="cs_N",
                                    cwd=str(tmp_path), sync={"enabled": False},
                                    bridge=bridge) is None
    assert t.sent == []


def test_start_sync_refuses_home_dir_local():
    # The runaway case: syncing the whole Mac home dir. Refused at the server gate
    # (is_dangerous(local)) even though the server path is fine.
    bridge, t = make_bridge()
    out = cd.start_sync_for_launch(
        "dev-H", session_id="cs_H", cwd="/root/codingprojects/x",
        sync={"enabled": True, "remote_path": "/Users/pranavkrishna"}, bridge=bridge)
    assert out is None
    assert t.frames("coding_sync_start") == []


def test_start_sync_refuses_mac_path_as_server():
    # The bogus /Users/... server tree: a Mac path used as the server destination.
    bridge, t = make_bridge()
    out = cd.start_sync_for_launch(
        "dev-M", session_id="cs_M",
        cwd="/Users/pranavkrishna/PranavFiles/coding-projects/jarvis-copilot",
        sync={"enabled": True, "remote_path": "/Users/me/code/proj"}, bridge=bridge)
    assert out is None
    assert t.frames("coding_sync_start") == []


def test_start_sync_refuses_server_path_outside_allowed_roots(monkeypatch):
    # Even a non-dangerous server path is refused if it's outside the allowlist.
    monkeypatch.setenv("JC_SYNC_ALLOWED_SERVER_ROOTS", "/root/codingprojects")
    bridge, t = make_bridge()
    out = cd.start_sync_for_launch(
        "dev-O", session_id="cs_O", cwd="/root/elsewhere/proj",
        sync={"enabled": True, "remote_path": "/Users/me/code/proj"}, bridge=bridge)
    assert out is None
    assert t.frames("coding_sync_start") == []


def test_start_sync_blocked_by_disk_guard():
    bridge, t = make_bridge()
    cd.set_sync_blocked(True, "disk full")
    try:
        out = cd.start_sync_for_launch(
            "dev-B", session_id="cs_B", cwd="/root/codingprojects/proj",
            sync={"enabled": True, "remote_path": "/Users/me/code/proj"},
            bridge=bridge)
        assert out is None
        assert t.frames("coding_sync_start") == []
    finally:
        cd.set_sync_blocked(False)


def test_mutagen_on_status_updates_session():
    bridge, t = make_bridge()
    s = cd.MutagenSyncSession(sync_id="sync-1", device_id="dev-A",
                              local_path="/l", remote_path="/r", bridge=bridge)
    bridge.register_sync(s)
    s.open()
    assert s.status == "opening"
    bridge.on_frame("dev-A", {"type": "coding_sync_status", "sync_id": "sync-1",
                              "status": "syncing", "done": 12, "total": 100})
    assert s.status == "syncing" and s.done == 12 and s.total == 100
    bridge.on_frame("dev-A", {"type": "coding_sync_status", "sync_id": "sync-1",
                              "status": "synced"})
    assert s.status == "synced" and s.last_sync_at is not None


def test_mutagen_status_conflicts():
    bridge, t = make_bridge()
    s = cd.MutagenSyncSession(sync_id="sync-c", device_id="dev-C",
                              local_path="/l", remote_path="/r", bridge=bridge)
    bridge.register_sync(s)
    bridge.on_frame("dev-C", {"type": "coding_sync_status", "sync_id": "sync-c",
                              "status": "conflicts", "conflicts": 3})
    assert s.status == "conflicts" and s.conflicts == 3


def test_mutagen_reopen_if_stale_resends_start():
    bridge, t = make_bridge()
    s = cd.MutagenSyncSession(sync_id="sync-st", device_id="dev-S",
                              local_path="/l", remote_path="/r", bridge=bridge)
    bridge.register_sync(s)
    s.open()
    assert len(t.frames("coding_sync_start")) == 1
    assert s.reopen_if_stale(now=s._last_open_at + 1) is False
    assert s.reopen_if_stale(now=s._last_open_at + 999) is True
    assert len(t.frames("coding_sync_start")) == 2
    # once status arrives we're no longer 'opening' -> never reopen
    bridge.on_frame("dev-S", {"type": "coding_sync_status", "sync_id": "sync-st",
                              "status": "synced"})
    assert s.reopen_if_stale(now=s._last_open_at + 999) is False


def test_mutagen_reopen_also_fires_on_connecting():
    bridge, t = make_bridge()
    s = cd.MutagenSyncSession(sync_id="sync-cn", device_id="dev-CN",
                              local_path="/l", remote_path="/r", bridge=bridge)
    bridge.register_sync(s)
    s.open()
    # Mutagen reports it's still connecting (ssh through the relay not up yet)
    bridge.on_frame("dev-CN", {"type": "coding_sync_status", "sync_id": "sync-cn",
                               "status": "connecting"})
    assert s.status == "connecting"
    # stuck connecting past the stale window -> re-start
    assert s.reopen_if_stale(now=s._last_open_at + 999) is True
    assert len(t.frames("coding_sync_start")) == 2


def test_mutagen_close_sends_stop():
    bridge, t = make_bridge()
    s = cd.MutagenSyncSession(sync_id="sync-x", device_id="dev-X",
                              local_path="/l", remote_path="/r", bridge=bridge)
    bridge.register_sync(s)
    s.close()
    assert t.frames("coding_sync_stop") and t.frames("coding_sync_stop")[0]["sync_id"] == "sync-x"
    assert bridge.sync_for("sync-x") is None  # send_sync_stop deregisters


def test_send_sync_reconcile_frame_and_deregisters_orphans():
    bridge, t = make_bridge()
    for sid in ("sync-a", "sync-b", "sync-c"):
        bridge.register_sync(cd.MutagenSyncSession(
            sync_id=sid, device_id="dev-1", local_path="/l", remote_path="/r",
            bridge=bridge))
    assert bridge.send_sync_reconcile("dev-1", ["sync-a"]) is True
    f = t.frames("coding_sync_reconcile")
    assert f and f[0]["active"] == ["sync-a"]
    # The authoritative set keeps sync-a; orphans b/c are dropped server-side.
    assert bridge.sync_for("sync-a") is not None
    assert bridge.sync_for("sync-b") is None and bridge.sync_for("sync-c") is None


def test_is_sync_capable_kind_excludes_only_mobile():
    # Desktop jc-clients commonly register with the DEFAULT kind 'browser' (only
    # the mobile app flips its kind), so 'browser'/'' must stay sync-capable —
    # only mobile kinds are excluded by kind. (Actual web browsers are filtered
    # out by the bridge_connected requirement, not here.)
    for k in ("desktop", "", "browser", "web"):
        assert cd.is_sync_capable_kind(k) is True
    assert cd.is_sync_capable_kind(None) is True
    for k in ("mobile-ios", "mobile"):
        assert cd.is_sync_capable_kind(k) is False


def test_resolve_desktop_device_id_skips_connected_mobile(monkeypatch):
    # A mobile device holds a bridge WS too — it must NEVER be a sync target,
    # even as the sole connected device or the explicitly-preferred one.
    from api import device_bridge
    monkeypatch.setattr(device_bridge, "connected_device_ids",
                        lambda: ["phone-1", "mac-1"], raising=False)
    monkeypatch.setattr("api.pairing.list_devices", lambda: [
        {"id": "phone-1", "name": "iPhone", "kind": "mobile-ios"},
        {"id": "mac-1", "name": "Mac", "kind": "desktop"},
    ], raising=False)
    assert cd.resolve_desktop_device_id() == "mac-1"
    assert cd.resolve_desktop_device_id(preferred="phone-1") == "mac-1"
    assert cd.resolve_desktop_device_id(preferred="iPhone") == "mac-1"


def test_resolve_desktop_device_id_none_when_only_mobile(monkeypatch):
    from api import device_bridge
    monkeypatch.setattr(device_bridge, "connected_device_ids",
                        lambda: ["phone-1"], raising=False)
    monkeypatch.setattr("api.pairing.list_devices", lambda: [
        {"id": "phone-1", "name": "iPhone", "kind": "mobile-ios"},
    ], raising=False)
    assert cd.resolve_desktop_device_id() is None
    assert cd.resolve_desktop_device_id(preferred="phone-1") is None


def test_sync_status_reports_live_registered_session(tmp_path, monkeypatch):
    import json
    monkeypatch.setattr(cd, "resolve_desktop_device_id", lambda preferred=None: "dev-Z")
    sess = cd.MutagenSyncSession(sync_id="sync-cs_Z", device_id="dev-Z",
                                 local_path="/l", remote_path="/r",
                                 bridge=make_bridge()[0])
    sess.status = "syncing"
    sess.done, sess.total = 2, 5
    cd.get_desktop_bridge().register_sync(sess)
    try:
        out = cd.sync_status("cs_Z", json.dumps({"enabled": True, "device": "dev-Z"}))
    finally:
        cd.get_desktop_bridge().send_sync_stop("dev-Z", "sync-cs_Z")
    assert out["status"] == "syncing"
    assert out["total"] == 5 and out["done"] == 2
    assert out["device_online"] is True


def test_sync_status_offline_overrides_stale_syncing(tmp_path, monkeypatch):
    import json
    monkeypatch.setattr(cd, "resolve_desktop_device_id", lambda preferred=None: None)
    sess = cd.MutagenSyncSession(sync_id="sync-cs_Off", device_id="dev-Off",
                                 local_path="/l", remote_path="/r",
                                 bridge=make_bridge()[0])
    sess.status = "syncing"
    sess.done, sess.total = 17, 500
    cd.get_desktop_bridge().register_sync(sess)
    try:
        out = cd.sync_status("cs_Off", json.dumps({"enabled": True, "device": "dev-Off"}))
    finally:
        cd.get_desktop_bridge().send_sync_stop("dev-Off", "sync-cs_Off")
    assert out["device_online"] is False
    assert out["status"] == "disconnected"
    assert out["total"] == 500 and out["done"] == 17


def test_sync_status_surfaces_conflicts(tmp_path, monkeypatch):
    import json
    monkeypatch.setattr(cd, "resolve_desktop_device_id", lambda preferred=None: "dev-K")
    sess = cd.MutagenSyncSession(sync_id="sync-cs_K", device_id="dev-K",
                                 local_path="/l", remote_path="/r",
                                 bridge=make_bridge()[0])
    sess.status = "conflicts"
    sess.conflicts = 2
    cd.get_desktop_bridge().register_sync(sess)
    try:
        out = cd.sync_status("cs_K", json.dumps({"enabled": True, "device": "dev-K"}))
    finally:
        cd.get_desktop_bridge().send_sync_stop("dev-K", "sync-cs_K")
    assert out["status"] == "conflicts" and out["conflicts"] == 2


def test_desktop_bridge_has_sync_for_not_get_sync():
    bridge, _t = make_bridge()
    assert hasattr(bridge, "sync_for")
    assert not hasattr(bridge, "get_sync")


def test_sync_error_frame_surfaces_on_session():
    bridge, _t = make_bridge()
    s = cd.MutagenSyncSession(sync_id="sync-er", device_id="dev-ER",
                              local_path="/l", remote_path="/r", bridge=bridge)
    bridge.register_sync(s)
    bridge.on_frame("dev-ER", {"type": "coding_sync_error", "sync_id": "sync-er",
                               "op": "mutagen", "error": "ssh connect refused"})
    assert s.status == "error"
    assert "ssh connect refused" in (s.error or "")


def test_unregistered_sync_id_is_ignored():
    bridge, t = make_bridge()
    bridge.on_frame("dev-T", {"type": "coding_sync_status",
                              "sync_id": "ghost", "status": "synced"})
    assert t.sent == []


def test_send_frame_unknown_device_returns_false():
    from api import device_bridge as db

    assert db.send_frame("no-such-device", {"type": "coding_term_input"}) is False


def test_sibling_sessions_share_one_repo_sync(tmp_path):
    bridge, t = make_bridge()
    sync = {"enabled": True, "remote_path": "/Users/me/proj"}
    a = cd.start_sync_for_launch("dev-X", session_id="cs_a", cwd="/root/proj",
                                 sync=sync, bridge=bridge)
    b = cd.start_sync_for_launch("dev-X", session_id="cs_b", cwd="/root/proj",
                                 sync=sync, bridge=bridge)
    # same folder-pair -> same object reused, only ONE coding_sync_start sent
    assert a is b
    assert len(t.frames("coding_sync_start")) == 1


class DirListResponder:
    """FakeTransport that synchronously replies to a coding_dir_list_get."""

    def __init__(self, *, dirs=None, error=None, connected=True):
        self.bridge = None
        self.dirs = dirs if dirs is not None else []
        self.error = error
        self.connected = connected
        self.sent = []

    def send(self, device_id, frame):
        if not self.connected:
            return False
        self.sent.append((device_id, dict(frame)))
        if frame.get("type") == "coding_dir_list_get":
            reply = {"type": "coding_dir_list_data", "req_id": frame["req_id"]}
            if self.error is not None:
                reply.update(ok=False, error=self.error)
            else:
                reply.update(ok=True, dirs=self.dirs)
            self.bridge.on_frame(device_id, reply)
        return True


def _dir_bridge(**kw):
    resp = DirListResponder(**kw)
    bridge = cd.DesktopBridge(transport=resp)
    resp.bridge = bridge
    return bridge, resp


def test_request_dir_list_returns_dirs():
    bridge, resp = _dir_bridge(dirs=["/Users/me/a", "/Users/me/b"])
    out = bridge.request_dir_list("dev-1", path="/Users/me/", timeout=2.0)
    assert out == ["/Users/me/a", "/Users/me/b"]
    gets = resp.sent
    assert gets and gets[0][1]["path"] == "/Users/me/"


def test_request_dir_list_device_error_returns_none():
    bridge, _resp = _dir_bridge(error="permission denied")
    assert bridge.request_dir_list("dev-1", path="/", timeout=2.0) is None


def test_request_dir_list_offline_returns_none():
    bridge, _t = make_bridge(connected=False)
    assert bridge.request_dir_list("dev-off", path="/", timeout=0.05) is None


def test_request_dir_list_timeout_returns_none():
    # FakeTransport records the send but never echoes a reply -> times out.
    bridge, _t = make_bridge(connected=True)
    assert bridge.request_dir_list("dev-1", path="/", timeout=0.05) is None


def test_inbound_allowlist_is_sync_and_folder_listing_only():
    """Only the sync and folder-listing replies reach DesktopBridge.on_frame;
    the old terminal / discovery / transcript frames are gone."""
    from api import device_bridge
    allowed = device_bridge._CODING_INBOUND_TYPES
    assert {"coding_sync_status", "coding_sync_error", "coding_sync_authorize_key",
            "coding_dir_list_data"} <= allowed
    for gone in ("coding_term_output", "coding_term_exit", "coding_discover",
                 "coding_transcript_data", "coding_file_done", "coding_session_ack"):
        assert gone not in allowed


def test_device_bridge_routes_coding_frames_to_handler():
    from api import device_bridge as db

    class _Sock:
        def shutdown(self, *_a):
            pass

        def close(self):
            pass

    got = []
    db.set_coding_frame_handler(lambda did, frame: got.append((did, frame)))
    try:
        conn = db._DeviceConn(device_id="dev-Z", sock=_Sock(), conn=None, name="desk")
        db._handle_message(conn, {"type": "coding_sync_status", "sync_id": "s",
                                  "status": "synced"})
        db._handle_message(conn, {"type": "coding_dir_list_data", "req_id": "r",
                                  "ok": True, "dirs": []})
        db._handle_message(conn, {"type": "coding_term_output", "term_id": "x", "data": "hi"})
        db._handle_message(conn, {"type": "pong"})
        assert [g[1]["type"] for g in got] == ["coding_sync_status", "coding_dir_list_data"]
        assert got[0][0] == "dev-Z"
    finally:
        db.set_coding_frame_handler(None)


def test_stop_folder_sync_closes_the_registered_pair():
    bridge, t = make_bridge()
    s = cd.start_sync_for_launch("dev-S", session_id="project:proj", cwd="/root/proj",
                                 sync={"enabled": True, "remote_path": "/Users/me/proj"},
                                 bridge=bridge)
    cd.stop_folder_sync("dev-S", "/Users/me/proj", "/root/proj", bridge=bridge)
    stops = t.frames("coding_sync_stop")
    assert [f["sync_id"] for f in stops] == [s.sync_id]
    assert bridge.sync_for(s.sync_id) is None


def test_stop_folder_sync_tells_the_mac_even_without_a_session_object():
    """After a webui restart nothing is registered, but the Mac may still run it."""
    bridge, t = make_bridge()
    cd.stop_folder_sync("dev-S", "/Users/me/proj", "/root/proj", bridge=bridge)
    assert [f["sync_id"] for f in t.frames("coding_sync_stop")] == [
        cd.repo_sync_id("dev-S", "/Users/me/proj", "/root/proj")]


def test_stop_folder_sync_ignores_missing_pieces():
    bridge, t = make_bridge()
    cd.stop_folder_sync("", "/Users/me/proj", "/root/proj", bridge=bridge)
    cd.stop_folder_sync("dev-S", "", "/root/proj", bridge=bridge)
    assert t.sent == []
