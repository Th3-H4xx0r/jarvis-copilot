"""HTTP for wearable health: scores to read, days to push, settings to change.

Settings have one owner — the wearable's own settings screen. A write must say
it came from there, which keeps the Integrations page free to show the values
without becoming a second place to edit them.

    GET  /api/health/devices                             eligible wearables + spaces
    POST /api/health/devices                             {devices: [...]} the phone's roster
    GET  /api/integrations/<id>/health/settings           read settings
    POST /api/integrations/<id>/health/settings           {source: "wearable-settings", ...}
    GET  /api/integrations/<id>/health/day/<date>         scores + analysis for a local day
    POST /api/integrations/<id>/health/day                {day: <ring day JSON>}
    POST /api/integrations/<id>/health/run                run the analysis now
"""
from __future__ import annotations

import logging

logger = logging.getLogger(__name__)

#: The only writer of health settings. Anything else is refused.
SETTINGS_SOURCE = "wearable-settings"

_EDITED_IN = "the ring's wearable settings screen"


def _store(space_id: str):
    from jarvis_health.store import HealthStore

    return HealthStore(space_id)


#: Health spaces are named by `jarvis_health.store.space_id_for`. Anything else
#: — `general`, an integration the user made — is not ours to write into.
_SPACE_PREFIX = "wearable-"


def _exists(space_id: str) -> bool:
    from jarvis_registry.store import shared

    return shared().exists(space_id)


def _is_health_space(space_id: str) -> bool:
    """Whether this id names a wearable's health space, and not just any space.

    Without this, every registry space reachable from the Integrations list was
    a valid target: a POST could rewrite `general`'s settings document with
    health defaults and hang a cron job off it.
    """
    return space_id.startswith(_SPACE_PREFIX) and _exists(space_id)


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

        if tail.startswith("day/"):
            date = tail[len("day/"):]
            day = store.day(date)
            j(
                handler,
                {
                    "date": date,
                    "scores": store.scores(date),
                    "has_data": day is not None,
                    "synced_at": day.synced_at if day else None,
                },
            )
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
        # The phone knows its own wearables; this is how an eligible one gets its
        # integration without anybody opening a settings screen first.
        roster = body_dict.get("devices")
        if not isinstance(roster, list):
            j(handler, {"error": "send {\"devices\": [...]} from the phone's roster"}, status=400)
            return True
        try:
            from jarvis_health.bootstrap import ensure_wearable_integrations

            created = ensure_wearable_integrations(roster)
            j(handler, {"ok": True, "spaces": created, "devices": devices()})
        except Exception as exc:
            logger.exception("health: could not ensure wearable integrations")
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
            _resync_schedule(space_id, settings)
            j(handler, {"settings": settings, "edited_in": _EDITED_IN})
            return True

        if tail == "day":
            raw = body.get("day") if isinstance(body.get("day"), dict) else None
            if not raw or not raw.get("date"):
                j(handler, {"error": "a day needs a 'date'"}, status=400)
                return True
            from jarvis_health.sources.ring import day_from_ring_json

            tz = raw.get("timezone") or "UTC"
            day = day_from_ring_json(raw, raw["date"], tz)
            store.put_day(day)
            j(handler, {"ok": True, "date": day.date, "timezone": day.timezone})
            return True

        if tail == "run":
            settings = store.settings()
            kind = settings.get("kind") or "ring"
            wearable_id = settings.get("device_id") or ""
            bridge_id = settings.get("bridge_device_id") or ""
            if not wearable_id or not bridge_id:
                j(handler, {"error": "this integration has no paired phone yet"}, status=409)
                return True

            import jarvis_health.runner as runner
            from jarvis_health.sources import source_for

            out = runner.run(space_id, source_for(kind, bridge_id, wearable_id),
                             trigger=body.get("trigger") or "manual")
            j(handler, {"run": out})
            return True
    except Exception as exc:
        logger.exception("health POST %s failed", parsed.path)
        j(handler, {"error": str(exc)}, status=500)
        return True

    return False


def devices() -> list[dict]:
    """Every wearable with a health integration, newest settings included."""
    from jarvis_registry.store import shared

    out = []
    for space in shared().spaces():
        space_id = space.get("id") or ""
        if not space_id.startswith("wearable-"):
            continue
        settings = _store(space_id).settings()
        out.append(
            {
                "space_id": space_id,
                "kind": settings.get("kind") or space_id.split("-")[1],
                "device_id": settings.get("device_id") or "",
                "name": settings.get("device_name") or space.get("name") or space_id,
                "enabled": bool(settings.get("enabled", True)),
                "frequency": settings.get("frequency"),
            }
        )
    return out


def _resync_schedule(space_id: str, settings: dict) -> None:
    """A frequency or an enabled flag only means something once cron agrees."""
    try:
        from jarvis_health.bootstrap import ensure_schedule

        ensure_schedule(
            space_id,
            settings,
            device_id=settings.get("device_id") or "",
            kind=settings.get("kind") or "ring",
        )
    except Exception:
        logger.exception("health: could not re-sync the schedule for %s", space_id)
