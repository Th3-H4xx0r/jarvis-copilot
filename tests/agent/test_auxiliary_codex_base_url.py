"""A ChatGPT (Codex) model with its own address keeps the Codex adapter.

Live 2026-11-18 → 11-21: iMessage memory stored nothing for three days — its writer passes the provider's base URL
(https://chatgpt.com/backend-api/codex) to call_llm, an explicit base URL turned the provider into "custom" (a
plain chat-completions client), and the Codex backend answered 404 {'detail': 'Not Found'}.
"""
from agent import auxiliary_client as aux


def test_the_codex_backend_address_keeps_the_codex_provider():
    for url in ("https://chatgpt.com/backend-api/codex", "https://chatgpt.com/backend-api/codex/"):
        provider, model, base_url, _key, _mode = aux._resolve_task_provider_model(
            provider="openai-codex", model="gpt-6-luna", base_url=url)
        assert (provider, model, base_url) == ("openai-codex", "gpt-6-luna", None)


def test_any_other_explicit_address_is_still_a_custom_endpoint():
    provider, _m, base_url, _k, _a = aux._resolve_task_provider_model(
        provider="openai-codex", model="m", base_url="http://localhost:8080/v1")
    assert (provider, base_url) == ("custom", "http://localhost:8080/v1")
    provider, _m, base_url, _k, _a = aux._resolve_task_provider_model(
        provider="openrouter", model="m", base_url="https://openrouter.ai/api/v1")
    assert provider == "custom"
