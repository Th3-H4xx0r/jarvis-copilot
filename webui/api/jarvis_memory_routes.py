"""Jarvis memory over HTTP: stats, status, logs, search, reflections, the memory map's settings, graph and entities, and the cleanup pass."""
from pathlib import Path
from urllib.parse import parse_qs
from api.helpers import bad
from api.helpers import j
from api.helpers import require
from api.profiles import get_active_hermes_home


def _jarvis_mem_store():
    """Open the jarvis_memory store for the active profile (read/serve for the UI)."""
    from plugins.memory.jarvis_memory.config import load_config
    from plugins.memory.jarvis_memory.store import MemoryStore
    cfg = load_config(str(get_active_hermes_home()))
    return MemoryStore(cfg["db_path"], cfg["vault_dir"])


def _handle_jarvis_memory_stats(handler):
    try:
        store = _jarvis_mem_store()
    except Exception as e:
        return j(handler, {"available": False, "error": str(e), "count": 0, "namespaces": []})
    try:
        ns = store.namespaces()
        return j(handler, {"available": True, "count": sum(c for _, c in ns),
                           "namespaces": [{"namespace": n, "count": c} for n, c in ns]})
    finally:
        store.close()


def _handle_jarvis_memory_status(handler):
    try:
        from plugins.memory.jarvis_memory.status import memory_status
        return j(handler, memory_status(str(get_active_hermes_home())))
    except Exception as e:
        return j(handler, {"available": False, "error": str(e)})


def _handle_jarvis_memory_logs(handler):
    try:
        from plugins.memory.jarvis_memory.mem_log import get_logs, install_handler
        install_handler()
        return j(handler, {"logs": get_logs(200)})
    except Exception as e:
        return j(handler, {"logs": [], "error": str(e)})


def _handle_jarvis_memory_search(handler, parsed):
    from urllib.parse import parse_qs
    q = parse_qs(parsed.query or "")
    query = (q.get("q", [""])[0] or "").strip()
    ns = (q.get("ns", [""])[0] or "").strip()
    try:
        limit = max(1, min(200, int(q.get("limit", ["50"])[0])))
    except ValueError:
        limit = 50
    try:
        store = _jarvis_mem_store()
    except Exception as e:
        return j(handler, {"available": False, "error": str(e), "entries": []})
    try:
        if not ns:
            nslist = store.namespaces()
            ns = nslist[0][0] if nslist else "global"
        if query:
            ids = [cid for cid, _ in store.keyword_search(ns, query, limit)]
            chunks = store.get_chunks(ids)
        else:
            chunks = store.recent_chunks(ns, limit)
        entries = [{"id": c.id, "body": c.body, "source": c.source,
                    "created_at": c.created_at, "score": c.score,
                    "namespace": c.namespace, "tags": c.tags} for c in chunks]
        return j(handler, {"available": True, "namespace": ns, "entries": entries})
    finally:
        store.close()


def _jarvis_reflect_store():
    from pathlib import Path
    from plugins.memory.jarvis_memory.proactive import ReflectionStore
    return ReflectionStore(str(Path(get_active_hermes_home()) / "memory" / "reflections.db"))


def _handle_jarvis_memory_reflections(handler):
    try:
        st = _jarvis_reflect_store()
    except Exception as e:
        return j(handler, {"available": False, "error": str(e), "reflections": []})
    try:
        return j(handler, {"available": True, "reflections": st.list(status="new", limit=50)})
    finally:
        st.close()


def _handle_jarvis_memory_reflection_dismiss(handler, body):
    try:
        require(body, "id")
    except ValueError as e:
        return bad(handler, str(e))
    try:
        st = _jarvis_reflect_store()
    except Exception as e:
        return bad(handler, str(e))
    try:
        return j(handler, {"ok": st.dismiss(body["id"])})
    finally:
        st.close()


def _handle_jarvis_memory_reflection_run(handler):
    try:
        import time as _t
        from plugins.memory.jarvis_memory.proactive import run_tick
        cards = run_tick(str(get_active_hermes_home()), _t.time())
        return j(handler, {"ok": True, "new": cards})
    except Exception as e:
        return j(handler, {"ok": False, "error": str(e), "new": []})


def _handle_jarvis_memory_delete(handler, body):
    try:
        require(body, "id")
    except ValueError as e:
        return bad(handler, str(e))
    try:
        store = _jarvis_mem_store()
    except Exception as e:
        return bad(handler, str(e))
    try:
        return j(handler, {"ok": store.delete_chunk(body["id"])})
    finally:
        store.close()


def route(req):
    """Mounted at /api/jarvis-memory (api/mounts.py)."""
    handler, parsed = req.handler, req.parsed
    if req.method == "GET":
        # ── Long-term memory (jarvis_memory) API (GET) ──
        if parsed.path == "/api/jarvis-memory/stats":
            return _handle_jarvis_memory_stats(handler)
        if parsed.path == "/api/jarvis-memory/status":
            return _handle_jarvis_memory_status(handler)
        if parsed.path == "/api/jarvis-memory/logs":
            return _handle_jarvis_memory_logs(handler)
        if parsed.path == "/api/jarvis-memory/search":
            return _handle_jarvis_memory_search(handler, parsed)
        if parsed.path == "/api/jarvis-memory/reflections":
            return _handle_jarvis_memory_reflections(handler)
        if parsed.path == "/api/jarvis-memory/map-settings":
            from api.memory_map import handle_settings_get
            return handle_settings_get(handler)
        if parsed.path in ("/api/jarvis-memory/graph", "/api/jarvis-memory/graph/highlight",
                           "/api/jarvis-memory/entity", "/api/jarvis-memory/recalls",
                           "/api/jarvis-memory/recall"):
            from api.memory_graph import handle_get as _graph_get
            return _graph_get(handler, parsed)
        if parsed.path == "/api/jarvis-memory/cleanup/status":
            from api.memory_map import handle_cleanup_status
            return handle_cleanup_status(handler)
    elif req.method == "POST":
        body = req.body
        if parsed.path == "/api/jarvis-memory/delete":
            return _handle_jarvis_memory_delete(handler, body)
        if parsed.path == "/api/jarvis-memory/reflections/dismiss":
            return _handle_jarvis_memory_reflection_dismiss(handler, body)
        if parsed.path == "/api/jarvis-memory/reflections/run":
            return _handle_jarvis_memory_reflection_run(handler)
        if parsed.path == "/api/jarvis-memory/map-settings":
            from api.memory_map import handle_settings_post
            return handle_settings_post(handler, body)
        if parsed.path in ("/api/jarvis-memory/entity", "/api/jarvis-memory/entity/merge",
                           "/api/jarvis-memory/entity/unlink"):
            from api.memory_graph import handle_post as _graph_post
            return _graph_post(handler, parsed, body)
        if parsed.path == "/api/jarvis-memory/cleanup/start":
            from api.memory_map import handle_cleanup_start
            return handle_cleanup_start(handler)
        if parsed.path == "/api/jarvis-memory/cleanup/stop":
            from api.memory_map import handle_cleanup_stop
            return handle_cleanup_stop(handler)
        if parsed.path == "/api/jarvis-memory/cleanup/restore":
            from api.memory_map import handle_cleanup_restore
            return handle_cleanup_restore(handler, body)
    return False
