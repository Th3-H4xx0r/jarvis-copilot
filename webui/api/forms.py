"""Forms the agent draws in the conversation.

Some questions are a bad fit for prose. "What should I call it, how often, and
what time?" is three answers the user has to keep in their head and type back in
order — when what they want is three boxes.

So the agent can ask for a form instead: it names the fields, the chat draws them
as a card with real inputs, and the answers come back as the user's next message.
The layout is fixed here, not by the model; the model supplies labels, types and
options and nothing else, which is what keeps every form looking like the app.

    GET  /api/forms/<id>            one form, and what was entered if it is done
    POST /api/forms/<id>/submit     {values: {...}}
"""
from __future__ import annotations

import json
import logging
import threading
import time
import uuid
from pathlib import Path
from typing import Any, Optional

logger = logging.getLogger(__name__)

MAX_FIELDS = 10
_MAX_TEXT = 200
_MAX_VALUE = 2000
_FORM_TTL_SECONDS = 30 * 24 * 3600

# What a field can be. Anything else is a control the card cannot draw.
FIELD_TYPES = {"text", "multiline", "number", "choice", "toggle"}

_LOCK = threading.Lock()


class FormError(ValueError):
    """The form doesn't fit the card. The message names the field."""


def _path() -> Path:
    from jarviscopilot_constants import get_hermes_home

    return Path(get_hermes_home()) / "forms.json"


def _load() -> list[dict]:
    try:
        raw = json.loads(_path().read_text())
        forms = raw.get("forms") if isinstance(raw, dict) else raw
        return [f for f in (forms or []) if isinstance(f, dict)]
    except (OSError, json.JSONDecodeError):
        return []


def _save(forms: list[dict]) -> None:
    path = _path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps({"forms": forms}, ensure_ascii=False, indent=2))
    tmp.replace(path)


def _text(value: Any, field: str, *, required: bool = True, limit: int = _MAX_TEXT) -> str:
    text = str(value or "").strip()
    if required and not text:
        raise FormError(f"{field} is required")
    if len(text) > limit:
        raise FormError(f"{field} is longer than {limit} characters")
    return text


def validate(form: dict) -> dict:
    """The form as the card will draw it, or FormError naming the bad field."""
    if not isinstance(form, dict):
        raise FormError("the form must be an object")

    fields = form.get("fields") or []
    if not isinstance(fields, list) or not fields:
        raise FormError("a form needs at least one field")
    if len(fields) > MAX_FIELDS:
        raise FormError(f"a form can ask at most {MAX_FIELDS} things at once")

    out_fields = []
    seen: set[str] = set()
    for i, raw in enumerate(fields):
        if not isinstance(raw, dict):
            raise FormError(f"fields[{i}] must be an object")
        kind = str(raw.get("type") or "text").strip().lower()
        if kind not in FIELD_TYPES:
            raise FormError(f"fields[{i}].type must be one of {', '.join(sorted(FIELD_TYPES))}")
        key = _text(raw.get("key"), f"fields[{i}].key", limit=64)
        if key in seen:
            raise FormError(f"two fields both called {key!r}")
        seen.add(key)
        options = [str(o).strip() for o in (raw.get("options") or []) if str(o).strip()]
        if kind == "choice" and not options:
            raise FormError(f"fields[{i}] is a choice with no options")
        out_fields.append({
            "key": key,
            "label": _text(raw.get("label"), f"fields[{i}].label"),
            "type": kind,
            "placeholder": _text(raw.get("placeholder"), f"fields[{i}].placeholder",
                                 required=False),
            "help": _text(raw.get("help"), f"fields[{i}].help", required=False),
            "options": options[:12],
            "required": bool(raw.get("required", False)),
            "default": _text(raw.get("default"), f"fields[{i}].default", required=False,
                             limit=_MAX_VALUE),
        })

    return {
        "id": uuid.uuid4().hex[:12],
        "title": _text(form.get("title"), "title", limit=64),
        "intro": _text(form.get("intro"), "intro", required=False, limit=300),
        "submit_label": _text(form.get("submit"), "submit", required=False, limit=32) or "Done",
        "fields": out_fields,
        "status": "open",
        "values": {},
        "created_at": time.time(),
    }


def ask(form: dict) -> dict:
    """Store a form for the card to draw. Nothing has been answered yet."""
    entry = validate(form)
    with _LOCK:
        forms = [f for f in _load()
                 if f.get("status") != "open" or _age(f) < _FORM_TTL_SECONDS]
        forms.append(entry)
        open_forms = [f for f in forms if f.get("status") == "open"]
        answered = [f for f in forms if f.get("status") != "open"]
        # Trim what is finished with; an open form's card is still on screen.
        _save(answered[-50:] + open_forms)
    return entry


def _age(form: dict) -> float:
    try:
        return time.time() - float(form.get("created_at") or 0)
    except (TypeError, ValueError):
        return 0.0


def get(form_id: str) -> Optional[dict]:
    return next((f for f in _load() if f.get("id") == form_id), None)


def submit(form_id: str, values: dict) -> dict:
    """Record what was entered. Returns the form, and the line to send as the reply."""
    if not isinstance(values, dict):
        raise FormError("values must be an object")
    with _LOCK:
        forms = _load()
        form = next((f for f in forms if f.get("id") == form_id), None)
        if form is None:
            raise FormError(f"no form {form_id!r}")
        if form.get("status") != "open":
            raise FormError("that form was already answered")

        cleaned: dict = {}
        for field in form["fields"]:
            raw = values.get(field["key"])
            if isinstance(raw, bool):
                cleaned[field["key"]] = raw
                continue
            text = str(raw if raw is not None else "").strip()[:_MAX_VALUE]
            if field["required"] and not text:
                raise FormError(f"{field['label']} is required")
            if field["type"] == "choice" and text and text not in field["options"]:
                raise FormError(f"{text!r} is not one of the choices for {field['label']}")
            cleaned[field["key"]] = text

        form["values"] = cleaned
        form["status"] = "answered"
        form["answered_at"] = time.time()
        _save(forms)
    return {"form": form, "reply": reply_text(form)}


def reply_text(form: dict) -> str:
    """What the user's message says after they submit — the answers, in order."""
    lines = []
    for field in form.get("fields", []):
        value = form.get("values", {}).get(field["key"])
        if isinstance(value, bool):
            shown = "yes" if value else "no"
        else:
            shown = str(value or "").strip()
        lines.append(f"{field['label']} {shown or '(not answered)'}")
    return "\n".join(lines)


# ── HTTP ─────────────────────────────────────────────────────────────────────
def handle_get(handler, parsed) -> bool:
    from api.helpers import j

    if not parsed.path.startswith("/api/forms/"):
        return False
    form_id = parsed.path[len("/api/forms/"):].strip("/")
    if not form_id or "/" in form_id:
        return False
    form = get(form_id)
    if form is None:
        j(handler, {"error": f"no form {form_id!r}"}, status=404)
        return True
    j(handler, form)
    return True


def handle_post(handler, parsed, body) -> bool:
    from api.helpers import j

    if not parsed.path.startswith("/api/forms/"):
        return False
    rest = parsed.path[len("/api/forms/"):].strip("/")
    form_id, _, action = rest.partition("/")
    if action != "submit" or not form_id:
        return False
    try:
        j(handler, submit(form_id, (body or {}).get("values") or {}))
    except FormError as exc:
        j(handler, {"error": str(exc)}, status=400)
    except Exception as exc:
        logger.warning("form submit failed", exc_info=True)
        j(handler, {"error": str(exc)}, status=500)
    return True
