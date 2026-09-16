"""Agent tools over the central registry (``jarvis_registry``).

Long-lived data an integration keeps — a casino session, an email digest, the
"last seen" cursor of a monitor — lives in the registry instead of a JSON file in
the workspace. These tools are how any chat, voice or scheduled turn reads and
writes it; every one of them runs on the server.

Start with ``registry_catalog``: it lists the spaces and what each holds, in a few
hundred tokens, so a query can be aimed rather than guessed.
"""
from __future__ import annotations

import json
from typing import Any

from tools.registry import registry

_MAX_RESULT_RECORDS = 200


def _reg():
    from jarvis_registry.store import shared  # import cost stays off startup

    return shared()


def _fail(message: str) -> str:
    return json.dumps({"ok": False, "error": message})


def _ok(**body: Any) -> str:
    return json.dumps({"ok": True, **body}, ensure_ascii=False, default=str)


# ── catalog ──────────────────────────────────────────────────────────────────
_CATALOG = {
    "name": "registry_catalog",
    "description": (
        "What the central registry holds: every integration's space, its documents "
        "and its record collections, each with a one-line description and a row "
        "count. Read this before querying so you know what exists. Optionally pass "
        "`space` for one integration."
    ),
    "parameters": {
        "type": "object",
        "properties": {"space": {"type": "string", "description": "One space id, e.g. 'casino'"}},
    },
}


def _h_catalog(args=None, **_kw) -> str:
    args = args or {}
    try:
        return _ok(spaces=_reg().catalog(space_id=(args.get("space") or "").strip() or None))
    except Exception as exc:
        return _fail(str(exc))


# ── documents ────────────────────────────────────────────────────────────────
_GET = {
    "name": "registry_get",
    "description": (
        "Read one document from an integration's space — settings, state, a cursor. "
        "Documents are overwritten in place; for history use registry_query."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "space": {"type": "string"},
            "key": {"type": "string"},
        },
        "required": ["space", "key"],
    },
}


def _h_get(args=None, **_kw) -> str:
    args = args or {}
    try:
        space = _reg().open(str(args.get("space") or ""))
        return _ok(space=space.id, key=args.get("key"), body=space.get(str(args.get("key") or "")))
    except Exception as exc:
        return _fail(str(exc))


_PUT = {
    "name": "registry_put",
    "description": (
        "Write a document into an integration's space, replacing what was there. Use "
        "for settings and state, not for history. Give `description` the first time so "
        "the catalog explains it."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "space": {"type": "string"},
            "key": {"type": "string"},
            "body": {"type": "object", "description": "Any JSON object"},
            "description": {"type": "string"},
        },
        "required": ["space", "key", "body"],
    },
}


def _h_put(args=None, **_kw) -> str:
    args = args or {}
    try:
        space = _reg().open(str(args.get("space") or ""))
        space.put(str(args.get("key") or ""), args.get("body"), description=args.get("description"))
        return _ok(space=space.id, key=args.get("key"))
    except Exception as exc:
        return _fail(str(exc))


# ── records ──────────────────────────────────────────────────────────────────
_APPEND = {
    "name": "registry_append",
    "description": (
        "Append one record to a collection — a casino session, an email digest, a "
        "workout. Records are the history: never rewrite one, append a correction. "
        "`ts` defaults to now (epoch seconds)."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "space": {"type": "string"},
            "collection": {"type": "string"},
            "body": {"type": "object", "description": "Any JSON object"},
            "ts": {"type": "number", "description": "Epoch seconds; defaults to now"},
        },
        "required": ["space", "collection", "body"],
    },
}


def _h_append(args=None, **_kw) -> str:
    args = args or {}
    try:
        space = _reg().open(str(args.get("space") or ""))
        record_id = space.append(str(args.get("collection") or ""), args.get("body"),
                                 ts=args.get("ts"), source="agent")
        return _ok(space=space.id, collection=args.get("collection"), id=record_id)
    except Exception as exc:
        return _fail(str(exc))


_QUERY = {
    "name": "registry_query",
    "description": (
        "Records from a collection, newest first. Narrow with `since`/`until` (epoch "
        "seconds) and `where` (exact matches on top-level fields). This is how one "
        "integration reads another's history."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "space": {"type": "string"},
            "collection": {"type": "string"},
            "since": {"type": "number"},
            "until": {"type": "number"},
            "where": {"type": "object", "description": 'e.g. {"game": "blackjack"}'},
            "limit": {"type": "integer", "description": f"1-{_MAX_RESULT_RECORDS}, default 50"},
            "oldest_first": {"type": "boolean"},
        },
        "required": ["space", "collection"],
    },
}


def _h_query(args=None, **_kw) -> str:
    args = args or {}
    try:
        space = _reg().open(str(args.get("space") or ""))
        limit = min(int(args.get("limit") or 50), _MAX_RESULT_RECORDS)
        rows = space.records(
            str(args.get("collection") or ""),
            since=args.get("since"), until=args.get("until"),
            where=args.get("where") or None, limit=limit,
            newest_first=not bool(args.get("oldest_first")),
        )
        return _ok(space=space.id, collection=args.get("collection"), count=len(rows), records=rows)
    except Exception as exc:
        return _fail(str(exc))


# ── catalog upkeep ───────────────────────────────────────────────────────────
_DESCRIBE = {
    "name": "registry_describe",
    "description": (
        "Explain a collection (or the space itself) in the catalog, so later turns and "
        "other integrations know what the data means. Say it in one line, and name the "
        "fields that matter."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "space": {"type": "string"},
            "collection": {"type": "string", "description": "Omit to describe the space"},
            "description": {"type": "string"},
            "fields": {"type": "object", "description": 'e.g. {"net": "dollars won"}'},
        },
        "required": ["space", "description"],
    },
}


def _h_describe(args=None, **_kw) -> str:
    args = args or {}
    try:
        space = _reg().open(str(args.get("space") or ""))
        description = str(args.get("description") or "")
        collection = (args.get("collection") or "").strip()
        if collection:
            space.collection(collection).describe(description, fields=args.get("fields") or None)
        else:
            space.describe(description)
        return _ok(space=space.id, collection=collection or None)
    except Exception as exc:
        return _fail(str(exc))


_PLAN = {
    "name": "integration_plan_propose",
    "description": (
        "Propose a new integration and show the user a plan card in the chat. Use this "
        "when they ask for something Jarvis should track or run on a schedule. Nothing "
        "is created until they approve the card: describe what it is for, the schedules "
        "you want (with a cron expression or an interval like 'every 15m' and the prompt "
        "each one runs), the record collections it will keep, and any skill you would "
        "write. Keep every line short — the card's layout is fixed and only takes text."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "name": {"type": "string", "description": "What to call it, e.g. 'Gym Sessions'"},
            "space_id": {"type": "string", "description": "Optional slug; derived from the name otherwise"},
            "summary": {"type": "string", "description": "One line: what it does for the user"},
            "icon": {"type": "string", "description": "Optional one-word icon name"},
            "schedules": {
                "type": "array",
                "description": "Scheduled runs this integration owns",
                "items": {
                    "type": "object",
                    "properties": {
                        "name": {"type": "string"},
                        "schedule": {"type": "string", "description": "'0 7 * * *' or 'every 15m'"},
                        "purpose": {"type": "string", "description": "One line, for the card"},
                        "prompt": {"type": "string", "description": "What the run is asked to do"},
                    },
                    "required": ["name", "schedule", "purpose", "prompt"],
                },
            },
            "collections": {
                "type": "array",
                "description": "Record collections it will keep in the registry",
                "items": {
                    "type": "object",
                    "properties": {
                        "name": {"type": "string"},
                        "description": {"type": "string", "description": "One line: what a record is"},
                    },
                    "required": ["name", "description"],
                },
            },
            "skills": {
                "type": "array",
                "description": "Skills you would write for it",
                "items": {
                    "type": "object",
                    "properties": {
                        "name": {"type": "string"},
                        "purpose": {"type": "string"},
                    },
                    "required": ["name", "purpose"],
                },
            },
        },
        "required": ["name", "summary"],
    },
}


def _h_plan(args=None, **_kw) -> str:
    args = args or {}
    try:
        from api.integration_plans import propose
    except Exception:
        try:
            import sys
            from pathlib import Path

            sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "webui"))
            from api.integration_plans import propose
        except Exception as exc:
            return _fail(f"the integration planner is unavailable: {exc}")
    try:
        plan = propose(args)
    except Exception as exc:
        return _fail(str(exc))
    return _ok(plan=plan, card={"kind": "integration_plan", "plan_id": plan["id"]},
               note="The plan card is in the chat; it only takes effect once the user approves it.")


_CREATE = {
    "name": "integration_create",
    "description": (
        "Make a new integration and return its space id. Call this FIRST when you are "
        "setting one up — every other registry tool writes into a space that already "
        "exists, so without this there is nowhere to put anything and the work ends up "
        "in 'general', which is the catch-all for things that belong nowhere. Give it "
        "the name the user would call it."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "name": {"type": "string", "description": "What to call it, e.g. 'Gym Sessions'"},
            "description": {"type": "string", "description": "One line: what it does"},
            "icon": {"type": "string",
                     "description": "One word: music, envelope, house, airplane, chips, "
                                    "chart, clock, bolt, book, heart"},
            "id": {"type": "string", "description": "Optional slug; derived from the name otherwise"},
        },
        "required": ["name"],
    },
}


def _h_create(args=None, **_kw) -> str:
    args = args or {}
    from jarvis_registry.store import slug

    name = str(args.get("name") or "").strip()
    if not name:
        return _fail("an integration needs a name")
    space_id = slug(str(args.get("id") or "").strip() or name)
    if space_id in _RESERVED_IDS:
        return _fail(f"{space_id!r} is not available as an integration id")
    try:
        reg = _reg()
        existed = reg.exists(space_id)
        space = reg.space(space_id, name=name,
                          description=str(args.get("description") or "").strip(),
                          icon=str(args.get("icon") or "").strip())
    except Exception as exc:
        return _fail(str(exc))
    return _ok(space=space.id, name=name, already_existed=existed,
               note=("That integration already existed; you are adding to it."
                     if existed else "Use this space id for everything else you create."))


# general is the catch-all for schedules that belong nowhere; photon is the iMessage
# setup endpoint. Neither is a new integration.
_RESERVED_IDS = {"general", "photon", "plans"}


_READY = {
    "name": "integration_ready",
    "description": (
        "Call this once a new integration is actually built and there is nothing "
        "left to ask. It tells the setup sheet to stop offering a reply box and "
        "offer Close instead. Only call it when the space exists and its schedules, "
        "data and skills are in place — never as a way of ending a conversation "
        "early."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "space": {"type": "string", "description": "The integration's space id"},
            "summary": {"type": "string", "description": "One line: what it now does"},
        },
        "required": ["space"],
    },
}


def _h_ready(args=None, **_kw) -> str:
    args = args or {}
    space_id = str(args.get("space") or "").strip().lower()
    if space_id in _RESERVED_IDS:
        return _fail(
            f"{space_id!r} is not a new integration — it is where things that belong "
            "nowhere else go. Call integration_create to make one, put the work in it, "
            "and say that space is ready instead.")
    try:
        info = _reg().open(space_id).info()
    except Exception as exc:
        return _fail(f"{exc} — build the integration before saying it is ready")
    return _ok(space=space_id, name=info.get("name"),
               summary=str(args.get("summary") or "").strip(),
               card={"kind": "integration_ready", "space": space_id})


registry.register(name="integration_create", toolset="registry",
                  schema=_CREATE, handler=_h_create, emoji="✨")

registry.register(name="integration_ready", toolset="registry",
                  schema=_READY, handler=_h_ready, emoji="✅")

registry.register(name="integration_plan_propose", toolset="registry",
                  schema=_PLAN, handler=_h_plan, emoji="🧩")

registry.register(name="registry_catalog", toolset="registry",
                  schema=_CATALOG, handler=_h_catalog, emoji="🗂️")
registry.register(name="registry_get", toolset="registry",
                  schema=_GET, handler=_h_get, emoji="📄")
registry.register(name="registry_put", toolset="registry",
                  schema=_PUT, handler=_h_put, emoji="📝")
registry.register(name="registry_append", toolset="registry",
                  schema=_APPEND, handler=_h_append, emoji="➕")
registry.register(name="registry_query", toolset="registry",
                  schema=_QUERY, handler=_h_query, emoji="🔎")
registry.register(name="registry_describe", toolset="registry",
                  schema=_DESCRIBE, handler=_h_describe, emoji="🏷️")
