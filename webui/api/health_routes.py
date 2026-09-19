"""HTTP for Jarvis Health: the person's days, battery and settings.

One integration, `jarvis-health`, fed by every linked wearable. Settings have
one owner — the Health tab's settings. A write must say it came from there,
which keeps the Integrations page free to show the values without becoming a
second place to edit them.

    GET  /api/health/devices                               the wearables roster
    POST /api/health/devices                               {devices: [...]} the phone's roster
    GET  /api/integrations/jarvis-health/health/settings   read settings
    POST /api/integrations/jarvis-health/health/settings   {source: "health-settings", ...}
    GET  /api/integrations/jarvis-health/health/day?date=  that day bedtime to bedtime: day, scores, battery, sleep debt
    GET  /api/integrations/jarvis-health/health/day/<date> the same (older phones)
    GET  /api/integrations/jarvis-health/health/now        today: last night's bedtime to now, the same shape
    GET  /api/integrations/jarvis-health/health/history?metric=&range=&end=  a metric's W/M/6M/Y history
    POST /api/integrations/jarvis-health/health/workouts   {workout: {...}, device_id} a finished workout
    GET  /api/integrations/jarvis-health/health/workouts?since=&until=&kind=strength  saved workouts (a reinstall's history)
    POST /api/integrations/jarvis-health/health/workouts/delete  {start, device | device_id + source} remove one
    GET  /api/integrations/jarvis-health/health/training   {templates, exercises, settings} for strength training
    POST /api/integrations/jarvis-health/health/training/templates  {template}   (…/templates/delete {id})
    POST /api/integrations/jarvis-health/health/training/exercises  {exercise}   (…/exercises/delete {id})
    POST /api/integrations/jarvis-health/health/training/settings   {settings: {exercise id: {...} | null}}
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

            from jarvis_health.metrics import utc_now
            from jarvis_health.window import cycle

            date = tail[len("day/"):] if tail.startswith("day/") else (parse_qs(parsed.query).get("date") or [""])[0]
            if not date:
                j(handler, {"error": "say which day: ?date=YYYY-MM-DD"}, status=400)
                return True
            out = cycle(store, date, utc_now())
            j(handler, {**out, "scores": store.scores(date), "has_data": out["day"] is not None,
                        "sleep_debt": _sleep_debt(store, date), "workouts": store.workouts(out["start"], out["end"])})
            return True

        if tail == "now":
            from jarvis_health.metrics import utc_now
            from jarvis_health.window import today

            out = today(store, utc_now())
            j(handler, {**out, "sleep_debt": _sleep_debt(store, out["date"]),
                        "workouts": store.workouts(out["start"], "9999-12-31T00:00:00Z"),
                        # The phone's workout effort is measured against it.
                        "resting_hr": store.baseline().resting_hr})
            return True

        if tail == "workouts":
            from urllib.parse import parse_qs

            query = parse_qs(parsed.query)
            since = (query.get("since") or ["1970-01-01T00:00:00Z"])[0]
            until = (query.get("until") or ["9999-12-31T00:00:00Z"])[0]
            kind = (query.get("kind") or [""])[0] or None
            if not (_instant(since) and _instant(until)):
                j(handler, {"error": "since and until are UTC instants: 2026-09-19T00:00:00Z"}, status=400)
                return True
            j(handler, {"workouts": store.workouts(since, until, kind)})
            return True

        if tail == "training":
            j(handler, store.training())
            return True

        if tail == "history":
            from urllib.parse import parse_qs

            from jarvis_health.history import METRICS, RANGES, history
            from jarvis_health.metrics import utc_now

            query = parse_qs(parsed.query)
            metric = (query.get("metric") or [""])[0]
            range_ = (query.get("range") or ["W"])[0]
            if metric not in METRICS or range_ not in RANGES:
                j(handler, {"error": f"metric is one of {sorted(METRICS)}; range one of {list(RANGES)}"}, status=400)
                return True
            j(handler, history(store, metric, range_, (query.get("end") or [None])[0], utc_now()))
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

        if tail == "workouts":
            workout = body.get("workout") if isinstance(body.get("workout"), dict) else None
            if not workout or not workout.get("start") or not workout.get("end"):
                j(handler, {"error": "a workout needs a 'start' and an 'end'"}, status=400)
                return True
            if not (_instant(workout["start"]) and _instant(workout["end"])):
                j(handler, {"error": "a workout's start and end are UTC instants: 2026-09-19T10:00:00Z"}, status=400)
                return True
            from jarvis_health.store import device_key_for

            device = device_key_for(workout.get("source") or "ring", body.get("device_id") or "")
            j(handler, {"ok": True, "workout": store.put_workout(workout, device)})
            return True

        if tail == "workouts/delete":
            from jarvis_health.store import device_key_for

            if not body.get("start"):
                j(handler, {"error": "say which workout: its 'start'"}, status=400)
                return True
            # The key it was filed under when the phone knows it, else rebuilt
            # from the device's id the way the save built it.
            device = str(body.get("device") or "") or device_key_for(body.get("source") or "ring", body.get("device_id") or "")
            j(handler, {"ok": True, "deleted": store.delete_workout(body["start"], device)})
            return True

        if tail.startswith("training/"):
            return _training_post(handler, store, tail[len("training/"):], body)

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


def _sleep_debt(store, date: str) -> dict:
    from jarvis_health.sleep_debt import goal_of, week

    return week(store, date, goal_of(store.settings()))


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


def _instant(text) -> bool:
    """A timestamp with its zone, as workouts are filed by."""
    from jarvis_health.metrics import parse_instant

    try:
        return parse_instant(str(text)).tzinfo is not None
    except (TypeError, ValueError):
        return False


def _training_post(handler, store, what: str, body: dict) -> bool:
    """Templates, custom exercises and per-exercise settings, as the phone saves them."""
    from api.helpers import j

    try:
        if what in ("templates", "exercises"):
            item = body.get(what[:-1])
            if not isinstance(item, dict):
                j(handler, {"error": f"send {{\"{what[:-1]}\": {{...}}}}"}, status=400)
                return True
            saved = store.put_template(item) if what == "templates" else store.put_exercise(item)
            j(handler, {"ok": True, what[:-1]: saved})
            return True
        if what in ("templates/delete", "exercises/delete"):
            deleted = (store.delete_template if what.startswith("templates") else store.delete_exercise)(body.get("id"))
            j(handler, {"ok": True, "deleted": deleted})
            return True
        if what == "settings":
            settings = body.get("settings")
            if not isinstance(settings, dict):
                j(handler, {"error": "send {\"settings\": {exercise id: {...}}}"}, status=400)
                return True
            j(handler, {"ok": True, "settings": store.put_training_settings(settings)})
            return True
    except ValueError as exc:
        j(handler, {"error": str(exc)}, status=400)
        return True
    j(handler, {"error": f"no training endpoint {what!r}"}, status=404)
    return True
