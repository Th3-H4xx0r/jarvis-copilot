"""Asking the user something with boxes instead of prose.

Some questions are a bad fit for a sentence. "What should I call it, how often,
and at what time?" is three answers the user has to hold in their head and type
back in order — when what they want is three boxes.

``form_ask`` draws those boxes in the conversation. The agent names the fields;
the chat renders them as a card with real inputs; the answers come back as the
user's next message, so the turn after it reads them like anything else they said.
"""
from __future__ import annotations

import json
from typing import Any

from tools.registry import registry

_ASK = {
    "name": "form_ask",
    "description": (
        "Ask the user several things at once as a form in the chat: a card with "
        "real input boxes they fill in and submit. Use it when you need more than "
        "one answer, or when an answer is a choice from a short list — it is much "
        "less work for them than a paragraph of questions. Do not use it for a "
        "single yes/no, and do not ask for anything you could reasonably work out "
        "yourself. Their answers arrive as their next message."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "title": {"type": "string", "description": "What the form is for, in a few words"},
            "intro": {"type": "string", "description": "Optional line above the fields"},
            "submit": {"type": "string", "description": "Button label; 'Done' otherwise"},
            "fields": {
                "type": "array",
                "description": "What to ask, in the order it should be filled in",
                "items": {
                    "type": "object",
                    "properties": {
                        "key": {"type": "string", "description": "Short name for the answer, e.g. 'name'"},
                        "label": {"type": "string", "description": "The question, as a label"},
                        "type": {
                            "type": "string",
                            "enum": ["text", "multiline", "number", "choice", "toggle"],
                            "description": "text is one line; choice needs options; toggle is yes/no",
                        },
                        "options": {
                            "type": "array",
                            "items": {"type": "string"},
                            "description": "The choices, for type 'choice'",
                        },
                        "placeholder": {"type": "string", "description": "An example answer"},
                        "help": {"type": "string", "description": "One short line under the field"},
                        "required": {"type": "boolean"},
                        "default": {"type": "string", "description": "Prefilled answer"},
                    },
                    "required": ["key", "label"],
                },
            },
        },
        "required": ["title", "fields"],
    },
}


def _h_ask(args=None, **_kw) -> str:
    args = args or {}
    try:
        from api.forms import ask
    except Exception:
        try:
            import sys
            from pathlib import Path

            sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "webui"))
            from api.forms import ask
        except Exception as exc:
            return json.dumps({"ok": False, "error": f"forms are unavailable: {exc}"})
    try:
        form = ask(args)
    except Exception as exc:
        return json.dumps({"ok": False, "error": str(exc)})
    return json.dumps({
        "ok": True,
        "form_id": form["id"],
        "card": {"kind": "form", "form_id": form["id"]},
        "note": ("The form is on screen. Wait for their answers — they arrive as "
                 "their next message. Do not ask the same things again in prose."),
    }, ensure_ascii=False)


registry.register(name="form_ask", toolset="forms", schema=_ASK, handler=_h_ask, emoji="📝")
