"""Pure HTTP dispatcher for the widget designs API.

``handle_widgets_request`` takes the method, the path AFTER ``/api/widgets``, the
parsed JSON body and a ``WidgetStore``; it returns ``(status_code, payload)``,
which ``routes.py`` puts on the wire with ``j(handler, payload, status=status)``.
The webui server has no ``do_PUT``, so the API is GET/POST/DELETE only::

    GET    /designs                 -> {designs, catalog}
    GET    /designs/<id>            -> {ok, design} | 404
    POST   /designs {design}        -> {ok, design, warnings} | 400 {ok:false, errors}
    POST   /designs/<id>/delete     -> {ok} | 404          (alias for DELETE)
    DELETE /designs/<id>            -> {ok} | 404
    GET    /catalog                 -> {catalog}
    POST   /catalog {catalog:[...]} -> {ok} | 400 {ok:false, errors}
"""
from __future__ import annotations

import re

WIDGETS_PATH_PREFIX = "/api/widgets"

_RE_DESIGN = re.compile(r"^/designs/([A-Za-z0-9_-]+)$")
_RE_DELETE = re.compile(r"^/designs/([A-Za-z0-9_-]+)/delete$")


def handle_widgets_request(method, path, body, store):
    body = body if isinstance(body, dict) else {}
    p = path.split("?", 1)[0]
    if len(p) > 1:
        p = p.rstrip("/") or "/"

    if method == "GET":
        if p == "/designs":
            return 200, store.snapshot()
        if p == "/catalog":
            return 200, {"catalog": store.get_catalog()}
        m = _RE_DESIGN.match(p)
        if m:
            doc = store.get_design(m.group(1))
            if doc is None:
                return 404, {"ok": False, "error": "design not found"}
            return 200, {"ok": True, "design": doc}
        return 404, {"ok": False, "error": "unknown widgets endpoint"}

    if method == "DELETE":
        m = _RE_DESIGN.match(p)
        if m:
            return _delete(store, m.group(1))
        return 404, {"ok": False, "error": "unknown widgets endpoint"}

    if method == "POST":
        if p == "/designs":
            return _upsert(store, body)
        if p == "/catalog":
            return _catalog(store, body)
        m = _RE_DELETE.match(p)
        if m:
            return _delete(store, m.group(1))
        return 404, {"ok": False, "error": "unknown widgets endpoint"}

    return 405, {"ok": False, "error": f"method {method} not allowed"}


def _upsert(store, body):
    design = body
    if isinstance(body.get("design"), dict) and "presentations" not in body:
        design = body["design"]
    saved, errors, warnings = store.upsert_design(design)
    if saved is None:
        return 400, {"ok": False, "error": "invalid design", "errors": errors}
    return 200, {"ok": True, "design": saved, "warnings": warnings}


def _catalog(store, body):
    ok, errors = store.set_catalog(body.get("catalog"))
    if not ok:
        return 400, {"ok": False, "error": "invalid catalog", "errors": errors}
    return 200, {"ok": True}


def _delete(store, design_id):
    if not store.delete_design(design_id):
        return 404, {"ok": False, "error": "design not found"}
    return 200, {"ok": True}
