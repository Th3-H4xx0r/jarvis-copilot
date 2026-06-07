"""get_cli_sessions() must never block /api/sessions on the slow uncached scan.

Regression for the prod hang where the 20-40s `_load_cli_sessions_uncached`
ran while holding `_CLI_SESSIONS_CACHE_LOCK`, so every concurrent /api/sessions
request piled up on the lock (and a volatile cache key meant it re-loaded on
nearly every request).
"""
import threading
import time

from api import models


def _setup(monkeypatch, load_secs=0.4):
    key = ("h", "p", "db")
    monkeypatch.setattr(models, "_resolve_cli_sessions_context",
                        lambda: ("h", "db", "p", key))
    calls = {"n": 0}

    def _slow_load(home, db, profile):
        calls["n"] += 1
        time.sleep(load_secs)
        return [{"id": "cli_1", "is_cli_session": True}]

    monkeypatch.setattr(models, "_load_cli_sessions_uncached", _slow_load)
    models.clear_cli_sessions_cache()
    return calls


def test_first_call_returns_immediately_then_caches(monkeypatch):
    calls = _setup(monkeypatch, load_secs=0.4)
    t0 = time.monotonic()
    first = models.get_cli_sessions()
    elapsed = time.monotonic() - t0
    assert elapsed < 0.15, f"first call blocked {elapsed:.2f}s on the slow load"
    assert first == []  # nothing cached yet; background refresh kicked

    # Background refresh completes → subsequent call returns the data, fast.
    deadline = time.monotonic() + 3.0
    got = []
    while time.monotonic() < deadline:
        got = models.get_cli_sessions()
        if got:
            break
        time.sleep(0.05)
    assert got and got[0]["id"] == "cli_1"
    assert calls["n"] == 1  # exactly one load happened


def test_concurrent_polls_do_not_stack_loads(monkeypatch):
    calls = _setup(monkeypatch, load_secs=0.5)
    # Fire many concurrent first-time polls while the single refresh is in flight.
    results = []

    def _poll():
        t0 = time.monotonic()
        models.get_cli_sessions()
        results.append(time.monotonic() - t0)

    threads = [threading.Thread(target=_poll) for _ in range(12)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    # None of the 12 concurrent polls blocked on the 0.5s load.
    assert all(e < 0.2 for e in results), f"a poll blocked: {max(results):.2f}s"
    # Let the in-flight refresh finish, then confirm only ONE load ran.
    time.sleep(0.7)
    assert calls["n"] == 1
