"""Celeris wiring outside the runtime resolver: aux/fallback client URL, missing-key
contract, duplicate reasoning, context + pricing, decision models never chat."""
from types import SimpleNamespace

import pytest


@pytest.fixture(autouse=True)
def _discover(monkeypatch):
    import model_tools  # noqa: F401
    monkeypatch.delenv("CELERIS_BASE_URL", raising=False)


def test_aux_client_uses_model_url(monkeypatch):
    monkeypatch.setenv("CELERIS_API_KEY", "ck_test")
    from agent.auxiliary_client import resolve_provider_client
    client, model = resolve_provider_client("celeris", model="celeris-1-magnus")
    assert model == "celeris-1-magnus"
    assert str(client.base_url).rstrip("/") == "https://inference.celeris.ai/celeris-1-magnus/v1"


def test_missing_credential_matches_celeris():
    from agent.error_classifier import MISSING_CELERIS_API_KEY, is_missing_credential
    assert is_missing_credential(f"{MISSING_CELERIS_API_KEY}. Add CELERIS_API_KEY")


def test_reasoning_equal_to_answer_is_dropped():
    from agent.agent_runtime_helpers import extract_reasoning
    msg = SimpleNamespace(reasoning="The answer is 4.", content="The answer is 4.")
    assert extract_reasoning(None, msg) is None
    msg = SimpleNamespace(reasoning="Add 2 and 2.", content="The answer is 4.")
    assert extract_reasoning(None, msg) == "Add 2 and 2."


def test_context_and_pricing():
    from agent.model_metadata import DEFAULT_CONTEXT_LENGTHS
    from agent.usage_pricing import get_pricing_entry
    assert DEFAULT_CONTEXT_LENGTHS["celeris-1"] == 131072
    entry = get_pricing_entry("celeris-1-magnus", provider="celeris")
    assert entry is not None and float(entry.output_cost_per_million) == 0.70


def test_decision_model_refuses_to_chat():
    from run_agent import AIAgent
    with pytest.raises(Exception, match="decision model"):
        AIAgent(model="celeris-1-decision", provider="celeris", api_key="ck_test",
                base_url="https://inference.celeris.ai", api_mode="chat_completions",
                quiet_mode=True, enabled_toolsets=[], skip_context_files=True, skip_memory=True)


def test_switch_model_moves_to_the_new_model_url():
    from run_agent import AIAgent
    agent = AIAgent(model="celeris-1", provider="celeris", api_key="ck_test",
                    base_url="https://inference.celeris.ai/celeris-1/v1", api_mode="chat_completions",
                    quiet_mode=True, enabled_toolsets=[], skip_context_files=True, skip_memory=True)
    agent.switch_model("celeris-1-magnus", "celeris", api_key="ck_test",
                       base_url="https://inference.celeris.ai/celeris-1/v1", api_mode="chat_completions")
    assert agent.base_url == "https://inference.celeris.ai/celeris-1-magnus/v1"
    assert str(agent.client.base_url).rstrip("/") == "https://inference.celeris.ai/celeris-1-magnus/v1"


def test_agent_client_gets_model_url():
    from run_agent import AIAgent
    agent = AIAgent(model="celeris-1-magnus", provider="celeris", api_key="ck_test",
                    base_url="https://inference.celeris.ai", api_mode="chat_completions",
                    quiet_mode=True, enabled_toolsets=[], skip_context_files=True, skip_memory=True)
    assert agent.base_url == "https://inference.celeris.ai/celeris-1-magnus/v1"
    assert str(agent.client.base_url).rstrip("/") == "https://inference.celeris.ai/celeris-1-magnus/v1"
