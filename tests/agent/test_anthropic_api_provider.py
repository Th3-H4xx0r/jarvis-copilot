"""The `anthropic-api` provider: Anthropic billed to the API key, never a Claude subscription token."""

from unittest.mock import patch

from agent.anthropic_adapter import build_anthropic_client

# Synthetic keys. His real key is an `sk-ant-usr…` key, which `_is_oauth_token`
# would otherwise read as an OAuth/setup token.
USR_KEY = "sk-ant-usr01-" + "k" * 40


def _client_kwargs(*args, **kwargs):
    with patch("agent.anthropic_adapter._anthropic_sdk") as sdk:
        build_anthropic_client(*args, **kwargs)
        return sdk.Anthropic.call_args[1]


def test_force_api_key_sends_x_api_key_whatever_the_prefix():
    kw = _client_kwargs(USR_KEY, "https://api.anthropic.com", force_api_key=True)
    assert kw["api_key"] == USR_KEY
    assert "auth_token" not in kw
    headers = kw.get("default_headers", {})
    assert "user-agent" not in headers and "x-app" not in headers
    assert "oauth-2025-04-20" not in headers.get("anthropic-beta", "")


def test_force_api_key_works_without_a_base_url():
    kw = _client_kwargs(USR_KEY, None, force_api_key=True)
    assert kw["api_key"] == USR_KEY and "auth_token" not in kw


def test_without_the_flag_the_old_detection_is_unchanged():
    kw = _client_kwargs(USR_KEY, "https://api.anthropic.com")
    assert "auth_token" in kw


def test_profile_is_a_messages_provider_on_the_api_key_only():
    from providers import get_provider_profile

    profile = get_provider_profile("anthropic-api")
    assert profile is not None
    assert profile.api_mode == "anthropic_messages"
    assert profile.env_vars == ("ANTHROPIC_API_KEY",)
    # The old provider keeps its own name; the new one is not an alias of it.
    assert get_provider_profile("anthropic").name == "anthropic"


def test_registry_lists_it_after_anthropic_so_auto_detect_is_unchanged():
    from jarviscopilot_cli.auth import PROVIDER_REGISTRY

    ids = list(PROVIDER_REGISTRY)
    assert "anthropic-api" in ids
    assert ids.index("anthropic") < ids.index("anthropic-api")
    assert PROVIDER_REGISTRY["anthropic-api"].api_key_env_vars == ("ANTHROPIC_API_KEY",)


def test_model_names_normalise_like_anthropic():
    from jarviscopilot_cli.model_normalize import normalize_model_for_provider

    assert normalize_model_for_provider("anthropic/claude-sonnet-5.5", "anthropic-api") == "claude-sonnet-5-5"
    assert normalize_model_for_provider("claude-sonnet-5-5", "anthropic-api") == "claude-sonnet-5-5"


def test_usage_is_priced_at_anthropic_rates():
    from agent.usage_pricing import resolve_billing_route

    route = resolve_billing_route("claude-sonnet-5-5", provider="anthropic-api")
    assert route.provider == "anthropic"


def test_an_agent_built_without_api_mode_speaks_anthropic_messages_on_the_key():
    """WebUI compress / handoff / updates summaries build AIAgent without api_mode."""
    from run_agent import AIAgent

    with (
        patch("run_agent.get_tool_definitions", return_value=[]),
        patch("run_agent.check_toolset_requirements", return_value={}),
        patch("run_agent.OpenAI"),
        patch("agent.anthropic_adapter._anthropic_sdk") as sdk,
    ):
        agent = AIAgent(
            provider="anthropic-api", api_key=USR_KEY, base_url="https://api.anthropic.com",
            model="claude-sonnet-5-5", quiet_mode=True, skip_context_files=True, skip_memory=True,
        )
        kw = sdk.Anthropic.call_args[1]

    assert agent.api_mode == "anthropic_messages"
    assert agent.provider == "anthropic-api"
    assert agent._is_anthropic_oauth is False
    assert kw["api_key"] == USR_KEY and "auth_token" not in kw


def test_images_in_tool_results_reach_the_model_like_native_anthropic():
    from tools.vision_tools import _supports_media_in_tool_results

    assert _supports_media_in_tool_results("anthropic-api", "claude-sonnet-5-5") is True
