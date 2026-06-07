"""get_cli_sessions() must not pile up on the global cache lock.

Regression for the prod hang where the 20-40s `_load_cli_sessions_uncached`
ran while holding `_CLI_SESSIONS_CACHE_LOCK`, so every concurrent /api/sessions
request serialized on the lock. The new design: freshness is preserved (a
state.db change reloads), but the slow load runs under a per-key single-flight
lock OUTSIDE the global lock, so concurrent callers serve the last (stale)
snapshot instantly instead of blocking.
"""
import threading
import time

from api import models


class Ctl:
    def __init__(self):
        self.sig = ("s1",)
        self.load_count = 0
        self.load_secs = 0.0
        self.value = [{"id": "cli_1", "is_cli_session": True}]


def _setup(monkeypatch, ctl):
    monkeypatch.setattr(models, "_resolve_cli_sessions_context",
                        lambda: ("h", "db", "p", ("KEY",), ctl.sig))

    def _load(home, db, profile):
        ctl.load_count += 1
        time.sleep(ctl.load_secs)
        return [dict(v) for v in ctl.value]

    monkeypatch.setattr(models, "_load_cli_sessions_uncached", _load)
    models.clear_cli_sessions_cache()


def test_warm_stale_serves_instantly_while_loader_runs(monkeypatch):
    ctl = Ctl()
    _setup(monkeypatch, ctl)
    # prime the cache (cold load, fast)
    assert models.get_cli_sessions()[0]["id"] == "cli_1"
    assert ctl.load_count == 1

    # stat changes (stale) AND the reload is slow
    ctl.sig = ("s2",)
    ctl.load_secs = 0.5
    ctl.value = [{"id": "cli_2", "is_cli_session": True}]

    # a background request becomes the single loader (blocks ~0.5s)
    bg = threading.Thread(target=models.get_cli_sessions)
    bg.start()
    time.sleep(0.08)  # let it grab the load lock + start loading

    # main request: stale -> serve the OLD snapshot INSTANTLY, not block 0.5s
    t0 = time.monotonic()
    got = models.get_cli_sessions()
    elapsed = time.monotonic() - t0
    assert elapsed < 0.2, f"stale read blocked {elapsed:.2f}s on the slow load"
    assert got[0]["id"] == "cli_1"  # stale data served while loader runs

    bg.join()
    # loader finished -> fresh data now cached
    assert models.get_cli_sessions()[0]["id"] == "cli_2"
    assert ctl.load_count == 2  # prime + the one reload (single-flight)


def test_concurrent_stale_polls_single_flight(monkeypatch):
    ctl = Ctl()
    _setup(monkeypatch, ctl)
    models.get_cli_sessions()              # prime (load_count=1)
    ctl.sig = ("s2",)                      # mark stale
    ctl.load_secs = 0.4

    results = []

    def poll():
        t0 = time.monotonic()
        models.get_cli_sessions()
        results.append(time.monotonic() - t0)

    threads = [threading.Thread(target=poll) for _ in range(12)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    # at most one poll became the loader (~0.4s); the rest served stale instantly
    fast = [r for r in results if r < 0.15]
    assert len(fast) >= 11, f"too many polls blocked: {sorted(results)}"
    assert ctl.load_count == 2  # prime + exactly ONE reload
