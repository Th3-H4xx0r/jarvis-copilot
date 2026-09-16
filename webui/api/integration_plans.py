"""The integration plan card: what Jarvis proposes, before anything starts running.

Asking for a new integration does not create one. The agent calls
``integration_plan_propose`` with a plan — a name, what it is for, the schedules it
wants, the data it will keep, the skills it would write — and that plan is stored
pending and rendered as a card in the chat on the phone and the web.

The card's layout is fixed here, not by the model: header, summary, then Schedules,
Data and Skills, then Approve or Cancel. The model supplies text for those slots and
nothing else, which is what keeps every card looking like the app instead of like
whatever the model felt like emitting.

Approving creates the space, its schedules and its catalog; cancelling leaves nothing
behind, because nothing was created yet.

    GET  /api/integrations/plans            pending plans
    GET  /api/integrations/plans/<id>       one plan, whatever became of it
    POST /api/integrations/plans/<id>/approve
    POST /api/integrations/plans/<id>/cancel
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

MAX_SCHEDULES = 12
MAX_COLLECTIONS = 12
MAX_SKILLS = 6
_MAX_TEXT = 400
# /api/integrations/<id> belongs to another handler for these, so a space with one of
# these ids could be listed but never opened, paused or deleted.
RESERVED_IDS = {"photon", "plans"}
_PLAN_TTL_SECONDS = 7 * 24 * 3600

_LOCK = threading.Lock()


class PlanError(ValueError):
    """The plan doesn't fit the card. The message names the field."""


def _plans_path() -> Path:
    from jarviscopilot_constants import get_hermes_home

    return Path(get_hermes_home()) / "integration_plans.json"


def _load() -> list[dict]:
    try:
        raw = json.loads(_plans_path().read_text())
        plans = raw.get("plans") if isinstance(raw, dict) else raw
        return [p for p in (plans or []) if isinstance(p, dict)]
    except (OSError, json.JSONDecodeError):
        return []


def _save(plans: list[dict]) -> None:
    path = _plans_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps({"plans": plans}, ensure_ascii=False, indent=2))
    tmp.replace(path)


def _text(value: Any, field: str, *, required: bool = True, limit: int = _MAX_TEXT) -> str:
    text = str(value or "").strip()
    if required and not text:
        raise PlanError(f"{field} is required")
    if len(text) > limit:
        raise PlanError(f"{field} is longer than {limit} characters")
    return text


def validate(plan: dict) -> dict:
    """The plan as the card will render it, or PlanError naming the bad field."""
    from jarvis_registry.store import slug

    if not isinstance(plan, dict):
        raise PlanError("the plan must be an object")

    name = _text(plan.get("name"), "name", limit=64)
    space_id = slug(str(plan.get("space_id") or "").strip() or name)
    if space_id in RESERVED_IDS:
        raise PlanError(f"{space_id!r} is not available as an integration id")
    out = {
        "id": uuid.uuid4().hex[:12],
        "space_id": space_id,
        "name": name,
        "summary": _text(plan.get("summary"), "summary"),
        "icon": _text(plan.get("icon"), "icon", required=False, limit=32),
        "schedules": [],
        "collections": [],
        "skills": [],
        "created_at": time.time(),
        "status": "pending",
    }

    schedules = plan.get("schedules") or []
    if not isinstance(schedules, list):
        raise PlanError("schedules must be a list")
    if len(schedules) > MAX_SCHEDULES:
        raise PlanError(f"a plan can propose at most {MAX_SCHEDULES} schedules")
    for i, item in enumerate(schedules):
        if not isinstance(item, dict):
            raise PlanError(f"schedules[{i}] must be an object")
        out["schedules"].append({
            "name": _text(item.get("name"), f"schedules[{i}].name", limit=64),
            "schedule": _text(item.get("schedule"), f"schedules[{i}].schedule", limit=64),
            "purpose": _text(item.get("purpose"), f"schedules[{i}].purpose"),
            "prompt": _text(item.get("prompt"), f"schedules[{i}].prompt", limit=4000),
        })

    collections = plan.get("collections") or []
    if not isinstance(collections, list):
        raise PlanError("collections must be a list")
    if len(collections) > MAX_COLLECTIONS:
        raise PlanError(f"a plan can propose at most {MAX_COLLECTIONS} collections")
    for i, item in enumerate(collections):
        if not isinstance(item, dict):
            raise PlanError(f"collections[{i}] must be an object")
        out["collections"].append({
            "name": _text(item.get("name"), f"collections[{i}].name", limit=64),
            "description": _text(item.get("description"), f"collections[{i}].description"),
        })

    skills = plan.get("skills") or []
    if not isinstance(skills, list):
        raise PlanError("skills must be a list")
    if len(skills) > MAX_SKILLS:
        raise PlanError(f"a plan can propose at most {MAX_SKILLS} skills")
    for i, item in enumerate(skills):
        if not isinstance(item, dict):
            raise PlanError(f"skills[{i}] must be an object")
        out["skills"].append({
            "name": _text(item.get("name"), f"skills[{i}].name", limit=64),
            "purpose": _text(item.get("purpose"), f"skills[{i}].purpose"),
        })

    if not out["schedules"] and not out["collections"] and not out["skills"]:
        raise PlanError("a plan needs at least one schedule, collection or skill")
    return out


def propose(plan: dict) -> dict:
    """Validate and store a plan as pending. Nothing is created yet."""
    entry = validate(plan)
    with _LOCK:
        plans = [p for p in _load()
                 if p.get("status") != "pending" or _age(p) < _PLAN_TTL_SECONDS]
        plans.append(entry)
        pending_plans = [p for p in plans if p.get("status") == "pending"]
        decided = [p for p in plans if p.get("status") != "pending"]
        _save(decided[-50:] + pending_plans)
    return entry


def _age(plan: dict) -> float:
    """Seconds since a plan was proposed. A file edited by hand may have anything."""
    try:
        return time.time() - float(plan.get("created_at") or 0)
    except (TypeError, ValueError):
        return 0.0


def pending() -> list[dict]:
    with _LOCK:
        return [p for p in _load() if p.get("status") == "pending"]


def get(plan_id: str) -> Optional[dict]:
    return next((p for p in _load() if p.get("id") == plan_id), None)


def cancel(plan_id: str) -> bool:
    with _LOCK:
        plans = _load()
        for plan in plans:
            if plan.get("id") == plan_id and plan.get("status") == "pending":
                plan["status"] = "cancelled"
                _save(plans)
                return True
    return False


def approve(plan_id: str) -> dict:
    """Create what the plan described: the space, its catalog and its schedules.

    Skills are listed for the agent to write; a card can't author a skill on its own.
    """
    from cron.jobs import create_job
    from jarvis_registry.store import shared

    # Claim the plan before building anything: check-then-act outside the lock let
    # two Create presses both pass the pending test and create every job twice.
    with _LOCK:
        plans = _load()
        plan = next((p for p in plans if p.get("id") == plan_id), None)
        if plan is None:
            raise PlanError(f"no plan {plan_id!r}")
        if plan.get("status") != "pending":
            raise PlanError(f"that plan was already {plan.get('status')}")
        plan["status"] = "approved"
        plan["approved_at"] = time.time()
        _save(plans)

    space = shared().space(plan["space_id"], name=plan["name"],
                           description=plan["summary"], icon=plan.get("icon") or "")
    for collection in plan["collections"]:
        space.collection(collection["name"]).describe(collection["description"])

    created_schedules = []
    for item in plan["schedules"]:
        try:
            job = create_job(prompt=item["prompt"], schedule=item["schedule"],
                             name=item["name"], integration=space.id)
            created_schedules.append({"id": job.get("id"), "name": job.get("name")})
        except Exception as exc:                  # one bad expression shouldn't sink the rest
            logger.warning("integration plan %s: schedule %r failed: %s",
                           plan_id, item.get("name"), exc)
            created_schedules.append({"name": item["name"], "error": str(exc)})

    with _LOCK:
        plans = _load()
        for stored in plans:
            if stored.get("id") == plan_id:
                stored["created_schedules"] = created_schedules
        _save(plans)

    return {
        "id": plan_id,
        "space_id": space.id,
        "name": plan["name"],
        "schedules": created_schedules,
        "collections": [c["name"] for c in plan["collections"]],
        "skills": [s["name"] for s in plan["skills"]],
    }


# ── HTTP ─────────────────────────────────────────────────────────────────────
def handle_get(handler, parsed) -> bool:
    from api.helpers import j

    if parsed.path == "/api/integrations/plans":
        j(handler, {"plans": pending()})
        return True
    if not parsed.path.startswith("/api/integrations/plans/"):
        return False
    # One plan by id, approved or cancelled included: the card in the chat has to
    # render the same way when the conversation is scrolled back to months later.
    plan_id = parsed.path[len("/api/integrations/plans/"):].strip("/")
    if not plan_id or "/" in plan_id:
        return False
    plan = get(plan_id)
    if plan is None:
        j(handler, {"error": f"no plan {plan_id!r}"}, status=404)
        return True
    j(handler, plan)
    return True


def handle_post(handler, parsed, body) -> bool:
    from api.helpers import j

    path = parsed.path
    if not path.startswith("/api/integrations/plans/"):
        return False
    rest = path[len("/api/integrations/plans/"):].strip("/")
    plan_id, _, action = rest.partition("/")
    try:
        if action == "approve":
            j(handler, approve(plan_id))
            return True
        if action == "cancel":
            if not cancel(plan_id):
                j(handler, {"error": "that plan is no longer pending"}, status=404)
                return True
            j(handler, {"ok": True, "id": plan_id})
            return True
    except PlanError as exc:
        j(handler, {"error": str(exc)}, status=400)
        return True
    except Exception as exc:
        logger.warning("integration plan action failed", exc_info=True)
        j(handler, {"error": str(exc)}, status=500)
        return True
    return False
