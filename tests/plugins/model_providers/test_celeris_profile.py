"""Celeris profile: per-model base URLs, reasoning wire shape, decision models."""
from __future__ import annotations

import pytest


@pytest.fixture
def celeris():
    import model_tools  # noqa: F401  (plugin discovery)
    import providers
    p = providers.get_provider_profile("celeris")
    assert p is not None
    return p


def test_registered_with_chat_models_and_decision_model(celeris):
    assert celeris.display_name == "Celeris"
    assert celeris.env_vars[0] == "CELERIS_API_KEY"
    assert "celeris-1" in celeris.fallback_models and "celeris-1-magnus" in celeris.fallback_models
    assert "celeris-1-decision" in celeris.decision_models
    assert not set(celeris.decision_models) & set(celeris.fallback_models)


@pytest.mark.parametrize("model,base,url", [
    ("celeris-1", None, "https://inference.celeris.ai/celeris-1/v1"),
    ("celeris-1-magnus", "https://inference.celeris.ai", "https://inference.celeris.ai/celeris-1-magnus/v1"),
    ("@celeris:celeris-1-magnus", None, "https://inference.celeris.ai/celeris-1-magnus/v1"),
    ("celeris-1", "https://inference.celeris.ai/v1", "https://inference.celeris.ai/celeris-1/v1"),
])
def test_url_per_model(celeris, model, base, url):
    assert celeris.base_url_for_model(model, base) == url


def test_url_from_pasted_per_model_root(celeris):
    pasted = "https://inference.celeris.ai/celeris-1/v1/"
    assert celeris.base_url_for_model("celeris-1-magnus", pasted) == "https://inference.celeris.ai/celeris-1-magnus/v1"


def test_other_providers_url_unchanged():
    import model_tools  # noqa: F401
    import providers
    assert providers.model_base_url("gmi", "x", "https://api.gmi-serving.com/v1") == "https://api.gmi-serving.com/v1"
    assert providers.model_base_url("celeris", "celeris-1", "https://inference.celeris.ai") == \
        "https://inference.celeris.ai/celeris-1/v1"
    assert providers.model_base_url("", "m", "u") == "u"
    assert providers.model_base_url("no-such-provider", "m", "u") == "u"


def test_is_decision_model():
    import model_tools  # noqa: F401
    import providers
    assert providers.is_decision_model("celeris", "celeris-1-decision")
    assert providers.is_decision_model("celeris", "@celeris:celeris-1-decision")
    assert not providers.is_decision_model("celeris", "celeris-1")
    assert not providers.is_decision_model("gmi", "celeris-1-decision")
    assert not providers.is_decision_model(None, None)


@pytest.mark.parametrize("rc,extra,top", [
    (None, {"chat_template_kwargs": {"enable_thinking": False}}, {}),
    ({"effort": "medium"}, {"chat_template_kwargs": {"enable_thinking": False}}, {}),
    ({"effort": "high"}, {"chat_template_kwargs": {"enable_thinking": True}}, {}),
    ({"effort": "xhigh"}, {"chat_template_kwargs": {"enable_thinking": True}}, {}),
    ({"enabled": False, "effort": "high"}, {"chat_template_kwargs": {"enable_thinking": False}}, {}),
])
def test_celeris_1_thinking(celeris, rc, extra, top):
    assert celeris.build_api_kwargs_extras(reasoning_config=rc, model="celeris-1") == (extra, top)


@pytest.mark.parametrize("rc,extra,top", [
    (None, {}, {}),
    ({"effort": "none"}, {"chat_template_kwargs": {"enable_thinking": False}}, {}),
    ({"enabled": False}, {"chat_template_kwargs": {"enable_thinking": False}}, {}),
    ({"effort": "minimal"}, {}, {"reasoning_effort": "low"}),
    ({"effort": "low"}, {}, {"reasoning_effort": "low"}),
    ({"effort": "medium"}, {}, {"reasoning_effort": "medium"}),
    ({"effort": "high"}, {}, {"reasoning_effort": "xhigh"}),
    ({"effort": "max"}, {}, {"reasoning_effort": "xhigh"}),
])
def test_magnus_reasoning(celeris, rc, extra, top):
    assert celeris.build_api_kwargs_extras(reasoning_config=rc, model="celeris-1-magnus") == (extra, top)


def test_output_budget_default(celeris):
    assert celeris.default_max_tokens == 16384
