"""default_headers_for(): one host -> headers table for every client path."""

from unittest.mock import patch

import pytest

from agent.provider_headers import (
    KIMI_CODE_USER_AGENT,
    default_headers_for,
    qwen_portal_headers,
    routermint_headers,
)


def test_openrouter():
    headers = default_headers_for("https://openrouter.ai/api/v1")
    assert "HTTP-Referer" in headers and "X-Title" in headers


def test_ai_gateway():
    from agent.auxiliary_client import _AI_GATEWAY_HEADERS

    assert default_headers_for("https://ai-gateway.vercel.sh/v1") == _AI_GATEWAY_HEADERS


def test_nvidia_cloud_only():
    assert "X-BILLING-INVOKE-ORIGIN" in default_headers_for("https://integrate.api.nvidia.com/v1")
    assert default_headers_for("http://localhost:8000/v1", "nvidia") == {}


def test_routermint():
    assert default_headers_for("https://api.routermint.com/v1") == routermint_headers()


def test_copilot_vision_flag():
    plain = default_headers_for("https://api.githubcopilot.com")
    vision = default_headers_for("https://api.githubcopilot.com", is_vision=True)
    assert plain["Copilot-Integration-Id"] == "vscode-chat"
    assert "Copilot-Vision-Request" not in plain
    assert vision["Copilot-Vision-Request"] == "true"


def test_kimi_user_agent():
    assert default_headers_for("https://api.kimi.com/coding/v1") == {"User-Agent": KIMI_CODE_USER_AGENT}


def test_qwen_portal():
    assert default_headers_for("https://portal.qwen.ai/v1") == qwen_portal_headers()


def test_chatgpt_uses_token():
    with patch("agent.auxiliary_client._codex_cloudflare_headers", return_value={"originator": "x"}) as cf:
        assert default_headers_for("https://chatgpt.com/backend-api/codex", api_key="tok") == {"originator": "x"}
    cf.assert_called_once_with("tok")


def test_profile_headers_for_named_provider():
    from providers import get_provider_profile

    gmi = get_provider_profile("gmi")
    assert gmi is not None and gmi.default_headers
    assert default_headers_for("https://api.gmi-serving.com/v1", "gmi") == dict(gmi.default_headers)


def test_unknown_host_without_provider_is_empty():
    assert default_headers_for("https://api.example.com/v1") == {}
    assert default_headers_for("https://api.example.com/v1", "custom") == {}


# -- Paths that used to miss headers ------------------------------------------


def _custom_headers(client) -> dict:
    return dict(getattr(client, "_custom_headers", {}) or {})


@pytest.mark.parametrize(
    "base_url, header",
    [
        ("https://openrouter.ai/api/v1", "X-Title"),
        ("https://portal.qwen.ai/v1", "X-DashScope-AuthType"),
        ("https://api.routermint.com/v1", "User-Agent"),
    ],
)
def test_explicit_custom_endpoint_gets_host_headers(base_url, header):
    """The custom-endpoint aux path used to cover only kimi/copilot/nvidia."""
    from agent.auxiliary_client import resolve_provider_client

    client, _ = resolve_provider_client(
        "custom", model="m", explicit_base_url=base_url, explicit_api_key="k",
    )
    assert client is not None
    assert header in _custom_headers(client)


def test_async_client_gets_routermint_and_qwen_headers():
    """_to_async_client used to drop routermint / qwen-portal headers."""
    from openai import OpenAI

    from agent.auxiliary_client import _to_async_client

    for base_url, header in (
        ("https://api.routermint.com/v1", "User-Agent"),
        ("https://portal.qwen.ai/v1", "X-DashScope-AuthType"),
    ):
        async_client, _ = _to_async_client(OpenAI(api_key="k", base_url=base_url), "m")
        assert header in _custom_headers(async_client)
