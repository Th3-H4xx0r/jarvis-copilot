"""Which chat and model each Jarvis Pod talks to — chosen on the phone's Pod page.

    STATE_DIR/pod_voice.json   {"<device_id>": {"session_id": "", "model": "", "provider": ""}}

Nothing chosen (an empty field) keeps the voice defaults: the shared Voice chat,
and the voice model routing. A chosen chat that has since been deleted falls
back to the Voice chat rather than failing the turn.

    GET  /api/devices/pod/voice?device_id=
    POST /api/devices/pod/voice   {device_id, session_id?, model?, provider?}
"""
from __future__ import annotations

import json
import logging
import re
import threading
import urllib.parse

from api.config import STATE_DIR

logger = logging.getLogger(__name__)

PATH = STATE_DIR / "pod_voice.json"
FIELDS = ("session_id", "model", "provider")
_MAX_LEN = 200
_DEVICE_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
_LOCK = threading.Lock()


def _read_all() -> dict:
    try:
        data = json.loads(PATH.read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def load(device_id: str) -> dict:
    row = _read_all().get(device_id)
    row = row if isinstance(row, dict) else {}
    return {k: str(row.get(k) or "") for k in FIELDS}


def save(device_id: str, patch: dict) -> dict:
    if not _DEVICE_ID.match(device_id or ""):
        raise ValueError("device_id is required")
    with _LOCK:
        data = _read_all()
        row = {k: str((data.get(device_id) or {}).get(k) or "") for k in FIELDS}
        for key in FIELDS:
            if key in patch:
                row[key] = str(patch.get(key) or "").strip()[:_MAX_LEN]
        data[device_id] = row
        PATH.parent.mkdir(parents=True, exist_ok=True)
        tmp = PATH.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(data, indent=1))
        tmp.replace(PATH)
    return row


def _session_exists(session_id: str) -> bool:
    try:
        from api.models import get_session
        return get_session(session_id, metadata_only=True) is not None
    except Exception:
        return False


def choice_for(state: dict, client: str) -> dict:
    """A Pod socket's chosen chat and model ({} for anything else, or nothing chosen)."""
    if client != "jarvis_pod":
        return {}
    device_id = str((state.get("origin") or {}).get("device_id") or "")
    if not device_id:
        return {}
    row = load(device_id)
    if row["session_id"] and not _session_exists(row["session_id"]):
        logger.info("pod %s: chosen chat %s is gone; using the Voice chat", device_id, row["session_id"])
        row["session_id"] = ""
    return {k: v for k, v in row.items() if v}


# ── HTTP ─────────────────────────────────────────────────────────────────────

def handle_get(handler, parsed) -> bool:
    from api.helpers import j

    device_id = (urllib.parse.parse_qs(parsed.query).get("device_id") or [""])[0]
    if not _DEVICE_ID.match(device_id):
        j(handler, {"error": "device_id is required"}, status=400)
        return True
    j(handler, load(device_id))
    return True


def handle_post(handler, body: dict) -> bool:
    from api.helpers import j

    try:
        row = save(str(body.get("device_id") or ""), body)
    except ValueError as exc:
        j(handler, {"error": str(exc)}, status=400)
        return True
    j(handler, row)
    return True
