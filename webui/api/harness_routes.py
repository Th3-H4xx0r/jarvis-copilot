"""Pure HTTP dispatcher for the harness API.

``handle_harness_request`` takes the method, the path AFTER ``/api/harnesses``,
the parsed JSON body and a ``HarnessStore``; it returns ``(status, payload)``.
The webui server has no ``do_PUT``, so the API is GET/POST/DELETE only::

    GET    ""                          -> {harnesses, assignments, overrides}
    POST   /designs {design}           -> {ok, design} | 400 {ok:false, errors}
    POST   /designs/<id>/delete        -> {ok} | 404          (alias for DELETE)
    DELETE /designs/<id>               -> {ok} | 404
    POST   /assign {surface: default|voice|chat, harness_id ("" clears voice/chat)}
                                       -> {ok, assignments, overrides} | 400
    GET    /jobs/<session_id>          -> {jobs: [card]}   (Background job cards)
    POST   /jobs/<session_id>/<job_id>/stop -> {ok} | 404
"""
from __future__ import annotations

import re

HARNESS_PATH_PREFIX = "/api/harnesses"
_RE_DESIGN = re.compile(r"^/designs/([A-Za-z0-9_-]+)$")
_RE_DELETE = re.compile(r"^/designs/([A-Za-z0-9_-]+)/delete$")
_RE_JOBS = re.compile(r"^/jobs/([A-Za-z0-9_-]+)$")
_RE_JOB_STOP = re.compile(r"^/jobs/([A-Za-z0-9_-]+)/([A-Za-z0-9_-]+)/stop$")


def _delete(store, hid):
    if store.delete_design(hid):
        return 200, {"ok": True}
    return 404, {"ok": False, "error": "not found (built-ins cannot be deleted)"}


def handle_harness_request(method, path, body, store):
    body = body if isinstance(body, dict) else {}
    p = (path or "").split("?", 1)[0].rstrip("/")
    if method == "GET" and p == "":
        return 200, store.snapshot()
    if method == "GET" and _RE_JOBS.match(p):
        from api.harness_runner import session_job_cards
        return 200, {"jobs": session_job_cards(_RE_JOBS.match(p).group(1))}
    if method == "POST" and _RE_JOB_STOP.match(p):
        from api.harness_runner import stop_job
        if stop_job(*_RE_JOB_STOP.match(p).groups()):
            return 200, {"ok": True}
        return 404, {"ok": False, "error": "no running job with that id in this chat"}
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
                return 200, {"ok": True, "assignments": store.get_assignments(),
                             "overrides": store.overrides()}
            return 400, {"ok": False, "error": "unknown surface or harness"}
    return 404, {"ok": False, "error": "unknown harness endpoint"}


_RE_JOB_VIEW = re.compile(r"^/jobs/([A-Za-z0-9_~-]+)/([A-Za-z0-9_-]+)/(view|stream)$")


def route(req) -> bool:
    """Mounted at /api/harnesses (api/mounts.py)."""
    job = _RE_JOB_VIEW.match(req.sub) if req.method == "GET" else None
    if job:
        session_id, job_id, what = job.groups()
        if what == "stream":
            return _stream_job(req.handler, session_id, job_id)
        from api.harness_runner import job_view
        view = job_view(session_id, job_id)
        if view is None:
            return req.reply(404, {"error": "no such job in this chat"})
        return req.reply(200, view)
    from api.harness_store import store_for_request
    status, payload = handle_harness_request(req.method, req.sub_with_query, req.body, store_for_request())
    return req.reply(status, payload)


def _stream_job(handler, session_id, job_id) -> bool:
    """SSE: a Background job's own run, in /api/chat/stream's event format —
    everything so far, then live until it ends. A job that already ended (or
    is unknown) gets a bare ``stream_end``: its view comes from /view."""
    import time
    from api import sse
    from api.helpers import j
    from api.harness_runner import job_feed, job_view
    if job_view(session_id, job_id) is None:
        j(handler, {"error": "no such job in this chat"}, status=404)
        return True
    sse.open_stream(handler)
    try:
        feed = job_feed(job_id)
        # A job queued behind the worker's previous one has no feed yet: wait
        # for it to start rather than telling the viewer it is over.
        while feed is None:
            view = job_view(session_id, job_id)
            if view is None or not view.get("running"):
                sse.send(handler, 'stream_end', {'job_id': job_id})
                return True
            sse.keepalive(handler)
            time.sleep(1.0)
            feed = job_feed(job_id)
        cursor = None
        while True:
            events, cursor, closed = feed.read(cursor, sse.HEARTBEAT_SECONDS)
            for event, data in events:
                sse.send(handler, event, data)
                if event == 'stream_end':
                    return True
            if closed and not events:
                sse.send(handler, 'stream_end', {'job_id': job_id})
                return True
            if not events:
                sse.keepalive(handler)
    except sse.CLIENT_GONE:
        pass
    return True
