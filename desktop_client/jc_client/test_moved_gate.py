"""A session that continued on the server refuses new prompts in its stale Mac copy."""
import threading
import time

from jc_client.moved_gate import REASON, MovedGate


def test_gate_blocks_moved():
    g = MovedGate()
    g.set_moved({"claude|s1"})
    assert g.check("claude", "s1") == ("block", REASON)
    assert g.check("claude", "s2") == ("allow", "")


def test_gate_holds_after_wake_then_allows_when_unreachable():
    g = MovedGate()
    g.hold_until_confirmed(0.2)
    t0 = time.monotonic()
    assert g.check("claude", "s1") == ("allow", "")
    assert time.monotonic() - t0 >= 0.18


def test_gate_confirm_releases_waiters_early_with_the_new_list():
    g = MovedGate()
    g.hold_until_confirmed(5.0)
    out = {}

    def ask():
        out["r"] = g.check("claude", "s1")

    t = threading.Thread(target=ask)
    t.start()
    time.sleep(0.05)
    g.set_moved({"claude|s1"})
    t.join(1.0)
    assert out["r"] == ("block", REASON)


def test_gate_unblocks_after_confirm_not_moved():
    g = MovedGate()
    g.set_moved({"claude|s1"})
    g.set_moved(set())
    assert g.check("claude", "s1") == ("allow", "")
