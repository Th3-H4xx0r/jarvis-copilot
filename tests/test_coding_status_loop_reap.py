"""Tests for retiring stale DISCOVERED (Mac) coding sessions from the live fleet.

When a Mac disconnects, its discovered-tmux sessions used to linger forever at
status='running' (the disconnect handler only nulls activity_state), so the iOS
Live Activity / Dynamic Island kept showing dead sessions as gray "idle". The
reap retires them to status='stopped' once their owning device has been gone past
a grace window — restart-robust (recomputed each tick from the live connection
set) and self-healing (a reconnecting Mac's next discovery push revives them)."""
from agent.coding_status_loop import (
    REAP_GRACE,
    reap_disconnected_discovered,
    run_loop,
    should_reap_discovered,
)


def _drow(sid, *, device_id="dev1", source="discovered-tmux",
          status="running", activity_state="working", host="desktop"):
    return {"id": sid, "device_id": device_id, "source": source,
            "status": status, "activity_state": activity_state,
            "tmux_name": sid, "host": host}


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


# ── should_reap_discovered (pure) ─────────────────────────────────────────────

def test_reap_true_when_device_absent_past_grace():
    row = _drow("cs_1")
    assert should_reap_discovered(
        row, connected=set(), gone_since=100.0, now=100.0 + REAP_GRACE)


def test_no_reap_within_grace():
    row = _drow("cs_1")
    assert not should_reap_discovered(
        row, connected=set(), gone_since=100.0, now=100.0 + REAP_GRACE - 1)


def test_no_reap_when_device_connected():
    row = _drow("cs_1", device_id="dev1")
    assert not should_reap_discovered(
        row, connected={"dev1"}, gone_since=0.0, now=1e9)


def test_no_reap_on_first_absence_unclocked():
    # gone_since=None means we haven't clocked the device absent yet → never reap.
    row = _drow("cs_1")
    assert not should_reap_discovered(
        row, connected=set(), gone_since=None, now=1e9)


def test_no_reap_non_discovered_tmux():
    row = _drow("cs_1", source="discovered-transcript")
    assert not should_reap_discovered(
        row, connected=set(), gone_since=0.0, now=1e9)
    row2 = _drow("cs_2", source="launched", host="server")
    assert not should_reap_discovered(
        row2, connected=set(), gone_since=0.0, now=1e9)


def test_reaps_suffixed_discovered_tmux_source():
    # Match the rest of the module's `startswith("discovered-tmux")` convention
    # (ingest_discovered, _is_transcript_idle) so a future suffixed source like
    # "discovered-tmux:adopted" can't silently slip past the reap and re-introduce
    # the lingering-dead-session bug.
    row = _drow("cs_1", source="discovered-tmux:adopted")
    assert should_reap_discovered(
        row, connected=set(), gone_since=100.0, now=100.0 + REAP_GRACE)


def test_live_statuses_match_la_push():
    # The reap must consider exactly the statuses the Live Activity treats as live,
    # or it could reap a row the LA still shows (or vice-versa). Guard against drift
    # between the two module-level copies.
    import agent.coding_la_push as la
    from agent.coding_status_loop import _LIVE_STATUSES
    assert _LIVE_STATUSES == la._LIVE_STATUSES


def test_no_reap_non_live_status():
    row = _drow("cs_1", status="stopped")
    assert not should_reap_discovered(
        row, connected=set(), gone_since=0.0, now=1e9)


# ── reap_disconnected_discovered (orchestrator) ───────────────────────────────

def test_first_absence_stamps_clock_does_not_reap():
    store = FakeStore([_drow("cs_1", device_id="dev1")])
    clock = {}
    n = reap_disconnected_discovered(
        store, connected_ids=[], now=1000.0, gone_since=clock)
    assert n == 0
    assert store.updates == []          # nothing retired on first sighting
    assert clock == {"dev1": 1000.0}    # clock started


def test_reaps_after_grace_elapses():
    store = FakeStore([_drow("cs_1", device_id="dev1"),
                       _drow("cs_2", device_id="dev1")])
    clock = {"dev1": 1000.0}
    n = reap_disconnected_discovered(
        store, connected_ids=[], now=1000.0 + REAP_GRACE, gone_since=clock)
    assert n == 2
    rows = {r["id"]: r for r in store.rows}
    assert rows["cs_1"]["status"] == "stopped"
    assert rows["cs_1"]["activity_state"] is None
    assert rows["cs_2"]["status"] == "stopped"


def test_connected_device_clears_clock_and_survives():
    store = FakeStore([_drow("cs_1", device_id="dev1")])
    clock = {"dev1": 1.0}  # stale stamp from a previous blip
    n = reap_disconnected_discovered(
        store, connected_ids=["dev1"], now=1e9, gone_since=clock)
    assert n == 0
    assert store.updates == []
    assert clock == {}  # cleared because the device is connected again


def test_transcript_and_server_rows_never_reaped():
    store = FakeStore([
        _drow("cs_t", source="discovered-transcript"),
        _drow("cs_s", source="launched", host="server"),
    ])
    clock = {"dev1": 0.0}
    n = reap_disconnected_discovered(
        store, connected_ids=[], now=1e9, gone_since=clock)
    assert n == 0
    assert store.updates == []


def test_already_stopped_row_not_touched():
    store = FakeStore([_drow("cs_1", status="stopped")])
    clock = {"dev1": 0.0}
    n = reap_disconnected_discovered(
        store, connected_ids=[], now=1e9, gone_since=clock)
    assert n == 0
    assert store.updates == []


def test_reap_fires_notify_only_when_something_retired(monkeypatch):
    import sys
    import types

    notified = {"n": 0}
    fake_events = types.ModuleType("api.coding_events")
    fake_events.notify = lambda: notified.__setitem__("n", notified["n"] + 1)
    api_mod = types.ModuleType("api")
    api_mod.coding_events = fake_events
    monkeypatch.setitem(sys.modules, "api", api_mod)
    monkeypatch.setitem(sys.modules, "api.coding_events", fake_events)

    store = FakeStore([_drow("cs_1", device_id="dev1")])
    # first sighting → no reap → no notify
    reap_disconnected_discovered(
        store, connected_ids=[], now=1000.0, gone_since={})
    assert notified["n"] == 0
    # past grace → reap → notify once
    reap_disconnected_discovered(
        store, connected_ids=[], now=1000.0 + REAP_GRACE,
        gone_since={"dev1": 1000.0})
    assert notified["n"] == 1


# ── wiring: run_loop reaps every tick ─────────────────────────────────────────

class _Drv:
    def capture_pane(self, *, tmux_name, lines=80):
        return ""


class _Mgr:
    def __init__(self, store):
        self.store = store
        self.driver = _Drv()


def test_run_loop_reaps_each_tick(monkeypatch):
    from agent import coding_status_loop as csl

    calls = {"n": 0}
    monkeypatch.setattr(
        csl, "reap_disconnected_discovered",
        lambda store, **kw: (calls.__setitem__("n", calls["n"] + 1), 0)[1])

    mgr = _Mgr(FakeStore([]))
    ticks = {"n": 0}

    def stop():
        ticks["n"] += 1
        return ticks["n"] > 3

    run_loop(mgr, stop=stop, interval=0, sleep_fn=lambda _: None,
             disk_guard=None)
    assert calls["n"] == 3  # one reap per tick
