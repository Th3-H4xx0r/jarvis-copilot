"""Anthropic API provider profile — Claude billed to ANTHROPIC_API_KEY only.

The plain ``anthropic`` provider also reads Claude subscription tokens (and the
WebUI reroutes it to the Claude Code CLI). This one never does: the key is the
only credential, it is always sent as ``x-api-key``
(``build_anthropic_client(force_api_key=True)``), and a missing key is an error
("No Anthropic API key configured") rather than a quiet switch to the
subscription. Runtime resolution: ``runtime_provider._resolve_anthropic_api_runtime``.
"""

import json
import logging
import urllib.request

from providers import register_provider
from providers.base import ProviderProfile

logger = logging.getLogger(__name__)


class AnthropicApiProfile(ProviderProfile):
    """Native Anthropic Messages API on an API key — x-api-key header."""

    def fetch_models(
        self,
        *,
        api_key: str | None = None,
        timeout: float = 8.0,
    ) -> list[str] | None:
        if not api_key:
            return None
        try:
            req = urllib.request.Request("https://api.anthropic.com/v1/models")
            req.add_header("x-api-key", api_key)
            req.add_header("anthropic-version", "2023-06-01")
            req.add_header("Accept", "application/json")
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                data = json.loads(resp.read().decode())
            return [
                m["id"]
                for m in data.get("data", [])
                if isinstance(m, dict) and "id" in m
            ]
        except Exception as exc:
            logger.debug("fetch_models(anthropic-api): %s", exc)
            return None


anthropic_api = AnthropicApiProfile(
    name="anthropic-api",
    display_name="Anthropic API",
    description="Claude on your Anthropic API key (billed to the key, not a Claude plan)",
    signup_url="https://console.anthropic.com/settings/keys",
    api_mode="anthropic_messages",
    env_vars=("ANTHROPIC_API_KEY",),
    base_url="https://api.anthropic.com",
    auth_type="api_key",
    default_aux_model="claude-haiku-4-5-20251001",
)

register_provider(anthropic_api)
