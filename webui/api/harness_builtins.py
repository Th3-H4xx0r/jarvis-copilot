"""The harnesses every install starts with. Code constants: duplicable, never deleted.

The graphs live in ``agent.harness.builtins`` (the scheduler reads them too);
the web UI keeps its own fast-lane lookup (its profile-aware voice config).
"""
from __future__ import annotations

import api.config  # noqa: F401  (puts the JarvisCopilot checkout on sys.path for agent.*)
from agent.harness.builtins import CLAUDE_REF, DEFAULT_FAST, builtin_harnesses  # noqa: F401

_DEFAULT_FAST = DEFAULT_FAST


def fast_model_ref() -> str:
    """The configured fast lane (``voice.fast_lane``) as a picker ref."""
    try:
        from api.voice import get_voice_lane_config
        fl = (get_voice_lane_config() or {}).get("fast_lane") or {}
        if fl.get("model") and fl.get("provider"):
            return f"@{fl['provider']}:{fl['model']}"
    except Exception:
        pass
    return _DEFAULT_FAST
