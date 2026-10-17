"""The coding housekeeping thread: Live Activity push each tick, the server disk
guard every Nth tick (moved here from the deleted coding status loop)."""
from collections import namedtuple

from api import coding_housekeeping as hk
from agent.coding_disk_guard import DiskGuardConfig

DU = namedtuple("DU", "total used free")


def _cfg():
    return DiskGuardConfig(warn_pct=85, critical_pct=92, resume_pct=80,
                           min_free_bytes=10, staging_max_age_s=1800)


def test_disk_guard_blocks_on_critical_and_recovers():
    cfg, state = _cfg(), {"blocked": False}
    blocks, terminated, gced, notified = [], [], [], []

    def run(du, notify=lambda k, d: None):
        return hk.run_disk_guard(
            cfg=cfg, state=state, disk_usage=lambda: du,
            set_block=lambda block, reason: blocks.append(block),
            terminate_syncs=lambda: terminated.append(True),
            gc_staging=lambda c, now=None: gced.append(True), notify=notify)

    assert run(DU(100, 95, 5), notify=lambda k, d: notified.append(k)) == "critical"
    assert state["blocked"] is True and blocks == [True]
    assert terminated == [True] and gced and notified == ["critical"]

    run(DU(100, 95, 5))                  # still critical: re-asserted, not re-terminated
    assert blocks == [True, True] and terminated == [True]

    assert run(DU(100, 50, 50)) == "ok"  # recovered
    assert state["blocked"] is False and blocks == [True, True, False]
    assert len(gced) == 2


def test_loop_pushes_every_tick_and_guards_every_nth():
    ticks, guards, n = [], [], {"i": 0}

    def stop():
        n["i"] += 1
        return n["i"] > 9

    hk.run_loop("store", stop=stop, sleep_fn=lambda _s: None,
                on_tick=lambda s: ticks.append(s), disk_guard=lambda: guards.append(1),
                disk_guard_every=4)
    assert ticks == ["store"] * 9
    assert len(guards) == 3              # ticks 0, 4, 8


def test_a_failing_tick_does_not_stop_the_loop():
    n = {"i": 0}

    def stop():
        n["i"] += 1
        return n["i"] > 3

    def boom(_s):
        raise RuntimeError("apns down")

    hk.run_loop(None, stop=stop, sleep_fn=lambda _s: None, on_tick=boom, disk_guard=None)
    assert n["i"] == 4
