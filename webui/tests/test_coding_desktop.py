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
from agent import coding_sync as sync_core  # noqa: E402


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


# ── sync: initial direction PUSH vs PULL ─────────────────────────────────────


def test_sync_push_when_remote_empty(tmp_path):
    # Server has files, remote is empty -> PUSH: send each file to the device.
    (tmp_path / "a.txt").write_text("alpha", encoding="utf-8")
    (tmp_path / "sub").mkdir()
    (tmp_path / "sub" / "b.txt").write_text("bravo", encoding="utf-8")

    bridge, t = make_bridge()
    s = cd.DesktopSyncSession(sync_id="sync-1", device_id="dev-P",
                              root=str(tmp_path), bridge=bridge)
    bridge.register_sync(s)
    assert s.open() is True
    # device replies with an EMPTY manifest
    bridge.on_frame("dev-P", {"type": "coding_sync_manifest",
                              "sync_id": "sync-1", "manifest": {}})
    assert s.direction == "push"
    files = t.frames("coding_sync_file")
    sent_paths = sorted(f["relpath"] for f in files)
    assert sent_paths == ["a.txt", "sub/b.txt"]
    # bytes are base64 of the real file contents
    by_path = {f["relpath"]: base64.b64decode(f["b64"]) for f in files}
    assert by_path["a.txt"] == b"alpha"
    assert by_path["sub/b.txt"] == b"bravo"
    assert s.reconciled.is_set()
    # no pull requests on a push
    assert t.frames("coding_sync_get") == []


def test_sync_pull_when_remote_has_files(tmp_path):
    # Remote has files, so PULL: request each remote file; inbound files land.
    bridge, t = make_bridge()
    s = cd.DesktopSyncSession(sync_id="sync-2", device_id="dev-Q",
                              root=str(tmp_path), bridge=bridge)
    bridge.register_sync(s)
    s.open()
    remote_manifest = {
        "main.py": (3, 111.0, "h1"),
        "pkg/util.py": (5, 222.0, "h2"),
    }
    bridge.on_frame("dev-Q", {"type": "coding_sync_manifest",
                              "sync_id": "sync-2", "manifest": remote_manifest})
    assert s.direction == "pull"
    gets = sorted(f["relpath"] for f in t.frames("coding_sync_get"))
    assert gets == ["main.py", "pkg/util.py"]
    assert not s.reconciled.is_set()  # nothing received yet

    # device streams the requested files back
    bridge.on_frame("dev-Q", {"type": "coding_sync_file", "sync_id": "sync-2",
                              "relpath": "main.py",
                              "b64": base64.b64encode(b"print(1)").decode()})
    bridge.on_frame("dev-Q", {"type": "coding_sync_file", "sync_id": "sync-2",
                              "relpath": "pkg/util.py",
                              "b64": base64.b64encode(b"X=1\n").decode()})
    assert (tmp_path / "main.py").read_bytes() == b"print(1)"
    assert (tmp_path / "pkg" / "util.py").read_bytes() == b"X=1\n"
    assert s.reconciled.is_set()  # all pulled files arrived
    # no pushes on a pull
    assert t.frames("coding_sync_file") == []  # we SENT none (only received)


def test_sync_event_modify_pulls_and_delete_applies(tmp_path):
    bridge, t = make_bridge()
    (tmp_path / "gone.txt").write_text("bye", encoding="utf-8")
    s = cd.DesktopSyncSession(sync_id="sync-3", device_id="dev-R",
                              root=str(tmp_path), bridge=bridge)
    bridge.register_sync(s)
    # an incremental modify -> request the bytes
    bridge.on_frame("dev-R", {"type": "coding_sync_event", "sync_id": "sync-3",
                              "relpath": "changed.py", "kind": "modified"})
    assert any(f["relpath"] == "changed.py" for f in t.frames("coding_sync_get"))
    # an incremental delete -> apply locally
    bridge.on_frame("dev-R", {"type": "coding_sync_event", "sync_id": "sync-3",
                              "relpath": "gone.txt", "kind": "deleted"})
    assert not (tmp_path / "gone.txt").exists()


def test_sync_file_refuses_path_traversal(tmp_path):
    bridge, t = make_bridge()
    s = cd.DesktopSyncSession(sync_id="sync-4", device_id="dev-S",
                              root=str(tmp_path), bridge=bridge)
    bridge.register_sync(s)
    bridge.on_frame("dev-S", {"type": "coding_sync_file", "sync_id": "sync-4",
                              "relpath": "../escape.txt",
                              "b64": base64.b64encode(b"pwned").decode()})
    # nothing written outside the root
    assert not (tmp_path.parent / "escape.txt").exists()


def test_unregistered_sync_id_is_ignored():
    bridge, t = make_bridge()
    # No DesktopSyncSession registered for this id -> frame dropped, no crash.
    bridge.on_frame("dev-T", {"type": "coding_sync_manifest",
                              "sync_id": "ghost", "manifest": {}})
    assert t.sent == []


def test_start_sync_for_launch_opens_when_enabled(tmp_path):
    (tmp_path / "x.txt").write_text("hi", encoding="utf-8")
    bridge, t = make_bridge()
    s = cd.start_sync_for_launch(
        "dev-L", session_id="cs_L", cwd=str(tmp_path),
        sync={"enabled": True, "remote_path": "/Users/me/proj"}, bridge=bridge)
    assert s is not None
    opens = t.frames("coding_sync_open")
    assert len(opens) == 1
    # the open frame carries the REMOTE path the desktop watches
    assert opens[0]["path"] == "/Users/me/proj"
    assert opens[0]["sync_id"] == "sync-cs_L"
    # bridge routes inbound frames for this sync id
    assert bridge.sync_for("sync-cs_L") is s


def test_start_sync_for_launch_noop_when_disabled(tmp_path):
    bridge, t = make_bridge()
    assert cd.start_sync_for_launch("dev-N", session_id="cs_N",
                                    cwd=str(tmp_path), sync=None,
                                    bridge=bridge) is None
    assert cd.start_sync_for_launch("dev-N", session_id="cs_N",
                                    cwd=str(tmp_path), sync={"enabled": False},
                                    bridge=bridge) is None
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

    opens = t.frames("coding_sync_open")
    assert len(opens) == 1
    f = opens[0]
    assert f["sync_id"] == "sync-cs_run"
    assert f["path"] == "/Users/me/proj"  # the desktop's remote path
    # the session is registered for inbound-frame routing under its sync id
    assert bridge.sync_for("sync-cs_run") is not None


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
    opens = t.frames("coding_sync_open")
    assert len(opens) == 1
    # no explicit remote_path -> the desktop opens the session cwd
    assert opens[0]["path"] == str(tmp_path)
    assert opens[0]["sync_id"] == "sync-cs_d"


def test_resync_device_noop_when_nothing_synced(tmp_path):
    bridge, t = make_bridge()
    store = FakeStore([
        {"id": "cs_srv", "status": "running", "host": "server",
         "cwd": str(tmp_path), "sync_config": None},
    ])
    assert cd.resync_device("dev-N", store=store, bridge=bridge) == 0
    assert t.frames("coding_sync_open") == []


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
    assert t.frames("coding_sync_open") == []


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
        db._handle_message(conn, {"type": "coding_sync_event",
                                  "sync_id": "s", "relpath": "f", "kind": "x"})
        # a non-coding type is NOT routed to the handler
        db._handle_message(conn, {"type": "pong"})
        assert [g[1]["type"] for g in got] == [
            "coding_term_output", "coding_sync_event"]
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
