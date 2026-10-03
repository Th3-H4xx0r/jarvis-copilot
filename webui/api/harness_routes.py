"""Pure HTTP dispatcher for the harness API.

``handle_harness_request`` takes the method, the path AFTER ``/api/harnesses``,
the parsed JSON body and a ``HarnessStore``; it returns ``(status, payload)``.
The webui server has no ``do_PUT``, so the API is GET/POST/DELETE only::

    GET    ""                          -> {harnesses, assignments}
    POST   /designs {design}           -> {ok, design} | 400 {ok:false, errors}
    POST   /designs/<id>/delete        -> {ok} | 404          (alias for DELETE)
    DELETE /designs/<id>               -> {ok} | 404
    POST   /assign {surface, harness_id} -> {ok, assignments} | 400
"""
from __future__ import annotations

import re

HARNESS_PATH_PREFIX = "/api/harnesses"
_RE_DESIGN = re.compile(r"^/designs/([A-Za-z0-9_-]+)$")
_RE_DELETE = re.compile(r"^/designs/([A-Za-z0-9_-]+)/delete$")


def _delete(store, hid):
    if store.delete_design(hid):
        return 200, {"ok": True}
    return 404, {"ok": False, "error": "not found (built-ins cannot be deleted)"}


def handle_harness_request(method, path, body, store):
    body = body if isinstance(body, dict) else {}
    p = (path or "").split("?", 1)[0].rstrip("/")
    if method == "GET" and p == "":
        return 200, store.snapshot()
    if method == "DELETE":
        m = _RE_DESIGN.match(p)
        if m:
            return _delete(store, m.group(1))
    if method == "POST":
        if p == "/designs":
            saved, errors = store.upsert_design(body.get("design"))
            if errors:
                return 400, {"ok": False, "errors": errors}
            return 200, {"ok": True, "design": saved}
        m = _RE_DELETE.match(p)
        if m:
            return _delete(store, m.group(1))
        if p == "/assign":
            if store.set_assignment(body.get("surface"), body.get("harness_id")):
                return 200, {"ok": True, "assignments": store.get_assignments()}
            return 400, {"ok": False, "error": "unknown surface or harness"}
    return 404, {"ok": False, "error": "unknown harness endpoint"}
