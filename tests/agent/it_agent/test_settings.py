"""The supervisor model: the setting, else the Default harness's Background node — never the Claude Code
CLI or the fast lane (they can't follow code-checked JSON phases)."""
import pytest

from agent.it_agent import settings
from agent.it_agent.model import Limits

BG = "@anthropic-api:claude-sonnet-5-5"


class Store:
    def __init__(self, nodes):
        self.nodes = nodes

    def effective(self, surface):
        assert surface == "default"
        return "mine"

    def get(self, hid):
        return {"id": hid, "nodes": self.nodes} if hid == "mine" else None


@pytest.fixture(autouse=True)
def providers(monkeypatch):
    from agent.harness import builtins, llm
    monkeypatch.setattr(llm, "resolve_ref", lambda ref: (ref.split(":")[-1], ref[1:].split(":")[0], None))
    monkeypatch.setattr(builtins, "fast_model_ref", lambda: "@celeris:celeris-fast")


def _store():
    return Store([{"id": "r", "type": "router", "model": "@celeris:celeris-1"},
                  {"id": "bg", "type": "background", "model": BG}])


def test_supervisor_setting_wins():
    assert settings.supervisor_ref({"it_agent": {"supervisor_model": "@openrouter:x"}}, _store()) == ("@openrouter:x", "")


def test_default_is_default_harness_background_node():
    assert settings.supervisor_ref({}, _store()) == (BG, "")


def test_never_claude_code_or_fast_lane():
    ref, err = settings.supervisor_ref({"it_agent": {"supervisor_model": "@claude-code:claude-sonnet-5-5"}}, _store())
    assert ref is None and err == ("IT tasks can't run on the Claude Code CLI (@claude-code:claude-sonnet-5-5): set "
                                   "it_agent.supervisor_model in config.yaml to an API model.")
    ref, err = settings.supervisor_ref({"it_agent": {"supervisor_model": "@celeris:celeris-fast"}}, _store())
    assert ref is None and "fast lane" in err and "it_agent.supervisor_model" in err


def test_no_background_node_error_names_the_setting():
    want = ("No supervisor model for IT tasks: set it_agent.supervisor_model in config.yaml (your Default harness "
            "has no Background node).")
    assert settings.supervisor_ref({}, Store([{"id": "r", "type": "router", "model": "x"}])) == (None, want)
    assert settings.supervisor_ref({}, Store([{"id": "bg", "type": "background", "model": "@session"}])) == (None, want)


def test_limits_and_fast_ref():
    assert settings.limits({"it_agent": {"max_rethinks": 5, "reboot_wait_minutes": "x"}}) == Limits(max_rethinks=5)
    assert settings.limits({}) == Limits()
    assert settings.fast_ref({"computer": {"planner_model": "@celeris:celeris-1"}}) == "@celeris:celeris-1"
    assert settings.fast_ref({}) is None
