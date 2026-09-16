"""HTTP for the Integrations page: what exists, what it holds, and what it runs.

The page on the phone and in the web UI reads through here; neither ever opens the
registry database. Schedule actions (run now, enable, edit) stay on the existing
``/api/crons/*`` endpoints — a schedule is still a cron job, it just belongs to an
integration now.

    GET    /api/integrations                     every integration, for the list
    POST   /api/integrations                     create one {id?, name, description, icon}
    GET    /api/integrations/<id>                one, with data, skills and schedules
    GET    /api/integrations/<id>/records        ?collection=&limit=&since=&until=
    POST   /api/integrations/<id>/status         {status: active|paused|archived}
    DELETE /api/integrations/<id>                remove it and everything in it
"""
from __future__ import annotations

import logging
import urllib.parse

logger = logging.getLogger(__name__)

_MAX_RECORDS = 200


def _registry():
    from jarvis_registry.store import shared

    return shared()


def _integrations():
    from jarvis_registry import integrations

    return integrations


def handle_get(handler, parsed) -> bool:
    """GET routes. Returns True when the path was ours."""
    from api.helpers import j

    path = parsed.path
    from api.integration_plans import handle_get as _plans_get
    if _plans_get(handler, parsed):
        return True

    if path == "/api/integrations":
        ints = _integrations()
        ints.ensure_general()
        j(handler, {"integrations": ints.overview()})
        return True

    if not path.startswith("/api/integrations/"):
        return False

    rest = path[len("/api/integrations/"):].strip("/")
    space_id, _, tail = rest.partition("/")
    if not space_id:
        return False

    try:
        if tail == "":
            j(handler, _integrations().summary(space_id))
            return True
        if tail == "records":
            qs = urllib.parse.parse_qs(parsed.query)
            collection = (qs.get("collection") or [""])[0]
            if not collection:
                j(handler, {"error": "collection is required"}, status=400)
                return True
            space = _registry().open(space_id)
            records = space.records(
                collection,
                since=_float(qs.get("since")),
                until=_float(qs.get("until")),
                limit=_int(qs.get("limit"), 50, _MAX_RECORDS),
            )
            j(handler, {"space": space_id, "collection": collection,
                        "count": len(records), "records": records})
            return True
    except Exception as exc:
        return _error(handler, exc)
    return False


def handle_post(handler, parsed, body) -> bool:
    from api.helpers import j

    path = parsed.path
    from api.integration_plans import handle_post as _plans_post
    if _plans_post(handler, parsed, body):
        return True

    if path == "/api/integrations":
        try:
            from jarvis_registry.store import slug

            name = str((body or {}).get("name") or "").strip()
            if not name:
                j(handler, {"error": "name is required"}, status=400)
                return True
            space_id = str((body or {}).get("id") or "").strip().lower() or slug(name)
            space = _registry().space(
                space_id, name=name,
                description=str((body or {}).get("description") or ""),
                icon=str((body or {}).get("icon") or ""))
            j(handler, _integrations().summary(space.id), status=201)
            return True
        except Exception as exc:
            return _error(handler, exc)

    if not path.startswith("/api/integrations/"):
        return False
    rest = path[len("/api/integrations/"):].strip("/")
    space_id, _, tail = rest.partition("/")

    if tail == "status":
        try:
            status = str((body or {}).get("status") or "").strip()
            reg = _registry()
            reg.open(space_id)               # 404s before the write
            reg.set_status(space_id, status)
            j(handler, {"ok": True, "id": space_id, "status": status})
            return True
        except Exception as exc:
            return _error(handler, exc)
    return False


def handle_delete(handler, parsed) -> bool:
    from api.helpers import j

    path = parsed.path
    if not path.startswith("/api/integrations/"):
        return False
    space_id = path[len("/api/integrations/"):].strip("/")
    if not space_id or "/" in space_id:
        return False
    try:
        reg = _registry()
        reg.open(space_id)
        # The schedules go with it: an orphaned job would keep firing with no
        # integration to run in.
        from cron.jobs import remove_job

        removed = []
        for job in _integrations().schedules_for(space_id):
            if remove_job(job["id"]):
                removed.append(job.get("name") or job["id"])
        reg.delete_space(space_id)
        j(handler, {"ok": True, "id": space_id, "schedules_removed": removed})
        return True
    except Exception as exc:
        return _error(handler, exc)


# ── helpers ──────────────────────────────────────────────────────────────────
def _error(handler, exc: Exception) -> bool:
    from api.helpers import j
    from jarvis_registry.store import RegistryError, UnknownSpace

    if isinstance(exc, UnknownSpace):
        j(handler, {"error": str(exc)}, status=404)
        return True
    if isinstance(exc, RegistryError):
        j(handler, {"error": str(exc)}, status=400)
        return True
    logger.warning("integrations: request failed", exc_info=True)
    j(handler, {"error": str(exc)}, status=500)
    return True


def _int(values, default: int, cap: int) -> int:
    try:
        return max(1, min(int((values or [default])[0]), cap))
    except (TypeError, ValueError):
        return default


def _float(values):
    try:
        raw = (values or [None])[0]
        return float(raw) if raw not in (None, "") else None
    except (TypeError, ValueError):
        return None
