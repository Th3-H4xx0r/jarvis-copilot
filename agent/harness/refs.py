"""``@provider:model`` model refs.

The web UI registers its own ``split_provider_qualified_model`` (the one place
that knows every provider id and the ``custom:<host>:<port>`` forms); without
it (the gateway / scheduler) the provider is the first segment, with
``custom:<slug>`` and ``custom:<host>:<port>`` kept whole.
"""
from __future__ import annotations

import logging
from typing import Callable, Optional, Tuple

logger = logging.getLogger(__name__)

_splitter: Optional[Callable[[str], Optional[Tuple[str, str]]]] = None


def register_splitter(fn: Optional[Callable[[str], Optional[Tuple[str, str]]]]) -> None:
    """``fn("@provider:model") -> (provider, model) | None``; None restores the default."""
    global _splitter
    _splitter = fn


def _default_split(ref: str) -> Optional[Tuple[str, str]]:
    parts = ref[1:].split(":")
    if parts[0] == "custom" and len(parts) >= 3:
        # custom:<host>:<port>:<model> — the port belongs to the provider slug.
        if len(parts) >= 4 and parts[2].isdigit():
            provider, model = ":".join(parts[:3]), ":".join(parts[3:])
        else:
            provider, model = ":".join(parts[:2]), ":".join(parts[2:])
    else:
        provider, model = parts[0], ":".join(parts[1:])
    if not provider or not model:
        return None
    return provider, model


def split_ref(ref) -> Optional[Tuple[str, str]]:
    """``"@provider:model"`` → ``(provider, model)``; None when ``ref`` is not
    provider-qualified (a bare model name or empty)."""
    ref = str(ref or "").strip()
    if not (ref.startswith("@") and ":" in ref):
        return None
    if _splitter is not None:
        try:
            got = _splitter(ref)
            if got:
                return got[0], got[1]
        except Exception:
            logger.debug("harness model splitter failed for %s", ref, exc_info=True)
    return _default_split(ref)


def is_decision_ref(ref) -> bool:
    """A decision model answers typed questions (a Route's router), never a chat."""
    try:
        from providers import is_decision_model
        q = split_ref(ref)
        return bool(q) and is_decision_model(q[0], q[1])
    except Exception:
        return False


def claude_cli_installed() -> bool:
    """Whether the Claude Code CLI is on this machine (the web UI's check)."""
    import os
    import shutil

    command = (os.getenv("HERMES_CLAUDE_CODE_COMMAND", "").strip()
               or os.getenv("CLAUDE_CLI_PATH", "").strip() or "claude")
    return shutil.which(command) is not None


def route_anthropic_via_claude_code(model, provider, base_url=None):
    """Run ``anthropic`` (subscription) picks on the Claude Code CLI when it is
    installed — the same decision the web UI makes for chat
    (``api.config.route_anthropic_via_claude_code``): a subscription account
    gets HTTP 400 from the direct API while its CLI answers. ``anthropic-api``
    bills the API key and is never redirected. Returns ``(model, provider,
    base_url)``; a redirect leaves the base URL to the runtime resolver."""
    if str(provider or "").strip().lower() != "anthropic" or not claude_cli_installed():
        return model, provider, base_url
    return model, "claude-code", None
