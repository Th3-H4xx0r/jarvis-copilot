"""HTTP for the Integrations page: what exists, what it holds, and what it runs.

The page on the phone and in the web UI reads through here; neither ever opens the
registry database. Schedule actions (run now, enable, edit) stay on the existing
``/api/crons/*`` endpoints — a schedule is still a cron job, it just belongs to an
integration now.

    GET    /api/integrations                     every integration, for the list
    POST   /api/integrations                     create one {id?, name, description, icon}
    GET    /api/integrations/<id>                one, with data, skills and schedules
    GET    /api/integrations/<id>/records        ?collection=&limit=&since=&until=
    GET    /api/integrations/<id>/documents/<key>  one stored document
    POST   /api/integrations/<id>/status         {status: active|paused|archived}
    DELETE /api/integrations/<id>/collections/<name>   drop a collection's records
    DELETE /api/integrations/<id>/documents/<key>      drop one document
    DELETE /api/integrations/<id>/skills/<name>?mode=unlink|file
    DELETE /api/integrations/<id>                remove it, or the parts named in the body
"""
from __future__ import annotations

import logging
import urllib.parse

logger = logging.getLogger(__name__)

_MAX_RECORDS = 200

# /api/integrations/photon is the iMessage provider's setup endpoint and predates the
# registry. It is not a space, so it falls through to the handler that owns it.
_NOT_OURS = {"photon"}


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
    if not space_id or space_id in _NOT_OURS:
        return False

    try:
        if tail == "":
            j(handler, _integrations().summary(space_id))
            return True
        if tail.startswith("documents/"):
            key = urllib.parse.unquote(tail[len("documents/"):])
            space = _registry().open(space_id)
            body = space.get(key, default=None)
            if body is None:
                j(handler, {"error": f"no document {key!r}"}, status=404)
                return True
            described = next((d for d in space.documents() if d["key"] == key), {})
            j(handler, {"space": space_id, "key": key, "body": body,
                        "description": described.get("description") or "",
                        "updated_at": described.get("updated_at")})
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
            space_id = slug(str((body or {}).get("id") or "").strip() or name)
            if space_id in _NOT_OURS:
                j(handler, {"error": f"{space_id!r} is not available as an integration id"},
                  status=400)
                return True
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
    if space_id in _NOT_OURS:
        return False

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


def handle_delete(handler, parsed, body=None) -> bool:
    from api.helpers import j

    path = parsed.path
    if not path.startswith("/api/integrations/"):
        return False
    rest = path[len("/api/integrations/"):].strip("/")
    space_id, _, tail = rest.partition("/")
    if not space_id or space_id in _NOT_OURS:
        return False

    try:
        reg = _registry()
        reg.open(space_id)                      # 404s before anything is removed

        if tail.startswith("collections/"):
            name = urllib.parse.unquote(tail[len("collections/"):])
            gone = reg.open(space_id).delete_collection(name)
            j(handler, {"ok": True, "collection": name, "records_removed": gone})
            return True

        if tail.startswith("documents/"):
            key = urllib.parse.unquote(tail[len("documents/"):])
            if not reg.open(space_id).delete_document(key):
                j(handler, {"error": f"no document {key!r}"}, status=404)
                return True
            j(handler, {"ok": True, "document": key})
            return True

        if tail.startswith("skills/"):
            name = urllib.parse.unquote(tail[len("skills/"):])
            mode = (urllib.parse.parse_qs(parsed.query).get("mode") or ["unlink"])[0]
            return _delete_skill(handler, name, mode)

        if tail:
            return False
        return _delete_space(handler, space_id, body)
    except Exception as exc:
        return _error(handler, exc)


def _delete_skill(handler, name: str, mode: str) -> bool:
    """Unlink a skill from its integration, or take the skill out of service."""
    from api.helpers import j

    ints = _integrations()
    if mode == "file":
        where = ints.delete_skill(name)
        if where is None:
            j(handler, {"error": f"no skill {name!r}"}, status=404)
            return True
        j(handler, {"ok": True, "skill": name, "moved_to": where})
        return True
    if mode != "unlink":
        j(handler, {"error": "mode must be 'unlink' or 'file'"}, status=400)
        return True
    if not ints.unlink_skill(name):
        j(handler, {"error": f"{name!r} does not belong to an integration"}, status=404)
        return True
    j(handler, {"ok": True, "skill": name, "unlinked": True})
    return True


def _delete_space(handler, space_id: str, body) -> bool:
    """Remove the integration, or only the parts the body names.

    An absent body means all of it, which is what a bare DELETE has always meant.
    ``skill_files`` is separate from ``skills`` on purpose: unlinking a skill is
    cheap to undo, taking it out of service is not.
    """
    from api.helpers import j
    from cron.jobs import remove_job

    body = body if isinstance(body, dict) else {}
    want = lambda key: bool(body.get(key, True))        # noqa: E731 — absent means all
    reg = _registry()
    ints = _integrations()
    removed: dict = {"id": space_id}

    if want("schedules"):
        names = []
        for job in ints.schedules_for(space_id):
            if remove_job(job["id"]):
                names.append(job.get("name") or job["id"])
        removed["schedules_removed"] = names

    if want("skills"):
        unlinked, filed = [], []
        for skill in ints.skills_for(space_id):
            if body.get("skill_files"):
                if ints.delete_skill(skill["name"]):
                    filed.append(skill["name"])
            elif ints.unlink_skill(skill["name"]):
                unlinked.append(skill["name"])
        removed["skills_unlinked"] = unlinked
        removed["skills_deleted"] = filed

    space = reg.open(space_id)
    if want("data"):
        collections = [c["name"] for c in space.collections()]
        documents = [d["key"] for d in space.documents()]
        for name in collections:
            space.delete_collection(name)
        for key in documents:
            space.delete_document(key)
        removed["collections_removed"] = collections
        removed["documents_removed"] = documents

    # Last, so a failure above leaves something to retry against.
    if want("space"):
        reg.delete_space(space_id)
        removed["deleted"] = True

    j(handler, {"ok": True, **removed})
    return True


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
