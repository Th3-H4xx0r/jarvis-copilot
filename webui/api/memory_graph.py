"""HTTP for the memory map: the graph, a node's memories, fixing nodes, and
the recalls behind "memories used". Thin handlers over
plugins.memory.jarvis_memory.graph (contract: the 2026-10-22 design doc)."""
from __future__ import annotations

import logging
from urllib.parse import parse_qs

logger = logging.getLogger(__name__)


def _store_ns():
    from plugins.memory.jarvis_memory import external
    store, _embedder, namespace, _th = external._open()
    return store, namespace


def _arg(q, name, default=""):
    return (q.get(name, [default])[0] or default).strip()


def _int(value, default):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def handle_get(handler, parsed):
    """Returns None when the path isn't one of ours."""
    from api.helpers import bad, j
    from plugins.memory.jarvis_memory import graph
    path = parsed.path
    q = parse_qs(parsed.query or "")
    if path == "/api/jarvis-memory/graph":
        store, ns = _store_ns()
        types = [t for t in _arg(q, "types").split(",") if t]
        since = _arg(q, "since")
        try:
            return j(handler, graph.build(store, ns, center=_arg(q, "center", "me") or "me", types=types,
                                          since=float(since) if since else None,
                                          source=_arg(q, "source") or None,
                                          limit=_int(_arg(q, "limit"), 40)))
        except KeyError:
            return j(handler, {"error": "no such node"}, status=404)
        except ValueError:
            return bad(handler, "since must be a number")
    if path == "/api/jarvis-memory/graph/highlight":
        store, ns = _store_ns()
        try:
            return j(handler, graph.highlight(store, ns, int(_arg(q, "recall"))))
        except ValueError:
            return bad(handler, "recall must be a recall id")
        except KeyError:
            return j(handler, {"error": "no such recall"}, status=404)
    if path == "/api/jarvis-memory/entity":
        store, _ns = _store_ns()
        try:
            return j(handler, graph.entity_detail(store, _arg(q, "id"), limit=_int(_arg(q, "limit"), 50)))
        except KeyError:
            return j(handler, {"error": "no such node"}, status=404)
    if path == "/api/jarvis-memory/recalls":
        store, _ns = _store_ns()
        return j(handler, {"recalls": graph.recalls(store, limit=max(1, min(_int(_arg(q, "limit"), 30), 200)),
                                                    session_id=_arg(q, "session_id") or None)})
    return None


def handle_post(handler, parsed, body):
    from api.helpers import bad, j
    from plugins.memory.jarvis_memory import graph
    body = body if isinstance(body, dict) else {}
    path = parsed.path
    if path == "/api/jarvis-memory/entity":
        store, _ns = _store_ns()
        aliases = body.get("aliases")
        if aliases is not None and (not isinstance(aliases, list) or not all(isinstance(a, str) for a in aliases)):
            return bad(handler, "aliases must be a list of names")
        pinned = body.get("pinned")
        if pinned is not None and not isinstance(pinned, bool):
            return bad(handler, "pinned must be true or false")
        try:
            entity = graph.update_entity(store, str(body.get("id") or ""), label=body.get("label"),
                                         aliases=aliases, pinned=pinned)
        except KeyError:
            return j(handler, {"error": "no such node"}, status=404)
        except ValueError as exc:
            return bad(handler, str(exc))
        return j(handler, {"entity": entity})
    if path == "/api/jarvis-memory/entity/merge":
        store, _ns = _store_ns()
        try:
            entity = graph.merge(store, str(body.get("from") or ""), str(body.get("into") or ""))
        except KeyError:
            return j(handler, {"error": "no such node"}, status=404)
        except ValueError as exc:
            return bad(handler, str(exc))
        return j(handler, {"ok": True, "entity": entity})
    if path == "/api/jarvis-memory/entity/unlink":
        store, _ns = _store_ns()
        mid, eid = str(body.get("memory_id") or ""), str(body.get("entity_id") or "")
        if not mid or not eid:
            return bad(handler, "memory_id and entity_id are required")
        graph.unlink(store, mid, eid)
        return j(handler, {"ok": True})
    return None
