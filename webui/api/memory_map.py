"""Memory map wiring for the web server.

- The memory model setting (one choice for every memory model call; default
  Haiku 5.5 on his Anthropic API key) and the completer that follows it.
- Registering the brief's live sources (calendar, health, inbox, home…).
- HTTP handlers for the setting, the phone's context snapshot and cleanup.
"""
from __future__ import annotations

import logging
from typing import Optional, Tuple

logger = logging.getLogger(__name__)


def _store():
    from plugins.memory.jarvis_memory import external
    return external._open()[0]


def get_agent():
    """His choice: ``{"model", "provider"}``, ``{"harness_id"}`` or None (Same as Default)."""
    from plugins.memory.jarvis_memory import llm
    return llm.get_agent(_store())


def set_agent(agent) -> bool:
    from plugins.memory.jarvis_memory import llm
    return llm.set_agent(_store(), agent)


def resolve_map_model() -> Tuple[str, str]:
    from api.imessage_memory_writer import resolve_extraction_model
    return resolve_extraction_model(get_agent())


def complete(prompt: str, max_tokens: int = 1500) -> str:
    import api.imessage_memory_writer as writer
    ref, _label = resolve_map_model()
    if not ref:
        raise RuntimeError("no memory model set")
    return writer._one_shot(ref, prompt, max_tokens, thinking=False)


def _register_brief_sources() -> None:
    try:
        from api import brief_sources
        brief_sources.register_all()
    except Exception:
        logger.warning("memory map: brief sources not registered", exc_info=True)


def install() -> None:
    """Called once at web server start."""
    from plugins.memory.jarvis_memory import llm
    llm.set_completer(complete)
    _register_brief_sources()


# ── HTTP ─────────────────────────────────────────────────────────────────
def settings_payload() -> dict:
    agent = get_agent()
    try:
        _ref, label = resolve_map_model()
    except Exception:
        label = ""
    return {"agent": agent, "label": label}


def handle_settings_get(handler):
    from api.helpers import j
    return j(handler, settings_payload())


def handle_settings_post(handler, body: Optional[dict]):
    from api.helpers import bad, j
    body = body if isinstance(body, dict) else {}
    if "agent" not in body or not set_agent(body.get("agent")):
        return bad(handler, "agent must be null, {harness_id} or {model, provider}")
    return j(handler, settings_payload())


def handle_context_post(handler, body: Optional[dict]):
    """The phone's calendar (next 14 days), open reminders and time zone."""
    from api.auth import parse_cookie
    from api.helpers import j
    from api.pairing import find_device_by_session
    device = find_device_by_session(parse_cookie(handler) or "")
    if not device:
        return j(handler, {"error": "no matching device for session"}, status=401)
    from api.brief_sources import save_snapshot
    return j(handler, {"ok": True, **save_snapshot(body if isinstance(body, dict) else {})})


# ── cleanup / backfill ───────────────────────────────────────────────────
import threading as _threading

_cleanup = {"thread": None, "error": "", "progress": None}
_cleanup_lock = _threading.Lock()


def _run_cleanup():
    from plugins.memory.jarvis_memory import cleanup, external, tz
    store, embedder, _ns, _th = external._open()
    try:
        cleanup.run(store, embedder, zone=tz.user_zone(),
                    progress=lambda state: _cleanup.update(progress=state))
        _cleanup["error"] = ""
    except Exception as exc:
        logger.warning("memory cleanup failed", exc_info=True)
        _cleanup["error"] = str(exc)[:300]


def handle_cleanup_start(handler):
    from api.helpers import j
    with _cleanup_lock:
        thread = _cleanup["thread"]
        from plugins.memory.jarvis_memory import cleanup as _cl
        if (thread is not None and thread.is_alive()) or _cl.progress(_store()) is not None:
            return j(handler, {"ok": True, "started": False})  # one run at a time, any process
        _cleanup.update(progress={"step": "starting", "done": 0, "total": 0}, error="")
        thread = _threading.Thread(target=_run_cleanup, daemon=True, name="memory-cleanup")
        _cleanup["thread"] = thread
        thread.start()
    return j(handler, {"ok": True, "started": True})


def handle_cleanup_status(handler):
    """Running = a cleanup in this server or any other process (the shell
    backfill) noted progress in the last few minutes."""
    from api.helpers import j
    from plugins.memory.jarvis_memory import cleanup
    store = _store()
    thread = _cleanup["thread"]
    here = bool(thread is not None and thread.is_alive())
    shared = cleanup.progress(store)
    running = here or shared is not None
    state = shared or (_cleanup["progress"] if here else None)
    return j(handler, {"running": running, "progress": state if running else None,
                       "stopping": running and store.kv_get("__cleanup__", "stop") == "1",
                       "error": _cleanup["error"], "report": cleanup.load_report(store)})


def handle_cleanup_stop(handler):
    from api.helpers import j
    from plugins.memory.jarvis_memory import cleanup
    cleanup.request_stop(_store())
    return j(handler, {"ok": True})


def handle_cleanup_restore(handler, body: Optional[dict]):
    from api.helpers import j
    from plugins.memory.jarvis_memory import cleanup
    ids = [i for i in (body or {}).get("ids") or [] if isinstance(i, str)]
    return j(handler, {"ok": True, "restored": cleanup.restore_hidden(_store(), ids)})
