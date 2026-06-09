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
    store = FakeStore([_row("cs_1", "jc-1", activity_state="working")])
    drv = FakeDriver({"jc-1": "esc to interrupt"})
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
