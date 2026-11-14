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
    if str(args.get("key") or "").strip() == "power":
        return _fail("'power' is a Power integration's on/off and settings; change it "
                     "with power_set")
    if str(args.get("key") or "").strip() == "ui":
        return _fail("'ui' is the integration's own UI; change it with integration_ui_set, "
                     "which checks it before storing it")
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
    if _is_power_id(space_id):
        return _fail(f"{space_id!r} is a built-in Power integration; it can't be created "
                     "here (switch it on or configure it with power_set)")
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


def _is_power_id(space_id: str) -> bool:
    """A Power integration's id or its space: built into the code, not made in chat."""
    try:
        from jarvis_power import discovery, state

        return space_id in discovery.integrations() or state.is_power_space(space_id)
    except Exception:
        return False


# general is the catch-all for schedules that belong nowhere; photon is the iMessage
# setup endpoint. Neither is a new integration.
_RESERVED_IDS = {"general", "photon", "plans", "ui"}


# ── an integration's own UI ──────────────────────────────────────────────────
_STATE_PREVIEW_CHARS = 4000

_UI_GET = {
    "name": "integration_ui_get",
    "description": (
        "Read an integration's own UI — the card on the Integrations tab, the page at "
        "the top of its screen, and the scripts they run (with their code) — or null "
        "when it has none. Read it before changing it."
    ),
    "parameters": {
        "type": "object",
        "properties": {"space": {"type": "string", "description": "The integration's space id"}},
        "required": ["space"],
    },
}


def _h_ui_get(args=None, **_kw) -> str:
    args = args or {}
    try:
        from jarvis_registry import ui

        space_id = str(args.get("space") or "").strip()
        return _ok(space=space_id, ui=ui.get_ui(space_id))
    except Exception as exc:
        return _fail(str(exc))


_UI_SET = {
    "name": "integration_ui_set",
    "description": (
        "Store an integration's own UI: a compact `card` for the Integrations tab and/or "
        "a full `page`, both layout trees of the integration-ui skill's elements, plus "
        "the Python `scripts` they run (`load` builds the state the trees bind to; every "
        "action a control names needs a script). Send the WHOLE UI each time — a card, "
        "page or script you leave out is removed. It is checked first (errors come back "
        "one per line), then stored and `load` is run so you can see the state it built. "
        "Read the integration-ui skill before writing one."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "space": {"type": "string", "description": "The integration's space id"},
            "card": {"type": "object", "description": "Root node of the card"},
            "page": {"type": "object", "description": "Root node of the page"},
            "scripts": {
                "type": "object",
                "description": ('{"load": {"code": "<python>"}, "add_item": {"code": "...", '
                                '"confirm"?: "Add it?", "label"?: "Add item"}}'),
            },
            "prompt": {"type": "string",
                       "description": "What the person asked for, kept for later edits"},
        },
        "required": ["space", "scripts"],
    },
}


def _h_ui_set(args=None, **_kw) -> str:
    args = args or {}
    try:
        from jarvis_registry import ui

        space_id = str(args.get("space") or "").strip()
        scripts = args.get("scripts")
        if isinstance(scripts, dict):
            # A bare string is the code; saves a level of nesting for the model.
            scripts = {name: ({"code": body} if isinstance(body, str) else body)
                       for name, body in scripts.items()}
        presentations = {key: args[key] for key in ("card", "page") if args.get(key) is not None}
        doc = {"schema": ui.SCHEMA, "presentations": presentations, "scripts": scripts}
        if str(args.get("prompt") or "").strip():
            doc["prompt"] = str(args["prompt"]).strip()
        _reg().open(space_id)
        errors, warnings = ui.validate_ui(doc)
        if errors:
            return json.dumps({"ok": False, "errors": errors, "warnings": warnings,
                               "error": "the UI was not stored:\n" + "\n".join(errors)},
                              ensure_ascii=False)
        stored = ui.save_ui(space_id, doc)
        loaded = ui.load_state(space_id)
    except Exception as exc:
        errors = getattr(exc, "errors", None)
        if errors:
            return json.dumps({"ok": False, "errors": errors,
                               "error": "the UI was not stored:\n" + "\n".join(errors)})
        return _fail(str(exc))
    return _ok(space=space_id, version=stored["version"],
               state_preview=_preview(loaded["state"]), load_error=loaded["error"],
               warnings=warnings,
               note=("Stored, but load failed — fix the load script and set it again."
                     if loaded["error"] else
                     "Stored. Check the state has what the trees bind to; try an action "
                     "with integration_ui_test if it is safe to run."))


def _preview(state):
    text = json.dumps(state, ensure_ascii=False, default=str)
    if len(text) <= _STATE_PREVIEW_CHARS:
        return state
    return text[:_STATE_PREVIEW_CHARS] + f"… ({len(text)} characters in all)"


_UI_TEST = {
    "name": "integration_ui_test",
    "description": (
        "Run an integration UI's `load` script (no `action`) or one action script, the "
        "same way a tap in the app does, and see the state, toast or error. An action "
        "runs FOR REAL against the real data — adding, deleting, sending — so only test "
        "actions that are safe to run, or undo what they did."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "space": {"type": "string", "description": "The integration's space id"},
            "action": {"type": "string", "description": "A script name; omit to run load"},
            "event": {
                "type": "object",
                "description": ('What the app would send: {"control"?, "value"?, '
                                '"inputs"?: {"<id>": value}, "row"?: {...}}'),
            },
        },
        "required": ["space"],
    },
}


def _h_ui_test(args=None, **_kw) -> str:
    args = args or {}
    try:
        from jarvis_registry import ui

        space_id = str(args.get("space") or "").strip()
        if ui.get_ui(space_id) is None:
            return _fail(f"{space_id!r} has no UI yet; store one with integration_ui_set")
        action = str(args.get("action") or "").strip()
        if not action or action == "load":
            out = ui.load_state(space_id)
            return json.dumps({"ok": out["error"] is None, "version": out["version"],
                               "state": _preview(out["state"]), "error": out["error"]},
                              ensure_ascii=False, default=str)
        out = ui.run_action(space_id, action, args.get("event") or {})
        return json.dumps({**out, "state": _preview(out.get("state") or {})},
                          ensure_ascii=False, default=str)
    except Exception as exc:
        return _fail(str(exc))


_READY = {
    "name": "integration_ready",
    "description": (
        "Call this once a new integration is actually built and there is nothing "
        "left to ask. It tells the setup sheet to stop offering a reply box and "
        "offer Close instead. An integration is built when something RUNS in it — "
        "a schedule, or a skill that tells you how to do its work. A space with "
        "only a settings document does nothing at all, and this will refuse it. "
        "Never call this as a way of ending a conversation early."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "space": {"type": "string", "description": "The integration's space id"},
            "summary": {"type": "string", "description": "One line: what it now does"},
            "on_request": {
                "type": "boolean",
                "description": (
                    "True only when this integration is meant to run when the user "
                    "asks, not on its own. Anything the user asked you to watch, "
                    "track, monitor or tell them about needs a schedule instead — a "
                    "skill by itself is instructions nobody is following."
                ),
            },
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
        space = _reg().open(space_id)
        info = space.info()
    except Exception as exc:
        return _fail(f"{exc} — build the integration before saying it is ready")

    # An integration that nothing runs in is a name and a description. The sheet
    # closing on one is how a user ends up with an empty shell they have to work
    # out for themselves, so this is refused here rather than asked for in a prompt.
    from jarvis_registry.integrations import schedules_for, skills_for

    schedules = schedules_for(space_id)
    skills = skills_for(space_id)

    # A skill is a description of work; a schedule is what does it. "Watch the
    # Houston airports and tell me" with a skill and no schedule is a document
    # nobody reads, so saying so out loud is the only way past this.
    if not schedules and skills and not bool(args.get("on_request")):
        return _fail(
            f"{space_id!r} has a skill but no schedule, so nothing will ever run it — "
            f"a skill is instructions, followed only when someone asks. If the user "
            f"wants this watched or checked for them, add the schedule that does it "
            f"(cronjob action=create, passing integration='{space_id}'). If it really "
            f"is meant to run only when they ask, call this again with on_request=true.")

    if not schedules and not skills:
        stored = [d["key"] for d in space.documents()] + [c["name"] for c in space.collections()]
        return _fail(
            f"{space_id!r} has no schedules and no skills, so nothing in it runs — "
            + (f"it only holds {', '.join(stored)}. " if stored else "it is empty. ")
            + "Add the schedule that does its work (cronjob action=create, passing "
              f"integration='{space_id}'), or write a skill with "
              f"`integration: {space_id}` in its front matter, then say it is ready.")

    return _ok(space=space_id, name=info.get("name"),
               schedules=[j.get("name") or j["id"] for j in schedules],
               skills=[k["name"] for k in skills],
               summary=str(args.get("summary") or "").strip(),
               card={"kind": "integration_ready", "space": space_id})


registry.register(name="integration_create", toolset="registry",
                  schema=_CREATE, handler=_h_create, emoji="✨")

registry.register(name="integration_ready", toolset="registry",
                  schema=_READY, handler=_h_ready, emoji="✅")

registry.register(name="integration_ui_get", toolset="registry",
                  schema=_UI_GET, handler=_h_ui_get, emoji="🖼️")
registry.register(name="integration_ui_set", toolset="registry",
                  schema=_UI_SET, handler=_h_ui_set, emoji="🎨")
registry.register(name="integration_ui_test", toolset="registry",
                  schema=_UI_TEST, handler=_h_ui_test, emoji="🧪")

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
