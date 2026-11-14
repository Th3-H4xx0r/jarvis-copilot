"""The one path every on/off and settings change takes — app, web, Mac or Jarvis.

``request_*`` decide whether a change may happen now, needs Face ID first, or is
refused; ``apply_*`` make it. ``by`` is who asked: "app"/"ios", "web", "mac" (the
person) or "jarvis" (the agent, through its tools).
"""
from __future__ import annotations

import hashlib
import json
import logging
import threading
from typing import Any

from jarvis_power import approvals, discovery, schedules, state
from jarvis_power.base import PowerError

logger = logging.getLogger(__name__)
# One change at a time in this process: two clients (or a double tap) must not both
# pause schedules and overwrite each other's record of what they paused.
_lock = threading.RLock()


def request_enabled(integration_id: str, enabled: bool, by: str) -> dict:
    with _lock:
        return _request_enabled(integration_id, enabled, by)


def _request_enabled(integration_id: str, enabled: bool, by: str) -> dict:
    p = discovery.get(integration_id)
    enabled = bool(enabled)
    current = state.doc(integration_id)
    if current and bool(current.get("enabled", True)) == enabled:
        return {"ok": True, "row": _row(integration_id)}
    if not enabled:
        reason = p.can_switch_off()
        if reason:
            raise PowerError(reason)
        if p.protected:
            item = approvals.create(f"off:{p.id}", {"kind": "enabled", "id": p.id,
                                                     "value": False, "by": by},
                                    source=_source(by))
            return {"ok": False, "pending": item}
    apply_enabled(integration_id, enabled, by)
    return {"ok": True, "row": _row(integration_id)}


def request_settings(integration_id: str, changes: dict, by: str) -> dict:
    with _lock:
        return _request_settings(integration_id, changes, by)


def _request_settings(integration_id: str, changes: dict, by: str) -> dict:
    p = discovery.get(integration_id)
    if not isinstance(changes, dict) or not changes:
        raise PowerError("No settings to change")
    fields = {s.key: s for s in p.settings}
    clean: dict[str, Any] = {}
    needs_face_id = False
    for key, value in changes.items():
        setting = fields.get(key)
        if setting is None:
            raise PowerError(f"{p.name} has no setting {key!r}")
        if by == "jarvis":
            # Secrets are never Jarvis's to set: a token it chose is a token it knows.
            if setting.jarvis == "never" or setting.kind == "secret":
                raise PowerError(f"{setting.label} can only be changed in the app")
            needs_face_id = needs_face_id or setting.jarvis == "ask"
        clean[key] = setting.coerce(value)
    if needs_face_id:
        # The command carries a digest of the values, so the phone approves exactly these.
        digest = hashlib.sha256(json.dumps(clean, sort_keys=True).encode()).hexdigest()[:10]
        item = approvals.create(f"settings:{p.id}:{digest}",
                                {"kind": "settings", "id": p.id, "value": clean, "by": by},
                                source=_source(by), detail=_describe(fields, clean))
        return {"ok": False, "pending": item}
    apply_settings(integration_id, clean)
    return {"ok": True, "row": _row(integration_id)}


def apply_enabled(integration_id: str, enabled: bool, by: str) -> None:
    """Make the switch: store it, pause or restore its schedules, act in this process."""
    with _lock:
        sid = state.space_id_for(integration_id)
        already = state.doc(integration_id).get("paused_jobs") or []
        if enabled:
            schedules.restore(already)
            state.write_enabled(integration_id, True, by, paused_jobs=[])
        else:
            paused = sorted(set(already) | set(schedules.pause(sid)))
            state.write_enabled(integration_id, False, by, paused_jobs=paused)
    from jarvis_power import manager
    current = manager.current()
    if current is not None:
        current.reconcile()


def apply_settings(integration_id: str, clean: dict) -> None:
    with _lock:
        discovery.get(integration_id).write_settings(clean)


def _describe(fields: dict, clean: dict) -> str:
    """What a settings approval changes, for the Face ID card (never a secret's value)."""
    parts = []
    for key, value in clean.items():
        s = fields[key]
        shown = "on" if value is True else "off" if value is False else (
            "a new value" if s.kind == "secret" else f"{value}{(' ' + s.unit) if s.unit else ''}")
        parts.append(f"{s.label} → {shown}")
    return ", ".join(parts)


def _source(by: str) -> str:
    return {"jarvis": "Jarvis", "web": "the web app", "mac": "your Mac"}.get(by, "this iPhone")


def _row(integration_id: str) -> dict:
    from jarvis_power import api
    return api.row(integration_id)
