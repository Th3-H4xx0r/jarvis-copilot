"""Request shape for current Claude models (4.6+, the 5.x line, Fable/Mythos).

Claude Sonnet 5.5 rejected "Hello" with HTTP 400 `"thinking.type.enabled" is not
supported for this model` — the adapter only recognised 4.6/4.7 as adaptive-thinking
models, so every newer model got the legacy `budget_tokens` thinking + temperature=1.
"""

import pytest

from agent.anthropic_adapter import build_anthropic_kwargs

MSGS = [{"role": "user", "content": "Hello"}]


def _kwargs(model, effort="medium"):
    return build_anthropic_kwargs(model, MSGS, None, None, {"enabled": True, "effort": effort},
                                  base_url="https://api.anthropic.com")


@pytest.mark.parametrize("model", [
    "claude-sonnet-5-5", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5",
    "claude-opus-4-8", "claude-fable-5-1", "claude-fable-5", "anthropic/claude-sonnet-5.5",
])
def test_current_models_use_adaptive_thinking_and_no_sampling_params(model):
    k = _kwargs(model, effort="xhigh")
    assert k["thinking"]["type"] == "adaptive"
    assert "budget_tokens" not in k["thinking"]
    assert k["output_config"]["effort"] == "xhigh"   # 4.7+ accept xhigh
    assert "temperature" not in k and "top_p" not in k and "top_k" not in k


def test_4_6_stays_adaptive_without_xhigh():
    k = _kwargs("claude-sonnet-4-6", effort="xhigh")
    assert k["thinking"]["type"] == "adaptive"
    assert k["output_config"]["effort"] == "max"


@pytest.mark.parametrize("model", ["claude-sonnet-4-5", "claude-sonnet-4-20250514", "claude-opus-4-1-20250805"])
def test_pre_4_6_models_keep_budget_thinking(model):
    k = _kwargs(model)
    assert k["thinking"]["type"] == "enabled" and k["thinking"]["budget_tokens"] > 0
