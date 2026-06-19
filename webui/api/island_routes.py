"""Pure HTTP dispatcher for the Dynamic Island Designs API.

``handle_island_request`` is a pure function (no http.server plumbing): it takes
the method, the path AFTER ``/api/island``, the parsed JSON body, an
``IslandStore``, and an optional ``token_store`` (for triggering an APNs push on
set-data). Returns ``(status_code, payload_dict)``. ``routes.py`` adapts the
tuple to the wire with ``j(handler, payload, status=status)``.

The webui HTTP server has no ``do_PUT`` — so the API is GET/POST/DELETE only::

    GET    /designs                       -> {designs, catalog, selection}
    GET    /designs/<id>                  -> {ok, design} | 404
    POST   /designs {design|{design}}     -> validate+upsert -> {ok, id} | 400
    POST   /selection {mode, pinnedId?}   -> {ok, selection} | 400
    POST   /designs/<id>/rules {...}      -> {ok} | 400/404
    POST   /designs/<id>/data {...|data}  -> set values + push -> {ok, data, pushed}
    POST   /designs/<id>/delete           -> {ok, removed} | 404   (alias for DELETE)
    DELETE /designs/<id>                  -> {ok, removed} | 404
"""
from __future__ import annotations

import re

ISLAND_PATH_PREFIX = "/api/island"

_RE_DESIGN = re.compile(r"^/designs/([A-Za-z0-9_-]+)$")
_RE_RULES = re.compile(r"^/designs/([A-Za-z0-9_-]+)/rules$")
_RE_DATA = re.compile(r"^/designs/([A-Za-z0-9_-]+)/data$")
_RE_DELETE = re.compile(r"^/designs/([A-Za-z0-9_-]+)/delete$")


def handle_island_request(method, path, body, store, token_store=None):
    body = body if isinstance(body, dict) else {}
    p = path.split("?", 1)[0]
    if len(p) > 1:
        p = p.rstrip("/") or "/"

    if method == "GET":
        if p == "/designs":
            return 200, store.snapshot()
        m = _RE_DESIGN.match(p)
        if m:
            doc = store.get_design(m.group(1))
            if doc is None:
                return 404, {"error": "design not found"}
            return 200, {"ok": True, "design": doc}
        return 404, {"error": "unknown island endpoint"}

    if method == "DELETE":
        m = _RE_DESIGN.match(p)
        if m:
            return _delete(store, m.group(1))
        return 404, {"error": "unknown island endpoint"}

    if method == "POST":
        if p == "/designs":
            return _upsert(store, body)
        if p == "/selection":
            return _selection(store, token_store, body)
        m = _RE_RULES.match(p)
        if m:
            return _rules(store, m.group(1), body)
        m = _RE_DATA.match(p)
        if m:
            return _data(store, token_store, m.group(1), body)
        m = _RE_DELETE.match(p)
        if m:
            return _delete(store, m.group(1))
        return 404, {"error": "unknown island endpoint"}

    return 405, {"error": f"method {method} not allowed"}


# ── handlers ────────────────────────────────────────────────────────────────

def _upsert(store, body):
    design = body.get("design") if isinstance(body.get("design"), dict) else body
    if not isinstance(design, dict) or "presentations" not in design:
        return 400, {"error": "expected a design object with presentations"}
    ok, errors = store.upsert_design(design)
    if not ok:
        return 400, {"error": "invalid design", "errors": errors}
    return 200, {"ok": True, "id": design.get("id")}


def _selection(store, token_store, body):
    mode = body.get("mode")
    pinned = body.get("pinnedId")
    ok, errors = store.set_selection(mode, pinned)
    if not ok:
        return 400, {"error": "invalid selection", "errors": errors}
    sel = store.get_selection()
    pushed = 0
    # Pinning a CUSTOM design → force-push it now so a suspended phone flips to it
    # immediately (the activity is last-write-wins; force bypasses the dedupe).
    if (token_store is not None and sel.get("mode") == "pinned"
            and sel.get("pinnedId") not in (None, "", "voice", "coding")):
        try:
            from api import island_la_push
            pushed = island_la_push.push_design_update(
                store, token_store, sel["pinnedId"], force=True)
        except Exception:
            pushed = 0
    return 200, {"ok": True, "selection": sel, "pushed": pushed}


def _rules(store, entry_id, body):
    kwargs = {}
    if "enabled" in body:
        kwargs["enabled"] = body["enabled"]
    if "priority" in body:
        kwargs["priority"] = body["priority"]
    if "conditions" in body:
        kwargs["conditions"] = body["conditions"]
    if "schedule" in body:
        kwargs["schedule"] = body["schedule"]
    ok, errors = store.set_rules(entry_id, **kwargs)
    if not ok:
        status = 404 if any("unknown entry" in e for e in errors) else 400
        return status, {"error": "could not set rules", "errors": errors}
    return 200, {"ok": True}


def _data(store, token_store, design_id, body):
    if store.get_design(design_id) is None:
        return 404, {"error": "design not found"}
    # Accept either {"data": {...}, "merge"?:bool} or the value map directly as
    # the body. In the bare-map form a key literally named "merge" stays as data.
    if isinstance(body.get("data"), dict):
        raw = body["data"]
        merge = bool(body.get("merge", True))
    else:
        raw = body
        merge = True
    data = store.set_data(design_id, raw, merge=merge)
    pushed = 0
    if token_store is not None:
        try:
            from api import island_la_push
            pushed = island_la_push.push_design_update(
                store, token_store, design_id)
        except Exception:
            pushed = 0
    return 200, {"ok": True, "data": data, "pushed": pushed}


def _delete(store, design_id):
    removed = store.delete_design(design_id)
    if not removed:
        return 404, {"error": "design not found or not deletable"}
    return 200, {"ok": True, "removed": True}
