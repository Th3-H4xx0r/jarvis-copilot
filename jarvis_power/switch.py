"""The one path every on/off and settings change takes — app, web, Mac or Jarvis.

``request_*`` decide whether a change may happen now, needs Face ID first, or is
refused; ``apply_*`` make it. ``by`` is who asked: "app"/"ios", "web", "mac" (the
person) or "jarvis" (the agent, through its tools).
"""
from __future__ import annotations

import logging
from typing import Any

from jarvis_power import approvals, discovery, schedules, state
from jarvis_power.base import PowerError

logger = logging.getLogger(__name__)


def request_enabled(integration_id: str, enabled: bool, by: str) -> dict:
    p = discovery.get(integration_id)
    enabled = bool(enabled)
    if enabled == state.is_on(integration_id) and state.doc(integration_id):
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
            if setting.jarvis == "never":
                raise PowerError(f"{setting.label} can only be changed in the app")
            needs_face_id = needs_face_id or setting.jarvis == "ask"
        clean[key] = setting.coerce(value)
    if needs_face_id:
        item = approvals.create(f"settings:{p.id}", {"kind": "settings", "id": p.id,
                                                      "value": clean, "by": by},
                                source=_source(by))
        return {"ok": False, "pending": item}
    apply_settings(integration_id, clean)
    return {"ok": True, "row": _row(integration_id)}


def apply_enabled(integration_id: str, enabled: bool, by: str) -> None:
    """Make the switch: store it, pause or restore its schedules, act in this process."""
    sid = state.space_id_for(integration_id)
    if enabled:
        paused = state.doc(integration_id).get("paused_jobs") or []
        schedules.restore(paused)
        state.write_enabled(integration_id, True, by, paused_jobs=[])
    else:
        paused = schedules.pause(sid)
        state.write_enabled(integration_id, False, by, paused_jobs=paused)
    from jarvis_power import manager
    current = manager.current()
    if current is not None:
        current.reconcile()


def apply_settings(integration_id: str, clean: dict) -> None:
    discovery.get(integration_id).write_settings(clean)


def _source(by: str) -> str:
    return {"jarvis": "Jarvis", "web": "the web app", "mac": "your Mac"}.get(by, "this iPhone")


def _row(integration_id: str) -> dict:
    from jarvis_power import api
    return api.row(integration_id)
