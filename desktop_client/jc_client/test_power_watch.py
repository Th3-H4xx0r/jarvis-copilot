"""Sleep and wake, from the Mac app or from a clock jump."""
from jc_client.power_watch import PowerWatch


def test_notify_calls_handlers():
    seen = []
    pw = PowerWatch(lambda: seen.append("sleep"), lambda: seen.append("wake"))
    pw.notify("will_sleep")
    pw.notify("did_wake")
    pw.notify("bogus")
    assert seen == ["sleep", "wake"]


def test_power_jump_detects_wake():
    t = {"wall": 1000.0, "mono": 50.0}
    seen = []
    pw = PowerWatch(lambda: None, lambda: seen.append("wake"),
                    clock=lambda: t["wall"], mono=lambda: t["mono"])
    t["wall"] += 10
    t["mono"] += 10
    pw.check_jump()
    assert seen == []
    t["wall"] += 600   # asleep: the wall clock moved, the monotonic one didn't
    t["mono"] += 5
    pw.check_jump()
    assert seen == ["wake"]
