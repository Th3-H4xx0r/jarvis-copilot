"""Regression checks for #1896 — context-length fallback ignores config overrides.

When the agent's ``context_compressor`` reports 0 (fresh / cached / transitioning
agent), the context window comes from ``agent.model_metadata``. Called with only
model + base_url it falls through to the 256K default even when config.yaml sets
``model.context_length: 1048576`` or a ``custom_providers`` per-model override, and
a context-management plugin then auto-compresses far too early (compress flood,
429s, credential pool exhausted). ``session_model.context_length_for`` is the one
resolver every fallback uses; these tests pin what it passes and how it degrades.
"""

import sys
import types
from pathlib import Path

import pytest

from api.session_model import context_length_for

REPO = Path(__file__).resolve().parent.parent


@pytest.fixture
def resolver(monkeypatch):
    calls = []

    def get_model_context_length(model, base_url, **kwargs):
        calls.append((model, base_url, kwargs))
        return 1_048_576

    module = types.ModuleType("agent.model_metadata")
    module.get_model_context_length = get_model_context_length
    monkeypatch.setitem(sys.modules, "agent.model_metadata", module)
    return calls


def test_config_overrides_reach_the_resolver(resolver):
    cfg = {"model": {"context_length": "1048576"}, "custom_providers": [{"name": "x"}]}
    assert context_length_for("m", "http://b", provider="p", cfg=cfg) == 1_048_576
    assert resolver == [("m", "http://b", {
        "config_context_length": 1_048_576,
        "provider": "p",
        "custom_providers": [{"name": "x"}],
    })]


@pytest.mark.parametrize("raw", ["not-a-number", 0, -5, None])
def test_an_invalid_config_context_length_is_ignored(resolver, raw):
    context_length_for("m", cfg={"model": {"context_length": raw}, "custom_providers": "nope"})
    assert resolver[0][2]["config_context_length"] is None
    assert resolver[0][2]["custom_providers"] is None


def test_an_older_resolver_signature_gets_the_two_argument_call(monkeypatch):
    calls = []

    def legacy(model, base_url):
        calls.append((model, base_url))
        return 200_000

    module = types.ModuleType("agent.model_metadata")
    module.get_model_context_length = legacy
    monkeypatch.setitem(sys.modules, "agent.model_metadata", module)
    assert context_length_for("m", "u", cfg={}) == 200_000
    assert calls == [("m", "u")]


def test_a_failing_resolver_reads_as_unknown(monkeypatch):
    module = types.ModuleType("agent.model_metadata")
    module.get_model_context_length = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("down"))
    monkeypatch.setitem(sys.modules, "agent.model_metadata", module)
    assert context_length_for("m", cfg={}) == 0


def test_both_streaming_fallbacks_use_the_shared_resolver():
    src = (REPO / "api" / "streaming.py").read_text(encoding="utf-8")
    assert "get_model_context_length" not in src
    assert src.count("context_length_for(") == 2
    assert src.count("provider=resolved_provider or ''") >= 2
    assert src.count("cfg=_cfg") >= 2


def test_session_load_fallback_uses_the_shared_resolver():
    src = (REPO / "api" / "session_routes.py").read_text(encoding="utf-8")
    helper = src[src.find("def _resolve_context_length_for_session_model"):]
    helper = helper[:helper.find("\ndef ", 1)]
    assert "context_length_for(model_for_lookup, provider=provider" in helper
