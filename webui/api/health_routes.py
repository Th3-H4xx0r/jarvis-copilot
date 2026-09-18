"""HTTP for Jarvis Health: the person's days, battery and settings.

One integration, `jarvis-health`, fed by every linked wearable. Settings have
one owner — the Health tab's settings. A write must say it came from there,
which keeps the Integrations page free to show the values without becoming a
second place to edit them.

    GET  /api/health/devices                               the wearables roster
    POST /api/health/devices                               {devices: [...]} the phone's roster
    GET  /api/integrations/jarvis-health/health/settings   read settings
    POST /api/integrations/jarvis-health/health/settings   {source: "health-settings", ...}
    GET  /api/integrations/jarvis-health/health/day?date=  the merged day, scores and battery
    GET  /api/integrations/jarvis-health/health/day/<date> the same (older phones)
    GET  /api/integrations/jarvis-health/health/now        since the last wake
    POST /api/integrations/jarvis-health/health/day        {day: <ring day JSON>}
    POST /api/integrations/jarvis-health/health/devices/<device>  {linked: bool}
    POST /api/integrations/jarvis-health/health/run        run the analysis now
"""
from __future__ import annotations

import logging

logger = logging.getLogger(__name__)

#: The only writer of health settings. Anything else is refused.
SETTINGS_SOURCE = "health-settings"

_EDITED_IN = "the Health tab's settings"


def _store(space_id: str):
    from jarvis_health.store import HealthStore

    return HealthStore(space_id)


def _exists(space_id: str) -> bool:
    from jarvis_registry.store import shared

    return shared().exists(space_id)


def _is_health_space(space_id: str) -> bool:
    """Whether this id names Jarvis Health, and not just any space.

    Without this, every registry space reachable from the Integrations list was
    a valid target: a POST could rewrite `general`'s settings document with
    health defaults and hang a cron job off it. A `wearable-*` space still
    answers until the migration folds it in.
    """
    from jarvis_health.store import SHARED_SPACE

    return space_id == SHARED_SPACE or (space_id.startswith("wearable-") and _exists(space_id))


def _split(path: str) -> tuple[str, str]:
    """('<space id>', '<tail after /health/>') for a health path, else ('', '')."""
    if not path.startswith("/api/integrations/"):
        return "", ""
    rest = path[len("/api/integrations/"):].strip("/")
    space_id, _, tail = rest.partition("/")
    if not tail.startswith("health"):
        return "", ""
    return space_id, tail[len("health"):].strip("/")


def handle_get(handler, parsed) -> bool:
    from api.helpers import j

    path = parsed.path

    if path == "/api/health/devices":
        j(handler, {"devices": devices()})
        return True

    space_id, tail = _split(path)
    if not space_id:
        return False

    if not _is_health_space(space_id):
        j(handler, {"error": f"no health integration {space_id!r}"}, status=404)
        return True

    try:
        store = _store(space_id)

        if tail == "settings":
            j(handler, {"settings": store.settings(), "edited_in": _EDITED_IN})
            return True

        if tail == "day" or tail.startswith("day/"):
            from urllib.parse import parse_qs

            from jarvis_health.merge import merged_day
            from jarvis_health.metrics import to_json

            date = tail[len("day/"):] if tail.startswith("day/") else (parse_qs(parsed.query).get("date") or [""])[0]
            merged = merged_day(store, date) if date else None
            j(
                handler,
                {
                    "date": date,
                    "day": to_json(merged) if merged else None,
                    "scores": store.scores(date) if date else None,
                    "battery": store.battery(date) if date else None,
                    "has_data": merged is not None,
                    "synced_at": merged.synced_at if merged else None,
                },
            )
            return True

        if tail == "now":
            from jarvis_health.metrics import utc_now
            from jarvis_health.window import since_wake

            j(handler, since_wake(store, utc_now()))
            return True

        if tail == "runs":
            j(handler, {"runs": store.runs(limit=20)})
            return True

        if tail == "alerts":
            j(handler, {"alerts": store.alerts(limit=50)})
            return True
    except Exception as exc:
        logger.exception("health GET %s failed", path)
        j(handler, {"error": str(exc)}, status=500)
        return True

    return False


def handle_post(handler, parsed, body) -> bool:
    from api.helpers import j

    body_dict = body if isinstance(body, dict) else {}

    if parsed.path == "/api/health/devices":
        # The phone knows its own wearables; this is how an eligible one joins
        # Jarvis Health without anybody opening a settings screen first.
        roster = body_dict.get("devices")
        if not isinstance(roster, list):
            j(handler, {"error": "send {\"devices\": [...]} from the phone's roster"}, status=400)
            return True
        try:
            from jarvis_health.bootstrap import ensure_health_integration

            j(handler, {"ok": True, **ensure_health_integration(roster)})
        except Exception as exc:
            logger.exception("health: could not register wearables")
            j(handler, {"error": str(exc)}, status=500)
        return True

    space_id, tail = _split(parsed.path)
    if not space_id:
        return False

    if not _is_health_space(space_id):
        j(handler, {"error": f"no health integration {space_id!r}"}, status=404)
        return True

    body = body_dict

    try:
        store = _store(space_id)

        if tail == "settings":
            if body.get("source") != SETTINGS_SOURCE:
                j(
                    handler,
                    {"error": f"health settings are edited in {_EDITED_IN}", "edited_in": _EDITED_IN},
                    status=403,
                )
                return True
            updates = {k: v for k, v in body.items() if k not in ("source",)}
            settings = store.put_settings(updates)
            _resync_schedule(settings)
            j(handler, {"settings": settings, "edited_in": _EDITED_IN})
            return True

        if tail.startswith("devices/"):
            entry = store.set_linked(tail[len("devices/"):], bool(body.get("linked")))
            if entry is None:
                j(handler, {"error": "no such wearable in Jarvis Health"}, status=404)
                return True
            j(handler, {"device": entry})
            return True

        if tail == "day":
            raw = body.get("day") if isinstance(body.get("day"), dict) else None
            if not raw or not raw.get("date"):
                j(handler, {"error": "a day needs a 'date'"}, status=400)
                return True
            from jarvis_health.sources.ring import day_from_ring_json
            from jarvis_health.store import device_key_for

            kind = raw.get("source") or "ring"
            device_id = raw.get("device_id") or body.get("device_id") or ""
            day = day_from_ring_json(raw, raw["date"], raw.get("timezone") or "UTC")
            store.put_day(day, device_key_for(kind, device_id))
            j(handler, {"ok": True, "date": day.date, "timezone": day.timezone})
            return True

        if tail == "run":
            import jarvis_health.runner as runner

            out = runner.run(space_id, trigger=body.get("trigger") or "manual")
            j(handler, {"run": out})
            return True
    except Exception as exc:
        logger.exception("health POST %s failed", parsed.path)
        j(handler, {"error": str(exc)}, status=500)
        return True

    return False


def devices() -> list[dict]:
    """Every wearable Jarvis Health knows, with its link state and last sync."""
    from jarvis_health.store import HealthStore

    return HealthStore().roster()


def _resync_schedule(settings: dict) -> None:
    """A frequency or an enabled flag only means something once cron agrees."""
    try:
        from jarvis_health.bootstrap import ensure_schedule

        ensure_schedule(settings)
    except Exception:
        logger.exception("health: could not re-sync the Jarvis Health schedule")
