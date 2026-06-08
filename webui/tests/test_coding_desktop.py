"""Unit tests for the SERVER side of a DESKTOP-host coding session.

Everything here runs with a FAKE transport (records sent frames; lets the test
inject inbound frames) — no real WebSocket, device, tmux, claude, or filesystem
watcher is touched. The one place real I/O happens is the sync apply path, which
uses pytest ``tmp_path`` dirs.

Coverage:
  * DesktopDriver -> coding_term_open with the right argv/cwd (and the
    send-keys / kill-session translations), with command CONSTRUCTION identical
    to LocalDriver.
  * inbound coding_term_output reaches the attached terminal feed (incl. the
    pre-attach replay buffer), and feed writes emit coding_term_input.
  * sync initial direction: PUSH when the remote manifest is empty (drives
    coding_sync_file out), PULL otherwise (drives coding_sync_get out, then an
    inbound coding_sync_file lands on disk).
  * inbound frame routing by term_id / sync_id through device_bridge's
    set_coding_frame_handler hook.
"""
from __future__ import annotations

import base64
import gzip
import os
import sys

# webui dir (for ``api.*``) and the repo root (for ``agent.*``) on the path.
_WEBUI_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
_REPO_ROOT = os.path.abspath(os.path.join(_WEBUI_DIR, ".."))
for _p in (_WEBUI_DIR, _REPO_ROOT):
    if _p not in sys.path:
        sys.path.insert(0, _p)

from api import coding_desktop as cd  # noqa: E402
from agent.coding_host_drivers import DesktopDriver, LocalDriver  # noqa: E402
from agent.coding_session_manager import CodingSessionManager  # noqa: E402


# ── fakes ────────────────────────────────────────────────────────────────────


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


# ── DesktopDriver: command construction identical, execution sends frames ─────


def test_desktop_argv_construction_matches_local_driver():
    """The desktop driver MUST build the exact same tmux+claude argv as the
    local driver — only execution differs."""
    local = LocalDriver()
    desk = DesktopDriver(bridge_run=lambda argv: None)
    kw = dict(plugin_dir="/plug", context_file="/ctx.md", model="opus",
              initial_prompt="do it")
    assert desk.claude_argv(**kw) == local.claude_argv(**kw)
    la = local.claude_argv(**kw)
    assert desk.tmux_new_argv(tmux_name="jc-abc", cwd="/work", launch_argv=la) \
        == local.tmux_new_argv(tmux_name="jc-abc", cwd="/work", launch_argv=la)


def test_bridge_run_new_session_sends_coding_term_open():
    bridge, t = make_bridge()
    run = cd.make_bridge_run("dev-1", bridge)
    desk = DesktopDriver(bridge_run=run)

    launch_argv = desk.claude_argv(plugin_dir="/plug", context_file="/ctx.md",
                                   model="opus", initial_prompt="hello world")
    tmux_argv = desk.tmux_new_argv(tmux_name="jc-deadbeef", cwd="/home/me/proj",
                                   launch_argv=launch_argv)
    res = desk._run(tmux_argv)
    assert res.returncode == 0

    opens = t.frames("coding_term_open")
    assert len(opens) == 1
    f = opens[0]
    assert f["term_id"] == "jc-deadbeef"
    assert f["cwd"] == "/home/me/proj"
    # argv carried is the claude launch argv (everything after -c <cwd>)
    assert f["argv"] == launch_argv
    assert f["argv"][0] == "env"  # the scrub prefix is preserved verbatim


def test_bridge_run_send_keys_translates_to_coding_term_input():
    bridge, t = make_bridge()
    run = cd.make_bridge_run("dev-2", bridge)
    desk = DesktopDriver(bridge_run=run)
    # The manager sends two argvs per message: literal text, then Enter.
    for argv in desk.send_message_argvs(tmux_name="jc-xyz", text="ship it"):
        desk._run(argv)
    inputs = t.frames("coding_term_input")
    assert len(inputs) == 2
    assert inputs[0] == {"type": "coding_term_input", "term_id": "jc-xyz",
                         "data": "ship it"}
    # Enter is sent as a carriage return so the desktop PTY submits the line.
    assert inputs[1]["data"] == "\r"
    assert inputs[1]["term_id"] == "jc-xyz"


def test_bridge_run_kill_session_sends_coding_term_close():
    bridge, t = make_bridge()
    run = cd.make_bridge_run("dev-3", bridge)
    desk = DesktopDriver(bridge_run=run)
    desk._run(desk.kill_argv(tmux_name="jc-kill"))
    closes = t.frames("coding_term_close")
    assert closes == [{"type": "coding_term_close", "term_id": "jc-kill"}]


def test_bridge_run_reports_failure_when_device_offline():
    bridge, t = make_bridge(connected=False)
    run = cd.make_bridge_run("dev-off", bridge)
    desk = DesktopDriver(bridge_run=run)
    res = desk._run(desk.tmux_new_argv(
        tmux_name="jc-x", cwd="/w",
        launch_argv=desk.claude_argv(plugin_dir="/p", context_file="/c",
                                     model=None, initial_prompt=None)))
    assert res.returncode == 1
    assert "not connected" in res.stderr


def test_desktop_driver_lazy_factory_resolves_at_run_time():
    bridge, t = make_bridge()
    calls = {"n": 0}

    def factory():
        calls["n"] += 1
        return cd.make_bridge_run("dev-lazy", bridge)

    desk = DesktopDriver(bridge_run_factory=factory)
    assert desk.preflight() is None  # factory yields a runnable -> ready
    desk._run(desk.kill_argv(tmux_name="jc-l"))
    assert calls["n"] >= 1
    assert t.frames("coding_term_close")


def test_desktop_driver_preflight_when_no_client():
    desk = DesktopDriver(bridge_run_factory=lambda: None)
    msg = desk.preflight()
    assert msg and "desktop client" in msg


# ── terminal feed: inbound output reaches the feed; writes emit input ─────────


def test_inbound_output_reaches_attached_feed(monkeypatch):
    bridge, t = make_bridge()
    # Don't touch the real api.terminal registry in this unit test.
    monkeypatch.setattr(cd.DesktopBridge, "attach_feed",
                        _attach_feed_no_registry, raising=True)

    feed = bridge.attach_feed(session_id="cs_1", device_id="dev-A",
                              term_id="jc-term", rows=30, cols=100)
    # Simulate the device streaming PTY bytes back.
    bridge.on_frame("dev-A", {"type": "coding_term_output",
                              "term_id": "jc-term", "data": "hello "})
    bridge.on_frame("dev-A", {"type": "coding_term_output",
                              "term_id": "jc-term", "data": "world"})
    chunks = _drain(feed)
    assert chunks == ["hello ", "world"]


def test_output_buffered_before_attach_is_replayed(monkeypatch):
    bridge, t = make_bridge()
    monkeypatch.setattr(cd.DesktopBridge, "attach_feed",
                        _attach_feed_no_registry, raising=True)
    # Output arrives BEFORE any viewer attaches -> buffered for replay.
    bridge.on_frame("dev-B", {"type": "coding_term_output",
                              "term_id": "jc-pre", "data": "early "})
    bridge.on_frame("dev-B", {"type": "coding_term_output",
                              "term_id": "jc-pre", "data": "bytes"})
    feed = bridge.attach_feed(session_id="cs_2", device_id="dev-B",
                              term_id="jc-pre")
    assert _drain(feed) == ["early ", "bytes"]


def test_feed_write_emits_coding_term_input(monkeypatch):
    bridge, t = make_bridge()
    monkeypatch.setattr(cd.DesktopBridge, "attach_feed",
                        _attach_feed_no_registry, raising=True)
    feed = bridge.attach_feed(session_id="cs_3", device_id="dev-C",
                              term_id="jc-w")
    feed.feed_write("ls -la\n")
    feed.feed_resize(40, 120)
    inputs = t.frames("coding_term_input")
    assert inputs[-1]["data"] == "ls -la\n"
    resizes = t.frames("coding_term_resize")
    assert resizes[-1]["rows"] == 40 and resizes[-1]["cols"] == 120


def test_inbound_exit_closes_feed(monkeypatch):
    bridge, t = make_bridge()
    monkeypatch.setattr(cd.DesktopBridge, "attach_feed",
                        _attach_feed_no_registry, raising=True)
    feed = bridge.attach_feed(session_id="cs_4", device_id="dev-D",
                              term_id="jc-e")
    assert feed.is_alive()
    bridge.on_frame("dev-D", {"type": "coding_term_exit",
                              "term_id": "jc-e", "code": 0})
    assert not feed.is_alive()
    events = [e for (e, _p) in _drain_events(feed)]
    assert "terminal_closed" in events


# ── Mutagen sync: control frames + status (engine runs on the desktop) ───────


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
    for k in ("mobile-ios", "mobile-android", "mobile"):
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


# ── resync_device: re-open sync for running synced sessions on reconnect ─────


class FakeStore:
    """Minimal CodingSessionStore stand-in: list_sessions(status=...) only."""

    def __init__(self, sessions):
        self._sessions = list(sessions)

    def list_sessions(self, *, status=None):
        if status is None:
            return [dict(s) for s in self._sessions]
        return [dict(s) for s in self._sessions if s.get("status") == status]


def test_resync_device_reopens_running_synced_sessions(tmp_path):
    import json

    bridge, t = make_bridge()
    store = FakeStore([
        # running + has a sync_config -> RE-OPENED
        {"id": "cs_run", "status": "running", "host": "desktop",
         "cwd": str(tmp_path),
         "sync_config": json.dumps({"enabled": True,
                                    "remote_path": "/Users/me/proj"})},
        # stopped -> NOT re-opened (list_sessions(status='running') excludes it)
        {"id": "cs_stop", "status": "stopped", "host": "desktop",
         "cwd": str(tmp_path),
         "sync_config": json.dumps({"enabled": True})},
        # running but no sync_config and host != desktop -> NOT re-opened
        {"id": "cs_srv", "status": "running", "host": "server",
         "cwd": str(tmp_path), "sync_config": None},
    ])

    n = cd.resync_device("dev-RS", store=store, bridge=bridge)
    assert n == 1

    opens = t.frames("coding_sync_start")
    assert len(opens) == 1
    f = opens[0]
    pair = cd.repo_sync_id("dev-RS", "/Users/me/proj", str(tmp_path))
    assert f["sync_id"] == pair
    assert f["local_path"] == "/Users/me/proj"  # the desktop's folder
    # the session is registered for inbound-frame routing under its sync id
    assert bridge.sync_for(pair) is not None


def test_resync_device_desktop_session_without_sync_config(tmp_path):
    """A desktop-host running session with no explicit sync_config still gets a
    sync of its cwd (synthesized enabled config)."""
    bridge, t = make_bridge()
    store = FakeStore([
        {"id": "cs_d", "status": "running", "host": "desktop",
         "cwd": str(tmp_path), "sync_config": None},
    ])
    n = cd.resync_device("dev-D2", store=store, bridge=bridge)
    assert n == 1
    opens = t.frames("coding_sync_start")
    assert len(opens) == 1
    # no explicit remote_path -> the desktop opens the session cwd
    assert opens[0]["local_path"] == str(tmp_path)
    assert opens[0]["sync_id"] == cd.repo_sync_id("dev-D2", str(tmp_path), str(tmp_path))


def test_resync_device_noop_when_nothing_synced(tmp_path):
    bridge, t = make_bridge()
    store = FakeStore([
        {"id": "cs_srv", "status": "running", "host": "server",
         "cwd": str(tmp_path), "sync_config": None},
    ])
    assert cd.resync_device("dev-N", store=store, bridge=bridge) == 0
    assert t.frames("coding_sync_start") == []


def test_resync_device_defensive_on_bad_store():
    bridge, t = make_bridge()

    class Boom:
        def list_sessions(self, *, status=None):
            raise RuntimeError("db locked")

    # Must never raise; returns 0 and sends nothing.
    assert cd.resync_device("dev-B", store=Boom(), bridge=bridge) == 0
    assert t.sent == []


def test_resync_device_blank_device_id_is_noop(tmp_path):
    bridge, t = make_bridge()
    store = FakeStore([
        {"id": "cs_run", "status": "running", "host": "desktop",
         "cwd": str(tmp_path), "sync_config": '{"enabled": true}'},
    ])
    assert cd.resync_device("", store=store, bridge=bridge) == 0
    assert t.sent == []


def test_resync_device_skips_bad_sync_config_json(tmp_path):
    """A server-host running session whose sync_config is unparseable JSON is
    skipped (not re-opened) rather than crashing the whole resync."""
    bridge, t = make_bridge()
    store = FakeStore([
        {"id": "cs_bad", "status": "running", "host": "server",
         "cwd": str(tmp_path), "sync_config": "{not json"},
    ])
    # _session_is_synced is True (non-empty sync_config) but the JSON is bad ->
    # no usable sync dict -> skipped, count 0, no frames.
    assert cd.resync_device("dev-J", store=store, bridge=bridge) == 0
    assert t.frames("coding_sync_start") == []


# ── ingest_discovered: upsert + reconcile device-scanned tmux sessions ───────


def _temp_store(tmp_path):
    from agent.coding_session_db import CodingSessionStore

    return CodingSessionStore(db_path=str(tmp_path / "coding.db"))


def _discovered(device_id, sessions, store, monkeypatch):
    """Run ingest_discovered against a real temp store (via _resolve_store)."""
    monkeypatch.setattr(cd, "_resolve_store", lambda: store, raising=True)
    return cd.ingest_discovered(device_id, sessions)


def test_ingest_discovered_creates_project_and_session(tmp_path, monkeypatch):
    store = _temp_store(tmp_path)
    n = _discovered("dev-1", [
        {"kind": "tmux", "tmux_name": "claude-proj", "cwd": "/Users/me/proj",
         "title": "proj", "last_activity": 1234.5},
    ], store, monkeypatch)
    assert n == 1

    sessions = store.list_sessions(device_id="dev-1")
    assert len(sessions) == 1
    s = sessions[0]
    assert s["tmux_name"] == "claude-proj"
    assert s["host"] == "desktop"
    assert s["status"] == "running"
    assert s["source"] == "discovered-tmux"
    assert s["external"] == 1
    assert s["title"] == "proj"
    assert s["cwd"] == "/Users/me/proj"
    assert s["last_activity_at"] == 1234.5

    # A project was auto-created for the cwd, grouped under (cwd, device_id).
    pid = s["project_id"]
    proj = store.get_project(pid)
    assert proj is not None
    assert proj["repo_path"] == "/Users/me/proj"
    assert proj["device_id"] == "dev-1"
    # Idempotent: re-resolving the same (cwd, device) returns the same project.
    assert store.get_or_create_project_for_path(
        repo_path="/Users/me/proj", device_id="dev-1") == pid


def test_ingest_discovered_second_push_updates_not_duplicates(tmp_path, monkeypatch):
    store = _temp_store(tmp_path)
    _discovered("dev-2", [
        {"kind": "tmux", "tmux_name": "claude-a", "cwd": "/w/a",
         "title": "old title", "last_activity": 10.0},
    ], store, monkeypatch)
    # Same (device_id, tmux_name) on the next push -> UPDATE the existing row.
    _discovered("dev-2", [
        {"kind": "tmux", "tmux_name": "claude-a", "cwd": "/w/a",
         "title": "new title", "last_activity": 99.0},
    ], store, monkeypatch)

    rows = store.list_sessions(device_id="dev-2")
    assert len(rows) == 1  # not duplicated
    assert rows[0]["title"] == "new title"
    assert rows[0]["status"] == "running"
    assert rows[0]["last_activity_at"] == 99.0


def test_ingest_discovered_cwd_change_moves_row_and_project(tmp_path, monkeypatch):
    """A tmux session re-created under the SAME name in a DIFFERENT folder must
    move the row's own cwd to match the (new) project it's reparented to — a
    stale cwd would split the row from its project's repo_path."""
    store = _temp_store(tmp_path)
    _discovered("dev-cwd", [
        {"kind": "tmux", "tmux_name": "claude-a", "cwd": "/w/old", "title": "a"},
    ], store, monkeypatch)
    _discovered("dev-cwd", [
        {"kind": "tmux", "tmux_name": "claude-a", "cwd": "/w/new", "title": "a"},
    ], store, monkeypatch)

    rows = store.list_sessions(device_id="dev-cwd")
    assert len(rows) == 1  # still one row (matched by name)
    row = rows[0]
    assert row["cwd"] == "/w/new"  # row cwd moved with it
    # ...and it's parented to the NEW cwd's project, not the old one.
    assert store.get_project(row["project_id"])["repo_path"] == "/w/new"


def test_ingest_discovered_omitted_last_activity_does_not_wipe(tmp_path, monkeypatch):
    """A push that omits last_activity must NOT overwrite a previously-known
    last_activity_at with NULL — only apply it when the device reports one."""
    store = _temp_store(tmp_path)
    _discovered("dev-la", [
        {"kind": "tmux", "tmux_name": "claude-a", "cwd": "/w/a",
         "title": "a", "last_activity": 42.0},
    ], store, monkeypatch)
    # Next push has no last_activity field at all.
    _discovered("dev-la", [
        {"kind": "tmux", "tmux_name": "claude-a", "cwd": "/w/a", "title": "a"},
    ], store, monkeypatch)
    row = store.list_sessions(device_id="dev-la")[0]
    assert row["last_activity_at"] == 42.0  # preserved, not wiped to None


def test_ingest_discovered_reconciles_vanished_to_stopped(tmp_path, monkeypatch):
    store = _temp_store(tmp_path)
    _discovered("dev-3", [
        {"kind": "tmux", "tmux_name": "claude-x", "cwd": "/w/x", "title": "x"},
        {"kind": "tmux", "tmux_name": "claude-y", "cwd": "/w/y", "title": "y"},
    ], store, monkeypatch)
    assert len(store.list_sessions(device_id="dev-3")) == 2

    # Next push omits claude-y -> it must be reconciled to 'stopped' (kept, not
    # deleted, for history).
    _discovered("dev-3", [
        {"kind": "tmux", "tmux_name": "claude-x", "cwd": "/w/x", "title": "x"},
    ], store, monkeypatch)

    by_name = {r["tmux_name"]: r for r in store.list_sessions(device_id="dev-3")}
    assert len(by_name) == 2  # nothing deleted
    assert by_name["claude-x"]["status"] == "running"
    assert by_name["claude-y"]["status"] == "stopped"


def test_ingest_discovered_dismissed_tombstone_blocks_recreate(tmp_path, monkeypatch):
    store = _temp_store(tmp_path)
    cd._DISMISSED_DISCOVERED.clear()
    cd.dismiss_discovered("dev-4", "claude-gone")
    n = _discovered("dev-4", [
        {"kind": "tmux", "tmux_name": "claude-gone", "cwd": "/w/g", "title": "g"},
        {"kind": "tmux", "tmux_name": "claude-keep", "cwd": "/w/k", "title": "k"},
    ], store, monkeypatch)
    cd._DISMISSED_DISCOVERED.clear()
    # Only the non-dismissed session is upserted.
    assert n == 1
    names = {r["tmux_name"] for r in store.list_sessions(device_id="dev-4")}
    assert names == {"claude-keep"}


def test_ingest_discovered_only_owns_discovered_rows(tmp_path, monkeypatch):
    """Reconcile must never touch Jarvis-launched (non-discovered) rows even when
    they share the device_id."""
    store = _temp_store(tmp_path)
    pid = store.get_or_create_project_for_path(repo_path="/w/owned",
                                               device_id="dev-5")
    owned = store.create_session(
        project_id=pid, host="desktop", cwd="/w/owned", branch=None,
        tmux_name="jc-owned", source="launch", title="owned",
        device_id="dev-5", external=False, status="running")
    # A push that doesn't mention jc-owned must leave it running.
    _discovered("dev-5", [
        {"kind": "tmux", "tmux_name": "claude-disc", "cwd": "/w/disc", "title": "d"},
    ], store, monkeypatch)
    assert store.get_session(owned)["status"] == "running"


def test_ingest_discovered_blank_device_id_uses_route_fallback(tmp_path, monkeypatch):
    """_route_discover falls back to the connection device_id when the frame's
    device_id is blank."""
    store = _temp_store(tmp_path)
    monkeypatch.setattr(cd, "_resolve_store", lambda: store, raising=True)
    bridge, _t = make_bridge()
    bridge.on_frame("conn-dev", {
        "type": "coding_discover", "device_id": "",
        "sessions": [{"kind": "tmux", "tmux_name": "claude-z",
                      "cwd": "/w/z", "title": "z"}],
    })
    rows = store.list_sessions(device_id="conn-dev")
    assert len(rows) == 1 and rows[0]["tmux_name"] == "claude-z"


def test_ingest_discovered_forged_frame_device_id_cannot_write_foreign_rows(
        tmp_path, monkeypatch):
    """SECURITY: a device authenticated as one id must NOT be able to write (or
    reconcile) ANOTHER device's discovered rows by self-reporting a different
    device_id in the frame. _route_discover keys off the authoritative WS
    connection id, never the payload's claimed id."""
    store = _temp_store(tmp_path)
    monkeypatch.setattr(cd, "_resolve_store", lambda: store, raising=True)
    bridge, _t = make_bridge()
    # Connection authenticated as 'attacker'; frame falsely claims 'victim'.
    bridge.on_frame("attacker", {
        "type": "coding_discover", "device_id": "victim",
        "sessions": [{"kind": "tmux", "tmux_name": "evil",
                      "cwd": "/w/e", "title": "e"}],
    })
    # The row must land under the AUTHENTICATED connection id, not the forged one.
    assert store.list_sessions(device_id="victim") == []
    attacker_rows = store.list_sessions(device_id="attacker")
    assert [r["tmux_name"] for r in attacker_rows] == ["evil"]


def test_ingest_discovered_malformed_items_dont_abort_batch(tmp_path, monkeypatch):
    """Non-dict / wrong-kind / blank-name items are skipped individually; the
    valid sessions in the same batch are still ingested (a bad item never aborts
    the whole push)."""
    store = _temp_store(tmp_path)
    n = _discovered("dev-mal", [
        "not-a-dict",
        {"kind": "tmux"},                              # missing tmux_name
        {"kind": "shell", "tmux_name": "s", "cwd": "/w"},  # wrong kind
        {"kind": "tmux", "tmux_name": "  ", "cwd": "/w"},   # blank name
        {"kind": "tmux", "tmux_name": "good", "cwd": "/w/g", "title": "g"},
    ], store, monkeypatch)
    assert n == 1
    names = {r["tmux_name"] for r in store.list_sessions(device_id="dev-mal")}
    assert names == {"good"}


def test_send_discover_request_emits_frame():
    bridge, t = make_bridge()
    assert bridge.send_discover_request("dev-D") is True
    f = t.frames("coding_discover_request")
    assert f == [{"type": "coding_discover_request"}]
    assert t.sent[0][0] == "dev-D"


def test_ingest_discovered_no_store_is_noop(monkeypatch):
    monkeypatch.setattr(cd, "_resolve_store", lambda: None, raising=True)
    assert cd.ingest_discovered("dev-X", [{"kind": "tmux",
                                           "tmux_name": "c", "cwd": "/w"}]) == 0


# ── ingest_discovered: transcript (resumable history) items ──────────────────


def test_ingest_transcript_creates_idle_resumable_session(tmp_path, monkeypatch):
    """A transcript item (no live flag) -> an 'idle' (resumable history) row under
    the auto-project for its cwd, keyed by claude_session_id."""
    store = _temp_store(tmp_path)
    n = _discovered("dev-tr", [
        {"kind": "transcript", "claude_session_id": "abc123",
         "cwd": "/Users/me/hist", "summary": "Refactor the parser",
         "last_activity": 555.0},
    ], store, monkeypatch)
    assert n == 1

    rows = store.list_sessions(device_id="dev-tr")
    assert len(rows) == 1
    s = rows[0]
    assert s["claude_session_id"] == "abc123"
    assert s["source"] == "discovered-transcript"
    assert s["external"] == 1
    assert s["host"] == "desktop"
    assert s["status"] == "idle"           # resumable history, NOT stopped
    assert s["title"] == "Refactor the parser"
    assert s["cwd"] == "/Users/me/hist"
    assert s["last_activity_at"] == 555.0
    # grouped under the auto-project for (cwd, device_id)
    proj = store.get_project(s["project_id"])
    assert proj["repo_path"] == "/Users/me/hist"
    assert proj["device_id"] == "dev-tr"


def test_ingest_transcript_title_falls_back_to_cwd_basename(tmp_path, monkeypatch):
    store = _temp_store(tmp_path)
    _discovered("dev-trb", [
        {"kind": "transcript", "claude_session_id": "noSummary",
         "cwd": "/Users/me/my-repo"},
    ], store, monkeypatch)
    row = store.list_sessions(device_id="dev-trb")[0]
    assert row["title"] == "my-repo"       # basename of cwd when no summary


def test_ingest_transcript_live_is_running(tmp_path, monkeypatch):
    store = _temp_store(tmp_path)
    _discovered("dev-trl", [
        {"kind": "transcript", "claude_session_id": "live1",
         "cwd": "/w/live", "summary": "live one", "live": True},
    ], store, monkeypatch)
    row = store.list_sessions(device_id="dev-trl")[0]
    assert row["status"] == "running"


def test_ingest_transcript_not_stopped_by_tmux_reconcile(tmp_path, monkeypatch):
    """Transcript rows are persistent history — the tmux 'mark absent stopped'
    reconcile must NOT touch them, even when a later push omits them entirely."""
    store = _temp_store(tmp_path)
    # First push: one tmux + one transcript, both in /w/x.
    _discovered("dev-mix", [
        {"kind": "tmux", "tmux_name": "claude-x", "cwd": "/w/x", "title": "x"},
        {"kind": "transcript", "claude_session_id": "hist-x", "cwd": "/w/h",
         "summary": "history"},
    ], store, monkeypatch)
    # Second push: only the tmux (transcript pruned from ~/.claude / just absent).
    _discovered("dev-mix", [
        {"kind": "tmux", "tmux_name": "claude-x", "cwd": "/w/x", "title": "x"},
    ], store, monkeypatch)

    rows = {(_r.get("source"), _r.get("claude_session_id") or _r.get("tmux_name")): _r
            for _r in store.list_sessions(device_id="dev-mix")}
    tr = rows[("discovered-transcript", "hist-x")]
    assert tr["status"] == "idle"          # still idle, NOT reconciled to stopped


def test_ingest_transcript_second_push_updates_not_duplicates(tmp_path, monkeypatch):
    store = _temp_store(tmp_path)
    _discovered("dev-tr2", [
        {"kind": "transcript", "claude_session_id": "dup", "cwd": "/w/d",
         "summary": "old", "last_activity": 1.0},
    ], store, monkeypatch)
    _discovered("dev-tr2", [
        {"kind": "transcript", "claude_session_id": "dup", "cwd": "/w/d",
         "summary": "new", "last_activity": 9.0, "live": True},
    ], store, monkeypatch)
    rows = store.list_sessions(device_id="dev-tr2")
    assert len(rows) == 1                  # matched by claude_session_id
    assert rows[0]["title"] == "new"
    assert rows[0]["status"] == "running"  # now live
    assert rows[0]["last_activity_at"] == 9.0


def test_ingest_transcript_omitted_last_activity_does_not_wipe(tmp_path, monkeypatch):
    store = _temp_store(tmp_path)
    _discovered("dev-trla", [
        {"kind": "transcript", "claude_session_id": "la", "cwd": "/w/la",
         "summary": "a", "last_activity": 77.0},
    ], store, monkeypatch)
    _discovered("dev-trla", [
        {"kind": "transcript", "claude_session_id": "la", "cwd": "/w/la",
         "summary": "a"},
    ], store, monkeypatch)
    row = store.list_sessions(device_id="dev-trla")[0]
    assert row["last_activity_at"] == 77.0  # preserved


def test_ingest_transcript_dismissed_tombstone_blocks_recreate(tmp_path, monkeypatch):
    store = _temp_store(tmp_path)
    cd._DISMISSED_DISCOVERED.clear()
    cd.dismiss_discovered("dev-trd", "csid-gone")   # tombstone by claude_session_id
    n = _discovered("dev-trd", [
        {"kind": "transcript", "claude_session_id": "csid-gone", "cwd": "/w/g",
         "summary": "gone"},
        {"kind": "transcript", "claude_session_id": "csid-keep", "cwd": "/w/k",
         "summary": "keep"},
    ], store, monkeypatch)
    cd._DISMISSED_DISCOVERED.clear()
    assert n == 1
    csids = {r["claude_session_id"] for r in store.list_sessions(device_id="dev-trd")}
    assert csids == {"csid-keep"}


def test_ingest_live_transcript_dedups_against_tmux_in_same_batch(tmp_path, monkeypatch):
    """A live transcript whose cwd already has a tmux row THIS batch is skipped —
    we keep the drivable tmux row, not a duplicate."""
    store = _temp_store(tmp_path)
    n = _discovered("dev-dedup", [
        {"kind": "tmux", "tmux_name": "claude-live", "cwd": "/w/same",
         "title": "live"},
        {"kind": "transcript", "claude_session_id": "same-csid", "cwd": "/w/same",
         "summary": "same session", "live": True},
    ], store, monkeypatch)
    # Only the tmux row was upserted; the live transcript dup was skipped.
    assert n == 1
    rows = store.list_sessions(device_id="dev-dedup")
    assert len(rows) == 1
    assert rows[0]["source"] == "discovered-tmux"
    assert rows[0]["tmux_name"] == "claude-live"


def test_ingest_idle_transcript_not_deduped_against_tmux(tmp_path, monkeypatch):
    """An IDLE (live=false) transcript is real history even if a tmux shares its
    cwd — it is NOT deduped (it's a different, resumable past session)."""
    store = _temp_store(tmp_path)
    n = _discovered("dev-nd", [
        {"kind": "tmux", "tmux_name": "claude-now", "cwd": "/w/same",
         "title": "now"},
        {"kind": "transcript", "claude_session_id": "past-csid", "cwd": "/w/same",
         "summary": "a past session"},   # live omitted -> idle history
    ], store, monkeypatch)
    assert n == 2
    sources = sorted(r["source"] for r in store.list_sessions(device_id="dev-nd"))
    assert sources == ["discovered-tmux", "discovered-transcript"]


def test_ingest_mixed_batch_both_kinds(tmp_path, monkeypatch):
    """A batch with both a tmux item and an unrelated transcript ingests both,
    grouped under their respective per-cwd projects."""
    store = _temp_store(tmp_path)
    n = _discovered("dev-both", [
        {"kind": "tmux", "tmux_name": "claude-t", "cwd": "/w/t", "title": "t"},
        {"kind": "transcript", "claude_session_id": "h1", "cwd": "/w/h",
         "summary": "history"},
    ], store, monkeypatch)
    assert n == 2
    rows = store.list_sessions(device_id="dev-both")
    by_src = {r["source"]: r for r in rows}
    assert set(by_src) == {"discovered-tmux", "discovered-transcript"}
    assert by_src["discovered-tmux"]["status"] == "running"
    assert by_src["discovered-transcript"]["status"] == "idle"


# ── claude --resume <id> argv (specific transcript) ──────────────────────────


def test_local_driver_claude_argv_resume_session_id():
    """resume_session_id -> ``--resume <id>`` and the initial prompt is suppressed
    (an existing conversation to continue). Distinct from resume=True (--continue)."""
    drv = LocalDriver()
    argv = drv.claude_argv(plugin_dir="/p", context_file="/c", model=None,
                           initial_prompt="seed me", resume_session_id="csid-9")
    assert "--resume" in argv
    assert argv[argv.index("--resume") + 1] == "csid-9"
    assert "seed me" not in argv          # initial prompt suppressed on resume
    assert "--continue" not in argv
    # the Restart path still uses --continue (latest conversation), not --resume
    cont = drv.claude_argv(plugin_dir="/p", context_file="/c", model=None,
                           initial_prompt=None, resume=True)
    assert "--continue" in cont and "--resume" not in cont


# ── request_transcript: pull a discovered transcript FROM the device ─────────


class TranscriptResponder:
    """A FakeTransport that, on a ``coding_transcript_get``, SYNCHRONOUSLY feeds
    back the configured ``coding_transcript_data`` frames through the bridge (so
    ``request_transcript`` finds the event already set when it waits)."""

    def __init__(self, chunks, *, error=None, respond=True):
        # chunks: list[(seq, content_b64, eof)]
        self.bridge = None
        self.chunks = chunks
        self.error = error
        self.respond = respond
        self.sent = []

    def send(self, device_id, frame):
        self.sent.append((device_id, dict(frame)))
        if frame.get("type") != "coding_transcript_get" or not self.respond:
            return True
        req_id = frame["req_id"]
        if self.error is not None:
            self.bridge.on_frame(device_id, {
                "type": "coding_transcript_data", "req_id": req_id,
                "ok": False, "error": self.error})
            return True
        for (seq, content_b64, eof) in self.chunks:
            self.bridge.on_frame(device_id, {
                "type": "coding_transcript_data", "req_id": req_id,
                "claude_session_id": frame.get("claude_session_id"),
                "seq": seq, "eof": eof, "content_b64": content_b64})
        return True


def _make_transcript_bridge(chunks, *, error=None, respond=True):
    resp = TranscriptResponder(chunks, error=error, respond=respond)
    bridge = cd.DesktopBridge(transport=resp)
    resp.bridge = bridge
    return bridge, resp


def _gz_chunks(raw, *, pieces=3):
    """gzip ``raw`` then split into ``pieces`` base64 chunks (seq, b64, eof)."""
    gz = gzip.compress(raw)
    step = max(1, len(gz) // pieces)
    out = []
    i = seq = 0
    while i < len(gz):
        part = gz[i:i + step]
        i += step
        out.append((seq, base64.b64encode(part).decode(), i >= len(gz)))
        seq += 1
    return out


def test_request_transcript_reassembles_and_gunzips():
    raw = b'{"type":"user"}\n{"type":"assistant"}\n' * 200
    chunks = _gz_chunks(raw, pieces=3)
    assert len(chunks) >= 2  # actually split, so reassembly is exercised
    # feed in REVERSE seq order (eof chunk first) to prove reassembly sorts by
    # seq and that a late chunk after eof is still accumulated.
    shuffled = list(reversed(chunks))
    bridge, resp = _make_transcript_bridge(shuffled)
    out = bridge.request_transcript("dev-T", claude_session_id="csid",
                                    cwd="/w/p", timeout=2.0)
    assert out == raw
    # the get frame carried the req_id + lookup keys
    gets = [f for (_d, f) in resp.sent if f.get("type") == "coding_transcript_get"]
    assert len(gets) == 1
    assert gets[0]["claude_session_id"] == "csid" and gets[0]["cwd"] == "/w/p"


def test_request_transcript_timeout_returns_none():
    bridge, _resp = _make_transcript_bridge([], respond=False)  # device never replies
    out = bridge.request_transcript("dev-T", claude_session_id="c", cwd="/w",
                                    timeout=0.05)
    assert out is None


def test_request_transcript_device_error_returns_none():
    bridge, _resp = _make_transcript_bridge([], error="no such transcript")
    out = bridge.request_transcript("dev-T", claude_session_id="c", cwd="/w",
                                    timeout=2.0)
    assert out is None


def test_request_transcript_oversize_returns_none(monkeypatch):
    monkeypatch.setattr(cd.DesktopBridge, "_TRANSCRIPT_CAP", 16, raising=True)
    big = base64.b64encode(b"x" * 64).decode()  # 64 decoded bytes > 16 cap
    bridge, _resp = _make_transcript_bridge([(0, big, True)])
    out = bridge.request_transcript("dev-T", claude_session_id="c", cwd="/w",
                                    timeout=2.0)
    assert out is None


def test_request_transcript_returns_none_when_device_offline():
    bridge, _t = make_bridge(connected=False)  # send() returns False
    out = bridge.request_transcript("dev-off", claude_session_id="c", cwd="/w",
                                    timeout=2.0)
    assert out is None


def test_request_transcript_cleans_up_waiter():
    raw = b"hello transcript\n"
    bridge, _resp = _make_transcript_bridge(_gz_chunks(raw, pieces=1))
    assert bridge.request_transcript("dev-T", claude_session_id="c", cwd="/w",
                                     timeout=2.0) == raw
    # the in-flight waiter registry is empty again (no leak on success)
    assert bridge._transcript_waiters == {}


def test_request_transcript_empty_transcript_roundtrips_to_empty_bytes():
    """An EMPTY transcript: the device ships ONE eof chunk = base64(gzip(b"")).
    The server must round-trip it to ``b""`` (a VALID empty result), NOT mistake
    the empty payload for a timeout/error (which would return ``None``)."""
    chunks = _gz_chunks(b"", pieces=1)          # one eof chunk, non-empty gzip
    assert len(chunks) == 1 and chunks[0][2] is True
    bridge, _resp = _make_transcript_bridge(chunks)
    out = bridge.request_transcript("dev-T", claude_session_id="c", cwd="/w",
                                    timeout=2.0)
    assert out == b""          # valid-but-empty, distinct from None
    assert out is not None
    assert bridge._transcript_waiters == {}     # still cleaned up


def test_request_transcript_late_duplicate_after_eof_is_safe():
    """A stray duplicate chunk arriving for the SAME req_id AFTER eof was already
    signalled must be dropped safely once the waiter is gone (no KeyError, no
    resurrection) — the bridge stays consistent."""
    raw = b'{"type":"user"}\n' * 100
    chunks = _gz_chunks(raw, pieces=2)
    bridge, _resp = _make_transcript_bridge(chunks)
    out = bridge.request_transcript("dev-T", claude_session_id="c", cwd="/w",
                                    timeout=2.0)
    assert out == raw
    # waiter already popped; a late frame for that req_id is ignored.
    bridge._route_transcript_data({
        "type": "coding_transcript_data", "req_id": "stale-req",
        "seq": 0, "eof": True, "content_b64": ""})
    assert bridge._transcript_waiters == {}


# ── resume_discovered_to_server: run a discovered session ON THE SERVER ───────


class _FailManager:
    """A manager whose launch must NOT be reached (validation rejects first)."""

    def launch(self, **kw):
        raise AssertionError("manager.launch must not be called")


class _RecordingServerDriver:
    """Minimal host=server driver that records the claude_argv kwargs + tmux cwd
    so the resume test can assert ``--resume <csid>`` ran in the server cwd."""

    name = "server"

    def __init__(self):
        self.claude_kw = None
        self.tmux_calls = []

    def preflight(self):
        return None

    def claude_argv(self, *, plugin_dir, context_file, model, initial_prompt,
                    skip_permissions=False, resume=False, resume_session_id=None,
                    mcp_config=None):
        self.claude_kw = dict(model=model, initial_prompt=initial_prompt,
                              resume=resume, resume_session_id=resume_session_id)
        argv = ["env", "claude"]
        if resume_session_id:
            argv += ["--resume", str(resume_session_id)]
        return argv

    def tmux_new_argv(self, *, tmux_name, cwd, launch_argv):
        self.tmux_calls.append({"tmux_name": tmux_name, "cwd": cwd,
                                "launch_argv": list(launch_argv)})
        return ["tmux", "new-session", "-d", "-s", tmux_name, "-c", cwd] \
            + list(launch_argv)

    def _run(self, argv):
        import types as _types
        return _types.SimpleNamespace(returncode=0, stderr="")


def _server_resume_fixture(tmp_path, monkeypatch, *,
                           transcript=b'{"type":"user"}\n'):
    """Seed a discovered transcript row + wire a server manager/bridge for resume.

    ``transcript`` is the RAW (gunzipped) bytes ``request_transcript`` returns;
    pass None to simulate a failed pull."""
    store = _temp_store(tmp_path)
    monkeypatch.setattr(cd, "_resolve_store", lambda: store, raising=True)
    cd._DISMISSED_DISCOVERED.clear()
    cd.ingest_discovered("dev-mac", [
        {"kind": "transcript", "claude_session_id": "CSID-1",
         "cwd": "/Users/me/proj", "summary": "history"},
    ])
    row = store.list_sessions(device_id="dev-mac")[0]

    server_root = tmp_path / "server-projects"
    monkeypatch.setattr(cd, "SERVER_PROJECTS_ROOT", str(server_root), raising=True)
    claude_root = tmp_path / "claude" / "projects"
    monkeypatch.setattr("agent.coding_session_capture.claude_projects_dir",
                        lambda: claude_root, raising=True)

    bridge, _t = make_bridge()
    monkeypatch.setattr(bridge, "request_transcript",
                        lambda device_id, **kw: transcript)

    drv = _RecordingServerDriver()
    sync_calls = []
    mgr = CodingSessionManager(
        store=store, driver=drv,
        plugin_dir="/repo/plugins/jarviscopilot-code-assist",
        memory_loader=lambda: ("mem", "usr"),
        context_root=str(tmp_path / "ctx"),
        sync_starter=lambda **kw: sync_calls.append(kw))
    return dict(store=store, row=row, server_root=server_root,
                claude_root=claude_root, bridge=bridge, drv=drv, mgr=mgr,
                sync_calls=sync_calls)


def test_resume_discovered_to_server_happy_path(tmp_path, monkeypatch):
    raw = b'{"type":"user"}\n{"type":"assistant"}\n'
    fx = _server_resume_fixture(tmp_path, monkeypatch, transcript=raw)
    out = cd.resume_discovered_to_server(
        fx["row"]["id"], manager=fx["mgr"], bridge=fx["bridge"],
        store=fx["store"])
    server_cwd = fx["server_root"] / "proj"   # basename(device_cwd) under root

    assert out["ok"] is True
    assert "warning" not in out
    sess = out["session"]
    assert sess["cwd"] == str(server_cwd)
    assert sess["status"] == "running"
    assert sess["host"] == "server"

    # claude --resume <csid>, server cwd, no initial prompt
    assert fx["drv"].claude_kw["resume_session_id"] == "CSID-1"
    assert fx["drv"].claude_kw["initial_prompt"] is None
    assert fx["drv"].tmux_calls[0]["cwd"] == str(server_cwd)

    # the transcript was written to the SERVER's encoded ~/.claude path so
    # `claude --resume CSID-1` (in server_cwd) finds it.
    from agent.coding_session_capture import encode_project_dir
    dest = (fx["claude_root"] / encode_project_dir(str(server_cwd))
            / "CSID-1.jsonl")
    assert dest.read_bytes() == raw

    # the old discovered row is retired (stopped) + tombstoned so it can't dup.
    assert fx["store"].get_session(fx["row"]["id"])["status"] == "stopped"
    assert cd._is_dismissed("dev-mac", "CSID-1") is True

    # file sync was started server_cwd <-> device_cwd (via the manager's starter)
    assert len(fx["sync_calls"]) == 1
    sc = fx["sync_calls"][0]
    assert sc["cwd"] == str(server_cwd)
    assert sc["sync"] == {"enabled": True, "device": "dev-mac",
                          "remote_path": "/Users/me/proj",
                          # carries transcript info so the server keeps the Mac's
                          # <csid>.jsonl current while it runs on the server.
                          "transcript": {"csid": "CSID-1",
                                         "device_cwd": "/Users/me/proj"}}

    # the resumed server session lands in the SAME project as the discovered row
    # (project_id threaded through), not a fresh server-only project.
    assert sess["project_id"] == fx["row"]["project_id"]
    assert fx["row"]["project_id"]
    cd._DISMISSED_DISCOVERED.clear()


def test_resume_discovered_to_server_empty_transcript_writes_no_warning(
        tmp_path, monkeypatch):
    """A VALID-but-empty transcript (``request_transcript`` returns ``b""``) is a
    SUCCESS, not a failure: the file is written (empty) and NO soft warning is
    surfaced. Regression guard for ``if data:`` vs ``if data is not None:``."""
    fx = _server_resume_fixture(tmp_path, monkeypatch, transcript=b"")
    out = cd.resume_discovered_to_server(
        fx["row"]["id"], manager=fx["mgr"], bridge=fx["bridge"],
        store=fx["store"])
    assert out["ok"] is True
    assert "warning" not in out                    # empty != failed pull
    server_cwd = fx["server_root"] / "proj"
    from agent.coding_session_capture import encode_project_dir
    dest = (fx["claude_root"] / encode_project_dir(str(server_cwd))
            / "CSID-1.jsonl")
    assert dest.exists()                           # written even though empty
    assert dest.read_bytes() == b""
    cd._DISMISSED_DISCOVERED.clear()


def test_resume_discovered_to_server_warns_when_transcript_unavailable(
        tmp_path, monkeypatch):
    """A failed transcript pull must NOT abort the resume — the session still
    launches on the server (claude recovers what it can) with a soft warning."""
    fx = _server_resume_fixture(tmp_path, monkeypatch, transcript=None)
    out = cd.resume_discovered_to_server(
        fx["row"]["id"], manager=fx["mgr"], bridge=fx["bridge"],
        store=fx["store"])
    assert out["ok"] is True
    assert out.get("warning")                      # soft warning surfaced
    assert out["session"]["status"] == "running"   # still launched on the server
    server_cwd = fx["server_root"] / "proj"
    from agent.coding_session_capture import encode_project_dir
    dest = (fx["claude_root"] / encode_project_dir(str(server_cwd))
            / "CSID-1.jsonl")
    assert not dest.exists()                        # nothing written on failure
    cd._DISMISSED_DISCOVERED.clear()


def test_resume_discovered_to_server_unknown_session_raises_keyerror(tmp_path):
    import pytest
    store = _temp_store(tmp_path)
    bridge, _t = make_bridge()
    with pytest.raises(KeyError):
        cd.resume_discovered_to_server("nope", manager=_FailManager(),
                                       bridge=bridge, store=store)


def test_resume_discovered_to_server_requires_claude_session_id(tmp_path):
    import pytest
    store = _temp_store(tmp_path)
    sid = store.create_session(
        project_id=None, host="desktop", cwd="/w", branch=None, tmux_name=None,
        source="discovered-transcript", title="t", device_id="dev-1",
        external=True, status="idle")  # no claude_session_id
    bridge, _t = make_bridge()
    with pytest.raises(ValueError):
        cd.resume_discovered_to_server(sid, manager=_FailManager(),
                                       bridge=bridge, store=store)


def test_resume_discovered_to_server_rejects_non_discovered(tmp_path):
    """A real server/launched session (even with a claude_session_id) is NOT a
    discovered session — resume must reject it before touching the manager."""
    import pytest
    store = _temp_store(tmp_path)
    sid = store.create_session(
        project_id=None, host="server", cwd="/w", branch=None, tmux_name="jc-x",
        source="chat", title="t", claude_session_id="csid", status="running")
    bridge, _t = make_bridge()
    with pytest.raises(ValueError):
        cd.resume_discovered_to_server(sid, manager=_FailManager(),
                                       bridge=bridge, store=store)


# ── resume-to-server retirement: the discovered row doesn't resurrect ────────


def test_resume_to_server_tombstone_blocks_rediscovery(tmp_path, monkeypatch):
    """After a discovered transcript is resumed onto the server, the device keeps
    listing that same csid as history. The resume tombstoned it, so a rediscover
    push must NOT resurrect it as a dup of the now-live server session."""
    raw = b'{"type":"user"}\n'
    fx = _server_resume_fixture(tmp_path, monkeypatch, transcript=raw)
    cd.resume_discovered_to_server(
        fx["row"]["id"], manager=fx["mgr"], bridge=fx["bridge"],
        store=fx["store"])
    store = fx["store"]
    before = {r["id"] for r in store.list_sessions(device_id="dev-mac")}
    # the device re-pushes the same transcript (still present in its ~/.claude)
    cd.ingest_discovered("dev-mac", [
        {"kind": "transcript", "claude_session_id": "CSID-1",
         "cwd": "/Users/me/proj", "summary": "history"},
    ])
    after = store.list_sessions(device_id="dev-mac")
    # no NEW discovered row was created (the csid is tombstoned)
    assert {r["id"] for r in after} == before
    # the original row stays retired
    assert store.get_session(fx["row"]["id"])["status"] == "stopped"
    cd._DISMISSED_DISCOVERED.clear()


# ── discovered projects default to sync-ON (with the device cwd) ─────────────


def test_ingest_discovered_project_defaults_sync_on(tmp_path, monkeypatch):
    """A project auto-created for a discovered session defaults sync ON with the
    device cwd as the desktop path — so the server has a mirror target."""
    store = _temp_store(tmp_path)
    _discovered("dev-syncdef", [
        {"kind": "tmux", "tmux_name": "claude-a", "cwd": "/Users/me/sp",
         "title": "a"},
    ], store, monkeypatch)
    row = store.list_sessions(device_id="dev-syncdef")[0]
    proj = store.get_project(row["project_id"])
    assert proj["sync_enabled"] == 1
    assert proj["sync_desktop_path"] == "/Users/me/sp"


def test_ingest_transcript_project_defaults_sync_on(tmp_path, monkeypatch):
    store = _temp_store(tmp_path)
    _discovered("dev-trsync", [
        {"kind": "transcript", "claude_session_id": "c1", "cwd": "/Users/me/tp",
         "summary": "h"},
    ], store, monkeypatch)
    row = store.list_sessions(device_id="dev-trsync")[0]
    proj = store.get_project(row["project_id"])
    assert proj["sync_enabled"] == 1
    assert proj["sync_desktop_path"] == "/Users/me/tp"


def test_ingest_discovered_does_not_clobber_user_sync_toggle(tmp_path, monkeypatch):
    """The sync default is CREATE-ONLY — a later discovery push must never undo a
    user's manual sync toggle on an existing project."""
    store = _temp_store(tmp_path)
    _discovered("dev-tog", [
        {"kind": "tmux", "tmux_name": "claude-a", "cwd": "/w/tog", "title": "a"},
    ], store, monkeypatch)
    pid = store.list_sessions(device_id="dev-tog")[0]["project_id"]
    store.update_project(pid, sync_enabled=False)  # user turns it OFF
    assert store.get_project(pid)["sync_enabled"] == 0
    # a later push must NOT re-enable it
    _discovered("dev-tog", [
        {"kind": "tmux", "tmux_name": "claude-a", "cwd": "/w/tog", "title": "a"},
    ], store, monkeypatch)
    assert store.get_project(pid)["sync_enabled"] == 0


def test_distinct_idle_transcript_not_overdeduped_against_tmux(tmp_path, monkeypatch):
    """The csid dedup must be PRECISE: an idle transcript with a DIFFERENT csid
    sharing a tmux row's cwd is a genuinely distinct resumable history and must
    NOT be swallowed."""
    store = _temp_store(tmp_path)
    n = _discovered("dev-precise", [
        {"kind": "tmux", "tmux_name": "claude-now", "cwd": "/w/same",
         "title": "now"},  # plain tmux: no claude_session_id
        {"kind": "transcript", "claude_session_id": "other-csid",
         "cwd": "/w/same", "summary": "a different past session"},
    ], store, monkeypatch)
    assert n == 2
    sources = sorted(r["source"]
                     for r in store.list_sessions(device_id="dev-precise"))
    assert sources == ["discovered-tmux", "discovered-transcript"]


# ── device_bridge inbound hook routes coding frames to the handler ───────────


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
        conn = db._DeviceConn(device_id="dev-Z", sock=_Sock(), conn=None,
                              name="desk")
        db._handle_message(conn, {"type": "coding_term_output",
                                  "term_id": "jc-z", "data": "hi"})
        db._handle_message(conn, {"type": "coding_sync_status",
                                  "sync_id": "s", "status": "synced"})
        # the transcript-reply frame is allow-listed + routed too
        db._handle_message(conn, {"type": "coding_transcript_data",
                                  "req_id": "r", "seq": 0, "eof": True,
                                  "content_b64": ""})
        # a non-coding type is NOT routed to the handler
        db._handle_message(conn, {"type": "pong"})
        assert [g[1]["type"] for g in got] == [
            "coding_term_output", "coding_sync_status", "coding_transcript_data"]
        assert got[0][0] == "dev-Z"
    finally:
        db.set_coding_frame_handler(None)


def test_send_frame_unknown_device_returns_false():
    from api import device_bridge as db

    assert db.send_frame("no-such-device", {"type": "coding_term_input"}) is False


def test_device_connect_hook_calls_resync_device(monkeypatch):
    """The device-connect hook (_trigger_coding_resync) drives resync_device off
    a background thread; verify it actually invokes it with the device_id."""
    import threading

    from api import coding_desktop as cd_mod
    from api import device_bridge as db

    seen = []
    done = threading.Event()

    def _fake_resync(device_id):
        seen.append(device_id)
        done.set()
        return 0

    monkeypatch.setattr(cd_mod, "resync_device", _fake_resync, raising=True)
    db._trigger_coding_resync("dev-HOOK")
    assert done.wait(2.0), "resync hook thread never ran"
    assert seen == ["dev-HOOK"]


def test_device_connect_hook_blank_id_is_noop(monkeypatch):
    from api import coding_desktop as cd_mod
    from api import device_bridge as db

    called = []
    monkeypatch.setattr(cd_mod, "resync_device",
                        lambda did: called.append(did), raising=True)
    db._trigger_coding_resync("")  # blank -> no thread, no call
    assert called == []


# ── feed plugs into the real api.terminal SSE/input/resize/close routes ───────


def test_feed_drives_real_terminal_module_routes():
    """attach_feed registers the feed in api.terminal's registry; the existing
    write/resize/close helpers then dispatch to the feed's feed_* methods (which
    emit bridge frames) instead of touching a PTY — proving the desktop session
    reuses the unchanged /api/terminal/{output,input,resize,close} machinery."""
    from api import terminal as term_mod

    bridge, t = make_bridge()
    sid = "cs_route_test"
    try:
        feed = bridge.attach_feed(session_id=sid, device_id="dev-RT",
                                  term_id="jc-rt", rows=24, cols=80)
        # get_terminal returns OUR feed (registered under the session id)
        assert term_mod.get_terminal(sid) is feed
        # write_terminal -> feed.feed_write -> coding_term_input frame
        term_mod.write_terminal(sid, "echo hi\n")
        assert t.frames("coding_term_input")[-1]["data"] == "echo hi\n"
        # resize_terminal -> feed.feed_resize -> coding_term_resize frame
        term_mod.resize_terminal(sid, rows=50, cols=200)
        assert t.frames("coding_term_resize")[-1]["rows"] == 50
        # inbound output reaches the queue the SSE route reads
        bridge.on_frame("dev-RT", {"type": "coding_term_output",
                                   "term_id": "jc-rt", "data": "ok"})
        assert _drain(feed) == ["ok"]
        # close_terminal -> feed.feed_close (detach; doesn't kill the desktop tmux)
        assert term_mod.close_terminal(sid) is True
        assert term_mod.get_terminal(sid) is None
    finally:
        term_mod.close_terminal(sid)


# ── helpers ──────────────────────────────────────────────────────────────────


def _attach_feed_no_registry(self, *, session_id, device_id, term_id,
                             rows=24, cols=80):
    """attach_feed without touching api.terminal's global registry (so these
    pure unit tests don't leak terminal state across tests)."""
    with self._lock:
        feed = self._feeds.get(term_id)
        if feed is None:
            feed = cd.DesktopTerminalFeed(
                session_id=session_id, device_id=device_id, term_id=term_id,
                bridge=self, rows=rows, cols=cols)
            self._feeds[term_id] = feed
            for chunk in self._replay.pop(term_id, []):
                feed.on_output(chunk)
            if term_id in self._pending_exit:
                feed.on_exit(self._pending_exit.pop(term_id))
    return feed


def _drain(feed):
    """Return the text of every 'output' event currently queued on the feed."""
    out = []
    while True:
        try:
            event, payload = feed.output.get_nowait()
        except Exception:
            break
        if event == "output":
            out.append(payload["text"])
    return out


def _drain_events(feed):
    items = []
    while True:
        try:
            items.append(feed.output.get_nowait())
        except Exception:
            break
    return items


# ── open/close-only transcript reconcile (newest-wins) ───────────────────────

import base64 as _b64
import gzip as _gz


class _OneSessionStore:
    def __init__(self, row):
        self._row = row

    def get_session(self, sid):
        return dict(self._row) if self._row and self._row.get("id") == sid else None


def _server_tx(tmp_path, server_cwd, csid, body):
    from agent.coding_session_capture import claude_projects_dir, encode_project_dir
    d = claude_projects_dir() / encode_project_dir(server_cwd)
    d.mkdir(parents=True, exist_ok=True)
    p = d / (csid + ".jsonl")
    p.write_bytes(body)
    return p


def _row(server_cwd, csid="cc", device="dev"):
    import json
    return {"id": "s1", "cwd": server_cwd, "device_id": device,
            "sync_config": json.dumps({"enabled": True, "device": device,
                                       "transcript": {"csid": csid,
                                                      "device_cwd": "/Users/me/p"}})}


def test_push_transcript_roundtrip():
    bridge, t = make_bridge()
    body = (b'{"x":1}\n') * 100
    ok = bridge.push_transcript("dev", claude_session_id="cc", cwd="/Users/me/p",
                                raw=body)
    assert ok is True
    puts = t.frames("coding_transcript_put")
    assert puts and puts[-1]["eof"] is True
    blob = b"".join(_b64.b64decode(f["content_b64"])
                    for f in sorted(puts, key=lambda f: f["seq"]))
    assert _gz.decompress(blob) == body


def test_reconcile_pulls_when_device_newer(tmp_path, monkeypatch):
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path))
    server_cwd = str(tmp_path / "srv"); os.makedirs(server_cwd, exist_ok=True)
    sp = _server_tx(tmp_path, server_cwd, "cc", b'{"a":1}\n')          # 1 line
    bridge, t = make_bridge()
    monkeypatch.setattr(bridge, "request_transcript",
                        lambda *a, **k: b'{"a":1}\n{"b":2}\n{"c":3}\n')  # 3 lines
    res = cd.reconcile_session_transcript("s1", store=_OneSessionStore(_row(server_cwd)),
                                          bridge=bridge)
    assert "pulled device->server" in res
    assert sp.read_bytes() == b'{"a":1}\n{"b":2}\n{"c":3}\n'   # server got device's
    assert not t.frames("coding_transcript_put")              # nothing pushed out


def test_reconcile_pushes_when_server_newer(tmp_path, monkeypatch):
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path))
    server_cwd = str(tmp_path / "srv"); os.makedirs(server_cwd, exist_ok=True)
    _server_tx(tmp_path, server_cwd, "cc", b'{"a":1}\n{"b":2}\n{"c":3}\n')  # 3 lines
    bridge, t = make_bridge()
    monkeypatch.setattr(bridge, "request_transcript", lambda *a, **k: b'{"a":1}\n')  # 1
    res = cd.reconcile_session_transcript("s1", store=_OneSessionStore(_row(server_cwd)),
                                          bridge=bridge)
    assert "pushed server->device" in res
    puts = t.frames("coding_transcript_put")
    blob = b"".join(_b64.b64decode(f["content_b64"])
                    for f in sorted(puts, key=lambda f: f["seq"]))
    assert _gz.decompress(blob) == b'{"a":1}\n{"b":2}\n{"c":3}\n'  # server's pushed out


def test_reconcile_in_sync_does_nothing(tmp_path, monkeypatch):
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path))
    server_cwd = str(tmp_path / "srv"); os.makedirs(server_cwd, exist_ok=True)
    _server_tx(tmp_path, server_cwd, "cc", b'{"a":1}\n{"b":2}\n')
    bridge, t = make_bridge()
    monkeypatch.setattr(bridge, "request_transcript", lambda *a, **k: b'{"a":1}\n{"b":2}\n')
    res = cd.reconcile_session_transcript("s1", store=_OneSessionStore(_row(server_cwd)),
                                          bridge=bridge)
    assert "in-sync" in res
    assert not t.frames("coding_transcript_put")


def test_reconcile_no_transcript_meta_is_noop(tmp_path):
    bridge, t = make_bridge()
    row = {"id": "s1", "cwd": "/x", "sync_config": '{"enabled": true}'}  # no transcript
    res = cd.reconcile_session_transcript("s1", store=_OneSessionStore(row), bridge=bridge)
    assert res == "no-transcript"


# ── repo-sync dedup by folder-pair (one Mutagen sync per project) ────────────

class _MultiStore:
    """get_session + list_sessions over a fixed row list (for dedup tests)."""
    def __init__(self, rows):
        self._rows = list(rows)
    def get_session(self, sid):
        return next((dict(r) for r in self._rows if r.get("id") == sid), None)
    def list_sessions(self, *, status=None):
        return [dict(r) for r in self._rows
                if status is None or r.get("status") == status]


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


def test_resync_dedups_active_set_by_pair(tmp_path):
    import json
    bridge, t = make_bridge()
    cfg = json.dumps({"enabled": True, "remote_path": "/Users/me/proj"})
    store = _MultiStore([
        {"id": "cs_a", "status": "running", "host": "server",
         "cwd": "/root/proj", "device_id": "dev-X", "sync_config": cfg},
        {"id": "cs_b", "status": "running", "host": "server",
         "cwd": "/root/proj", "device_id": "dev-X", "sync_config": cfg},
    ])
    cd.resync_device("dev-X", store=store, bridge=bridge)
    # two sessions, same project -> ONE sync started + ONE active id
    assert len(t.frames("coding_sync_start")) == 1
    recon = t.frames("coding_sync_reconcile")[-1]
    pair = cd.repo_sync_id("dev-X", "/Users/me/proj", "/root/proj")
    assert recon["active"] == [pair]


def test_stop_keeps_shared_sync_until_last_session(tmp_path):
    import json
    bridge, t = make_bridge()
    cfg = json.dumps({"enabled": True, "remote_path": "/Users/me/proj"})
    rows = [
        {"id": "cs_a", "status": "running", "cwd": "/root/proj",
         "device_id": "dev-X", "sync_config": cfg},
        {"id": "cs_b", "status": "running", "cwd": "/root/proj",
         "device_id": "dev-X", "sync_config": cfg},
    ]
    store = _MultiStore(rows)
    cd.start_sync_for_launch("dev-X", session_id="cs_a", cwd="/root/proj",
                             sync={"enabled": True, "remote_path": "/Users/me/proj"},
                             bridge=bridge)
    # stop cs_a while cs_b is still running on the same pair -> NO sync_stop
    cd.stop_sync_for_session("cs_a", store=store, bridge=bridge)
    assert not t.frames("coding_sync_stop")
    # now cs_b is the only one left; stopping it tears the sync down
    rows[0]["status"] = "stopped"
    cd.stop_sync_for_session("cs_b", store=store, bridge=bridge)
    pair = cd.repo_sync_id("dev-X", "/Users/me/proj", "/root/proj")
    assert any(f["sync_id"] == pair for f in t.frames("coding_sync_stop"))


# ── adopt a discovered live Mac tmux (single-process attach) ─────────────────

def _discovered_tmux_store(connected_device="dev-mac"):
    row = {"id": "cs_adopt", "source": "discovered-tmux", "host": "desktop",
           "status": "running", "tmux_name": "jc-abc123",
           "cwd": "/Users/me/proj", "device_id": connected_device}
    return _OneSessionStore(row)


def test_adopt_sends_tmux_attach_open_and_feed(tmp_path):
    bridge, t = make_bridge()
    res = cd.adopt_discovered_tmux("cs_adopt", bridge=bridge,
                                   store=_discovered_tmux_store())
    assert res["ok"] is True
    opens = t.frames("coding_term_open")
    assert len(opens) == 1
    o = opens[0]
    assert o["term_id"] == "jc-abc123"
    # attach-or-create to the EXISTING tmux (co-view; no -D, so the Mac stays on),
    # then size the pane to the most-recent client (window-size latest).
    assert o["argv"] == ["tmux", "new-session", "-A", "-s", "jc-abc123",
                         "-c", "/Users/me/proj",
                         ";", "set-option", "-g", "window-size", "latest"]
    assert "-D" not in o["argv"]


def test_adopt_offline_when_device_disconnected():
    bridge, t = make_bridge(connected=False)  # send returns False
    res = cd.adopt_discovered_tmux("cs_adopt", bridge=bridge,
                                   store=_discovered_tmux_store())
    assert res == {"ok": False, "offline": True}


def test_adopt_rejects_non_discovered():
    bridge, t = make_bridge()
    store = _OneSessionStore({"id": "cs_adopt", "source": "chat",
                              "tmux_name": "x", "cwd": "/c", "device_id": "d"})
    try:
        cd.adopt_discovered_tmux("cs_adopt", bridge=bridge, store=store)
        assert False, "expected ValueError"
    except ValueError as e:
        assert "discovered" in str(e)


def test_adopted_feed_closes_attach_pty_on_detach():
    # An adopted feed is a throwaway tmux client: detaching sends coding_term_close
    # (kills only the attach PTY; the user's tmux+claude survive).
    bridge, t = make_bridge()
    cd.adopt_discovered_tmux("cs_adopt", bridge=bridge,
                             store=_discovered_tmux_store())
    feed = bridge.feed_for("jc-abc123")
    assert feed is not None and feed.detach_closes_term is True
    feed.feed_close()
    assert any(f["type"] == "coding_term_close" and f["term_id"] == "jc-abc123"
               for (_d, f) in t.sent)


def test_launched_desktop_feed_does_not_close_on_detach():
    # A LAUNCHED desktop feed must NOT close on detach (a tab-close can't kill claude).
    bridge, t = make_bridge()
    feed = bridge.attach_feed(session_id="cs_l", device_id="d", term_id="jc-l",
                              rows=24, cols=80)  # detach_closes_term defaults False
    feed.feed_close()
    assert not any(f["type"] == "coding_term_close" for (_d, f) in t.sent)


def test_on_device_disconnect_closes_feeds():
    # A Mac WS drop must end the adopted feed's SSE (closed set + terminal_closed)
    # so the viewer sees "[detached]" instead of a frozen stream.
    bridge, t = make_bridge()
    cd.adopt_discovered_tmux("cs_adopt", bridge=bridge,
                             store=_discovered_tmux_store("dev-mac"))
    feed = bridge.feed_for("jc-abc123")
    assert feed is not None and not feed.closed.is_set()
    bridge.on_device_disconnect("dev-mac")
    assert feed.closed.is_set()
    # a different device's disconnect leaves it alone (re-adopt a fresh one)
    bridge2, t2 = make_bridge()
    cd.adopt_discovered_tmux("cs_adopt", bridge=bridge2,
                             store=_discovered_tmux_store("dev-mac"))
    bridge2.on_device_disconnect("dev-other")
    assert not bridge2.feed_for("jc-abc123").closed.is_set()


# ── discovered-tmux carries claude_session_id (offline-resume support) ────────

def test_ingest_tmux_persists_claude_session_id(tmp_path, monkeypatch):
    store = _temp_store(tmp_path)
    _discovered("dev-csid", [
        {"kind": "tmux", "tmux_name": "jc-live", "cwd": "/w/p",
         "title": "p", "last_activity": 5.0, "claude_session_id": "sess-77"},
    ], store, monkeypatch)
    s = store.list_sessions(device_id="dev-csid")[0]
    assert s["source"] == "discovered-tmux"
    assert s["claude_session_id"] == "sess-77"  # resumable when the Mac goes offline


def test_ingest_tmux_csid_dedups_matching_live_transcript(tmp_path, monkeypatch):
    # A live tmux carrying csid X + a live transcript ALSO reporting X (same cwd)
    # must collapse to ONE drivable tmux row (no duplicate history copy).
    store = _temp_store(tmp_path)
    _discovered("dev-d", [
        {"kind": "tmux", "tmux_name": "jc-live", "cwd": "/w/p",
         "title": "p", "last_activity": 5.0, "claude_session_id": "X"},
        {"kind": "transcript", "claude_session_id": "X", "cwd": "/w/p",
         "summary": "hist", "last_activity": 5.0, "live": True},
    ], store, monkeypatch)
    rows = store.list_sessions(device_id="dev-d")
    assert len(rows) == 1
    assert rows[0]["source"] == "discovered-tmux"
    assert rows[0]["claude_session_id"] == "X"


def test_ingest_tmux_empty_csid_does_not_wipe_existing(tmp_path, monkeypatch):
    store = _temp_store(tmp_path)
    _discovered("dev-w", [
        {"kind": "tmux", "tmux_name": "jc-x", "cwd": "/w/p",
         "claude_session_id": "keep"}], store, monkeypatch)
    # a later push without the csid must not erase it
    _discovered("dev-w", [
        {"kind": "tmux", "tmux_name": "jc-x", "cwd": "/w/p"}], store, monkeypatch)
    assert store.list_sessions(device_id="dev-w")[0]["claude_session_id"] == "keep"


# ── activity_state: live working/waiting/idle from the Mac ───────────────────


def test_ingest_discovered_writes_activity_state(tmp_path, monkeypatch):
    store = _temp_store(tmp_path)
    _discovered("dev-act", [
        {"kind": "tmux", "tmux_name": "claude-a", "cwd": "/w/a", "title": "a",
         "activity_state": "working"},
    ], store, monkeypatch)
    assert store.list_sessions(device_id="dev-act")[0]["activity_state"] == "working"
    # next push updates it
    _discovered("dev-act", [
        {"kind": "tmux", "tmux_name": "claude-a", "cwd": "/w/a", "title": "a",
         "activity_state": "waiting"},
    ], store, monkeypatch)
    assert store.list_sessions(device_id="dev-act")[0]["activity_state"] == "waiting"
    # a push WITHOUT activity_state (capture failed / old client) must NOT wipe it
    _discovered("dev-act", [
        {"kind": "tmux", "tmux_name": "claude-a", "cwd": "/w/a", "title": "a"},
    ], store, monkeypatch)
    assert store.list_sessions(device_id="dev-act")[0]["activity_state"] == "waiting"


def test_on_device_disconnect_clears_activity_state(tmp_path, monkeypatch):
    store = _temp_store(tmp_path)
    _discovered("dev-on", [
        {"kind": "tmux", "tmux_name": "claude-a", "cwd": "/w/a", "title": "a",
         "activity_state": "working"},
    ], store, monkeypatch)
    _discovered("dev-other", [
        {"kind": "tmux", "tmux_name": "claude-b", "cwd": "/w/b", "title": "b",
         "activity_state": "working"},
    ], store, monkeypatch)
    monkeypatch.setattr(cd, "_resolve_store", lambda: store, raising=True)
    cd.get_desktop_bridge().on_device_disconnect("dev-on")
    # the disconnected device's row is cleared; lifecycle status is untouched...
    row = store.list_sessions(device_id="dev-on")[0]
    assert row["activity_state"] is None
    assert row["status"] == "running"
    # ...and a DIFFERENT device's session is left intact.
    assert store.list_sessions(device_id="dev-other")[0]["activity_state"] == "working"
