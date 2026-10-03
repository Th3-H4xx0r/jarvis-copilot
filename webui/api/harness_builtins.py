"""The harnesses every install starts with. Code constants: duplicable, never deleted."""
from __future__ import annotations

CLAUDE_REF = "@claude-code:claude-sonnet-5-5"
_DEFAULT_FAST = "@ollama-cloud:gemma4:31b"


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


def builtin_harnesses(fast_ref: str, claude_ref: str = CLAUDE_REF) -> list:
    """``single``'s answer model is the placeholder ``@session``: the runner
    swaps in the chat's own model."""
    msg = {"id": "in", "type": "message", "x": 40, "y": 40}
    return [
        {"id": "fast-claude", "name": "Fast + Claude", "icon": "⚡", "builtin": True,
         "nodes": [dict(msg),
                   {"id": "fast", "type": "answer", "model": fast_ref, "tools": "lean", "x": 40, "y": 180},
                   {"id": "claude", "type": "background", "model": claude_ref, "tools": "all",
                    "deliver": "speak_or_notify", "x": 260, "y": 320}],
         "edges": [{"from": "in", "to": "fast", "when": "always"},
                   {"from": "fast", "to": "claude", "when": "handoff"}]},
        {"id": "router", "name": "Router", "icon": "🧭", "builtin": True,
         "nodes": [dict(msg),
                   {"id": "route", "type": "route", "by": "rules", "x": 40, "y": 160, "labels": ["deep"],
                    "rules": [{"match": "keywords", "label": "deep",
                               "value": "code, coding, bug, refactor, research, investigate, "
                                        "analyse, analyze, essay, draft"},
                              {"match": "has_attachment", "value": True, "label": "deep"}]},
                   {"id": "fast", "type": "answer", "model": fast_ref, "tools": "lean", "x": 0, "y": 300},
                   {"id": "claude", "type": "answer", "model": claude_ref, "tools": "all", "x": 240, "y": 300}],
         "edges": [{"from": "in", "to": "route", "when": "always"},
                   {"from": "route", "to": "claude", "when": "label:deep"},
                   {"from": "route", "to": "fast", "when": "default"}]},
        {"id": "fast-checked", "name": "Fast, Claude checks", "icon": "✅", "builtin": True,
         "nodes": [dict(msg),
                   {"id": "fast", "type": "answer", "model": fast_ref, "tools": "lean", "x": 40, "y": 180},
                   {"id": "check", "type": "review", "model": claude_ref, "deliver": "post_if_changed",
                    "x": 260, "y": 320}],
         "edges": [{"from": "in", "to": "fast", "when": "always"},
                   {"from": "fast", "to": "check", "when": "always"}]},
        {"id": "single", "name": "Single model", "icon": "●", "builtin": True,
         "nodes": [dict(msg), {"id": "answer", "type": "answer", "model": "@session", "tools": "lean",
                               "x": 40, "y": 180}],
         "edges": [{"from": "in", "to": "answer", "when": "always"}]},
    ]
