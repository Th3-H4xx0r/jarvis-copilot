"""A schedule on "Default" follows the one default — a harness when one is set (2026-10-12):
"can you add support for a harness to be used as the default instead of it being a single model only"."""
from cron import scheduler


class _Store:
    def __init__(self, default):
        self.default = default

    def effective(self, surface):
        assert surface == "schedule"
        return self.default


def test_a_job_on_default_runs_the_default_harness(monkeypatch):
    monkeypatch.setattr("agent.harness.store.store_for_home", lambda: _Store("router"))
    assert scheduler._job_harness_id({"prompt": "x"}) == "router"


def test_a_jobs_own_pick_wins(monkeypatch):
    monkeypatch.setattr("agent.harness.store.store_for_home", lambda: _Store("router"))
    assert scheduler._job_harness_id({"prompt": "x", "harness_id": "mine"}) == "mine"
    assert scheduler._job_harness_id({"prompt": "x", "model": "@anthropic-api:claude-haiku-5-5"}) == ""


def test_single_default_means_the_default_model(monkeypatch):
    monkeypatch.setattr("agent.harness.store.store_for_home", lambda: _Store("single"))
    assert scheduler._job_harness_id({"prompt": "x"}) == ""


def test_a_broken_store_means_the_default_model(monkeypatch):
    def boom():
        raise OSError("no state dir")
    monkeypatch.setattr("agent.harness.store.store_for_home", boom)
    assert scheduler._job_harness_id({"prompt": "x"}) == ""
