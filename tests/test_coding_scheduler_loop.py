from agent.coding_scheduler_loop import make_send, tick, run_loop


class FakeManager:
    def __init__(self, fail=False):
        self.sent = []
        self.fail = fail

    def send_message(self, sid, text):
        if self.fail:
            raise RuntimeError("boom")
        self.sent.append((sid, text))


class FakeScheduler:
    """run_due calls send for each queued due item."""
    def __init__(self, due_items):
        self.due_items = due_items  # list of (sid, msg)

    def run_due(self, now, send):
        for sid, msg in self.due_items:
            send(sid, msg)
        return len(self.due_items)


def test_make_send_relays_and_swallows_errors():
    ok = FakeManager()
    send = make_send(ok)
    send("s1", "hi")
    assert ok.sent == [("s1", "hi")]
    # a failing manager must not raise out of send
    make_send(FakeManager(fail=True))("s2", "boom")  # no exception


def test_tick_fires_due_into_sessions():
    mgr = FakeManager()
    sched = FakeScheduler([("s1", "go"), ("s2", "stop")])
    n = tick(sched, mgr, now=123.0)
    assert n == 2
    assert mgr.sent == [("s1", "go"), ("s2", "stop")]


def test_run_loop_ticks_until_stop():
    mgr = FakeManager()
    sched = FakeScheduler([("s1", "x")])
    calls = {"n": 0}

    def stop():
        # stop after 3 ticks
        return calls["n"] >= 3

    def now_fn():
        calls["n"] += 1
        return float(calls["n"])

    run_loop(sched, mgr, stop=stop, interval=0, now_fn=now_fn, sleep_fn=lambda _: None)
    # ticked 3 times (each tick sent the one due item)
    assert len(mgr.sent) == 3
