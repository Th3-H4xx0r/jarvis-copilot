"""`@provider:model` ids where the MODEL part carries colons (Ollama tags such
as `gemma4:31b`) must split on the provider boundary, not the last colon.
Splitting on the last colon read `@ollama-cloud:gemma4:31b` as provider
"ollama-cloud:gemma4" + model "31b", flagged it as a stale cross-provider
model and swapped in the default model (Claude) — the voice picker's Gemma
row answered as Sonnet."""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "webui"))

from api import config as config_mod
from api import routes


def test_split_ollama_tagged_model():
    assert config_mod.split_provider_qualified_model("@ollama-cloud:gemma4:31b") == ("ollama-cloud", "gemma4:31b")
    assert routes._split_provider_qualified_model("@ollama-cloud:gemma4:31b") == ("gemma4:31b", "ollama-cloud")


def test_split_plain_provider_model():
    assert routes._split_provider_qualified_model("@anthropic:claude-sonnet-5") == ("claude-sonnet-5", "anthropic")


def test_split_custom_provider_with_tagged_model():
    assert routes._split_provider_qualified_model("@custom:macbook-ollama:llama3.2:latest") == (
        "llama3.2:latest", "custom:macbook-ollama")


def test_split_custom_host_port_slug():
    # custom:<host>:<port> is one slug; the model is only the last segment.
    assert routes._split_provider_qualified_model("@custom:10.0.0.5:11434:llama3") == ("llama3", "custom:10.0.0.5:11434")


def test_non_qualified_passthrough():
    assert routes._split_provider_qualified_model("gemma4:31b") == ("gemma4:31b", None)
    assert routes._split_provider_qualified_model("") == ("", None)


def test_resolve_keeps_tagged_ollama_pick(monkeypatch):
    monkeypatch.setattr(routes, "get_available_models", lambda: {
        "active_provider": "claude-code", "default_model": "claude-sonnet-5",
        "groups": [{"provider_id": "ollama-cloud", "models": []},
                   {"provider_id": "claude-code", "models": []}],
    })
    model, provider, normalized = routes._resolve_compatible_session_model_state(
        "@ollama-cloud:gemma4:31b", "ollama-cloud")
    assert model == "@ollama-cloud:gemma4:31b"
    assert provider == "ollama-cloud"
    assert normalized is False


def test_split_custom_host_port_slug_with_tagged_model():
    """`custom:<host>:<port>` is ONE slug and the model may still carry a tag."""
    assert routes._split_provider_qualified_model("@custom:10.0.0.5:11434:llama3.2:latest") == (
        "llama3.2:latest", "custom:10.0.0.5:11434")


def test_config_resolver_agrees_with_the_shared_helper():
    """resolve_model_provider and the normaliser must split identically, or a
    session model routes to a provider the catalogue has never heard of."""
    for model in ("@ollama-cloud:gemma4:31b",
                  "@custom:macbook-ollama:llama3.2:latest",
                  "@custom:10.0.0.5:11434:llama3",
                  "@custom:10.0.0.5:11434:llama3.2:latest",
                  "@custom:my-key:llama3.2:8b:latest",
                  "@anthropic:claude-sonnet-5"):
        provider, bare = config_mod.split_provider_qualified_model(model)
        resolved_model, resolved_provider, _ = config_mod.resolve_model_provider(model)
        assert (resolved_model, resolved_provider) == (bare, provider), model
