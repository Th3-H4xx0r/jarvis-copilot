from agent.coding_status_loop import run_status_tick, run_loop


class FakeStore:
    def __init__(self, rows):
        self.rows = rows
        self.updates = []

    def list_sessions(self):
        return [dict(r) for r in self.rows]

    def update_session(self, sid, **fields):
        self.updates.append((sid, fields))
        for r in self.rows:
            if r["id"] == sid:
                r.update(fields)


class FakeDriver:
    def __init__(self, panes, raise_for=None):
        self.panes = panes
        self.raise_for = raise_for or set()
        self.captured = []

    def capture_pane(self, *, tmux_name, lines=80):
        self.captured.append(tmux_name)
        if tmux_name in self.raise_for:
            raise RuntimeError("tmux gone")
        return self.panes.get(tmux_name, "")


class FakeManager:
    def __init__(self, store, driver):
        self.store = store
        self.driver = driver


def _row(sid, tmux, status="running", host="server", activity_state=None):
    return {"id": sid, "tmux_name": tmux, "status": status, "host": host,
            "activity_state": activity_state}


def test_tick_writes_activity_state():
    store = FakeStore([_row("cs_1", "jc-1")])
    drv = FakeDriver({"jc-1": "✻ Running… (esc to interrupt)"})
    n = run_status_tick(FakeManager(store, drv))
    assert n == 1
    assert store.updates == [("cs_1", {"activity_state": "working"})]


def test_skips_desktop_host():
    store = FakeStore([_row("cs_d", "jc-d", host="desktop")])
    drv = FakeDriver({"jc-d": "esc to interrupt"})
    assert run_status_tick(FakeManager(store, drv)) == 0
    assert store.updates == []
    assert drv.captured == []  # never even captured a desktop pane


def test_skips_stopped_sessions():
    store = FakeStore([_row("cs_s", "jc-s", status="stopped")])
    drv = FakeDriver({"jc-s": "esc to interrupt"})
    assert run_status_tick(FakeManager(store, drv)) == 0


def test_no_update_when_unchanged():
    # Real Claude status hints are parenthesized — "(esc to interrupt)" — which is
    # how we tell them from claude's prose. A bare unparenthesized hint isn't a
    # status line.
    store = FakeStore([_row("cs_1", "jc-1", activity_state="working")])
    drv = FakeDriver({"jc-1": "✻ Working… (3s · esc to interrupt)"})
    assert run_status_tick(FakeManager(store, drv)) == 0
    assert store.updates == []


def test_one_bad_row_doesnt_stop_tick():
    store = FakeStore([_row("cs_bad", "jc-bad"), _row("cs_ok", "jc-ok")])
    drv = FakeDriver({"jc-ok": "Do you want to proceed?\n❯ 1. Yes"},
                     raise_for={"jc-bad"})
    n = run_status_tick(FakeManager(store, drv))
    assert n == 1
    assert ("cs_ok", {"activity_state": "waiting"}) in store.updates


def test_skips_rows_without_tmux_name():
    store = FakeStore([_row("cs_n", None)])
    drv = FakeDriver({})
    assert run_status_tick(FakeManager(store, drv)) == 0


def test_run_loop_stops():
    store = FakeStore([_row("cs_1", "jc-1")])
    drv = FakeDriver({"jc-1": "esc to interrupt"})
    calls = {"n": 0}

    def stop():
        calls["n"] += 1
        return calls["n"] > 3

    run_loop(FakeManager(store, drv), stop=stop, interval=0,
             sleep_fn=lambda _: None)
    # stop() is checked before each tick → 3 ticks ran (n=1,2,3 false; n=4 true)
    assert calls["n"] == 4


def test_disk_guard_blocks_on_critical_and_recovers():
    from agent.coding_status_loop import run_disk_guard
    from agent.coding_disk_guard import DiskGuardConfig
    from collections import namedtuple
    DU = namedtuple("DU", "total used free")
    cfg = DiskGuardConfig(warn_pct=85, critical_pct=92, resume_pct=80,
                          min_free_bytes=10, staging_max_age_s=1800)
    state = {"blocked": False}
    blocks, terminated, gced, notified = [], [], [], []

    # critical (95% used) -> assert block flag + terminate device syncs + GC + notify
    out = run_disk_guard(
        cfg=cfg, state=state, disk_usage=lambda: DU(100, 95, 5),
        set_block=lambda block, reason: blocks.append(block),
        terminate_syncs=lambda: terminated.append(True),
        gc_staging=lambda c, now=None: gced.append(True),
        notify=lambda k, du: notified.append(k))
    assert out == "critical"
    assert state["blocked"] is True
    assert blocks == [True]              # flag asserted this tick
    assert terminated == [True]          # device syncs terminated on transition
    assert gced and notified == ["critical"]

    # still critical -> flag RE-asserted (keeps TTL fresh), but NO second terminate
    run_disk_guard(
        cfg=cfg, state=state, disk_usage=lambda: DU(100, 95, 5),
        set_block=lambda block, reason: blocks.append(block),
        terminate_syncs=lambda: terminated.append(True),
        gc_staging=lambda c, now=None: gced.append(True), notify=lambda k, du: None)
    assert blocks == [True, True]        # re-stamped every tick
    assert terminated == [True]          # NOT re-terminated (no new transition)

    # recovered (50% used, free above floor) -> unblock
    out = run_disk_guard(
        cfg=cfg, state=state, disk_usage=lambda: DU(100, 50, 50),
        set_block=lambda block, reason: blocks.append(block),
        terminate_syncs=lambda: terminated.append(True),
        gc_staging=lambda c, now=None: gced.append(True), notify=lambda k, du: None)
    assert out == "ok"
    assert state["blocked"] is False
    assert blocks == [True, True, False]
    assert len(gced) == 2  # GC ran on the two critical passes, not the recovery


class _DriverWithRun(FakeDriver):
    def __init__(self, panes, gone):
        super().__init__(panes)
        self.gone = set(gone)

    def _run(self, argv):
        import types
        name = argv[-1]
        rc = 1 if name in self.gone else 0
        return types.SimpleNamespace(returncode=rc, stderr="")


def test_reaps_dead_server_tmux():
    # A server session whose tmux is GONE must be reaped (not left as a fake
    # running/idle with a dead terminal, which the resume idempotency would wrongly
    # reuse). A session that HAD come alive (running/idle) is a clean end -> stopped
    # (no scary "Error" badge, routes the UI to the ended panel instead of looping a
    # dead re-attach). A session still "starting" failed to launch -> error.
    store = FakeStore([_row("cs_dead", "jc-dead"),
                       _row("cs_failed", "jc-failed", status="starting"),
                       _row("cs_live", "jc-live")])
    drv = _DriverWithRun({"jc-live": "esc to interrupt"},
                         gone=["jc-dead", "jc-failed"])
    run_status_tick(FakeManager(store, drv))
    rows = {r["id"]: r for r in store.rows}
    assert rows["cs_dead"]["status"] == "stopped"        # clean end
    assert rows["cs_dead"]["activity_state"] is None
    assert rows["cs_failed"]["status"] == "error"        # never came alive
    assert rows["cs_live"]["status"] == "running"        # untouched
    # the dead ones were NOT pane-captured (we short-circuited on has-session)
    assert "jc-dead" not in drv.captured


def test_server_transition_dispatches_notifications(monkeypatch):
    # The SERVER has no plugin jc-client hook, so the poll must drive the
    # finished/needs-input pings on the real edges:
    #   working -> idle  => "stop" (finished);  * -> waiting => "notification".
    # Other edges (e.g. -> working, first-seen idle) must NOT ping.
    import sys
    import types

    from agent import coding_status_loop as csl

    calls = []
    fake = types.ModuleType("api.coding_routes")
    fake._dispatch_coding_notifications = lambda store, **kw: calls.append(kw)
    fake._EVENT_NOTIFY_KEY = {"stop": "finished", "notification": "needs_input"}
    fake._coding_settings = lambda store: {
        "events": {"finished": {"telegram": False},
                   "needs_input": {"telegram": False}}}
    fake._coding_alert_text = lambda store, row, event: ("T", "L")
    fake._send_coding_telegram = lambda text: calls.append({"tg": text})
    api_mod = types.ModuleType("api")
    api_mod.coding_routes = fake
    monkeypatch.setitem(sys.modules, "api", api_mod)
    monkeypatch.setitem(sys.modules, "api.coding_routes", fake)

    row = {"id": "x", "cwd": "/p"}
    csl._notify_server_transition({}, row, "working", "idle")
    assert [c.get("event") for c in calls] == ["stop"]
    calls.clear()
    csl._notify_server_transition({}, row, "idle", "waiting")
    assert [c.get("event") for c in calls] == ["notification"]
    calls.clear()
    csl._notify_server_transition({}, row, None, "working")
    assert calls == []                                   # -> working: no ping
    csl._notify_server_transition({}, row, None, "idle")
    assert calls == []                                   # first-seen idle: no ping


def test_server_transition_sends_telegram_when_enabled(monkeypatch):
    # When the telegram channel is on, the server poll sends it directly (no
    # notify.sh on the server to do it).
    import sys
    import types

    from agent import coding_status_loop as csl

    tg = []
    fake = types.ModuleType("api.coding_routes")
    fake._dispatch_coding_notifications = lambda store, **kw: None
    fake._EVENT_NOTIFY_KEY = {"stop": "finished", "notification": "needs_input"}
    fake._coding_settings = lambda store: {
        "events": {"needs_input": {"telegram": True}}}
    fake._coding_alert_text = lambda store, row, event: ("🔔 needs you", "proj")
    fake._send_coding_telegram = lambda text: tg.append(text)
    api_mod = types.ModuleType("api")
    api_mod.coding_routes = fake
    monkeypatch.setitem(sys.modules, "api", api_mod)
    monkeypatch.setitem(sys.modules, "api.coding_routes", fake)

    csl._notify_server_transition({}, {"id": "x", "cwd": "/p"}, "idle", "waiting")
    assert tg == ["🔔 needs you — proj"]


def test_no_run_method_skips_reap():
    # A driver without _run (e.g. desktop/future host) just skips the reap.
    store = FakeStore([_row("cs_1", "jc-1")])
    drv = FakeDriver({"jc-1": ""})  # no _run attr
    run_status_tick(FakeManager(store, drv))
    assert store.rows[0]["status"] == "running"  # not reaped
