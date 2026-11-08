"""Default HTTP headers for an OpenAI-compatible client, chosen by base URL.

One function, ``default_headers_for()``, used by every place that builds a
client: the main agent (init and credential swap) and every auxiliary client
path.  Host-specific headers win; otherwise the provider profile's
``default_headers`` apply.
"""

from __future__ import annotations

import platform as _platform
from typing import Dict, Optional

from utils import base_url_host_matches

# Kimi's /coding endpoint only accepts requests that identify as a coding
# agent; anything else gets a 403.
KIMI_CODE_USER_AGENT = "claude-code/0.1.0"

# Qwen Portal headers mimic the QwenCode CLI for portal.qwen.ai.
_QWEN_CODE_VERSION = "0.14.1"


def routermint_headers() -> Dict[str, str]:
    """The User-Agent RouterMint needs to avoid Cloudflare 1010 blocks."""
    from jarviscopilot_cli import __version__ as _version

    return {"User-Agent": f"HermesAgent/{_version}"}


def qwen_portal_headers() -> Dict[str, str]:
    """Headers the Qwen Portal API requires."""
    ua = f"QwenCode/{_QWEN_CODE_VERSION} ({_platform.system().lower()}; {_platform.machine()})"
    return {
        "User-Agent": ua,
        "X-DashScope-CacheControl": "enable",
        "X-DashScope-UserAgent": ua,
        "X-DashScope-AuthType": "qwen-oauth",
    }


def _profile_headers(provider: Optional[str], base_url: str) -> Dict[str, str]:
    from providers import get_provider_profile

    name = (provider or "").strip().lower()
    if not name:
        from agent.model_metadata import _infer_provider_from_url

        name = _infer_provider_from_url(base_url) or ""
    if not name:
        return {}
    profile = get_provider_profile(name)
    if profile is None or not profile.default_headers:
        return {}
    return dict(profile.default_headers)


def default_headers_for(
    base_url: str,
    provider: Optional[str] = None,
    api_key: str = "",
    is_vision: bool = False,
) -> Dict[str, str]:
    """Return the default headers a client for ``base_url`` should send.

    ``provider`` picks the profile whose ``default_headers`` apply when the
    host has no rule of its own; without it the provider is inferred from the
    URL.  ``api_key`` is needed for chatgpt.com (the account id comes from
    the token).  ``is_vision`` adds Copilot's vision marker.  Returns ``{}``
    when nothing applies.
    """
    from agent import auxiliary_client as aux

    url = str(base_url or "")
    if base_url_host_matches(url, "openrouter.ai"):
        return aux.build_or_headers()
    if base_url_host_matches(url, "ai-gateway.vercel.sh"):
        return dict(aux._AI_GATEWAY_HEADERS)
    if base_url_host_matches(url, "integrate.api.nvidia.com"):
        return aux.build_nvidia_nim_headers(url)
    if base_url_host_matches(url, "api.routermint.com"):
        return routermint_headers()
    if base_url_host_matches(url, "api.githubcopilot.com"):
        from jarviscopilot_cli.copilot_auth import copilot_request_headers

        return copilot_request_headers(is_agent_turn=True, is_vision=is_vision)
    if base_url_host_matches(url, "api.kimi.com"):
        return {"User-Agent": KIMI_CODE_USER_AGENT}
    if base_url_host_matches(url, "portal.qwen.ai"):
        return qwen_portal_headers()
    if base_url_host_matches(url, "chatgpt.com"):
        return aux._codex_cloudflare_headers(api_key or "")
    return _profile_headers(provider, url)
