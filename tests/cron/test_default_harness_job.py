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


NODE_ON_CODEX = {"id": "codex", "name": "Codex", "nodes": [
    {"id": "in", "type": "message", "x": 0, "y": 0},
    {"id": "a", "type": "answer", "model": "@openai-codex:gpt-6.1-sol", "x": 200, "y": 0}],
    "edges": [{"from": "in", "to": "a", "when": "always"}]}


class _DocStore:
    def get(self, hid):
        return NODE_ON_CODEX if hid == "codex" else None


def _no_credentials(**kw):
    raise RuntimeError("no OpenAI Codex login")


def test_a_default_harness_without_credentials_runs_the_default_model(monkeypatch):
    monkeypatch.setattr("agent.harness.store.store_for_home", lambda: _DocStore())
    monkeypatch.setattr("jarviscopilot_cli.runtime_provider.resolve_runtime_provider", _no_credentials)
    plan, doc, note = scheduler._plan_job_harness({"id": "j"}, "check email", harness_id="codex",
                                                  default_model="claude-sonnet-5-5",
                                                  default_provider="anthropic-api", follows_default=True)
    assert plan is None and doc is None and "credentials" in note and "codex" in note.lower()


def test_a_jobs_own_harness_is_not_second_guessed(monkeypatch):
    monkeypatch.setattr("agent.harness.store.store_for_home", lambda: _DocStore())
    monkeypatch.setattr("jarviscopilot_cli.runtime_provider.resolve_runtime_provider", _no_credentials)
    plan, doc, _ = scheduler._plan_job_harness({"id": "j", "harness_id": "codex"}, "check email",
                                               harness_id="codex", default_model="claude-sonnet-5-5",
                                               default_provider="anthropic-api")
    assert plan is not None and doc["id"] == "codex"
