"""Keep recently used Claude chats' prompt cache warm.

Anthropic keeps a cached prompt for at most an hour (chats use the 1-hour
tier). A long chat picked up after a longer pause re-writes its whole history
(e.g. 90k tokens on Sonnet ≈ $0.36). Reading a cache entry restarts its hour,
so for chats used in the last WARM_FOR_S we re-send the chat's last request
with ``max_tokens: 0`` every INTERVAL_S: the API only reads the cache (no
output), ≈ 0.05-0.1x the input price, and the next real turn finds it warm.
Pranav's pick 2026-11-24: 6 hours.
"""
from __future__ import annotations

import logging
import threading
import time
from typing import Any, Dict, Optional

logger = logging.getLogger(__name__)

WARM_FOR_S = 6 * 3600      # keep a chat warm this long after its last real call
INTERVAL_S = 55 * 60       # re-read just inside the 1-hour cache lifetime
MAX_SESSIONS = 12          # bound memory: each entry holds one request body
_TICK_S = 60

_lock = threading.Lock()
_entries: Dict[str, Dict[str, Any]] = {}
_thread: Optional[threading.Thread] = None


def should_keep_warm(agent) -> bool:
    """Real chats on the native Anthropic API with 1-hour cache markers."""
    try:
        if getattr(agent, "api_mode", None) != "anthropic_messages":
            return False
        if not getattr(agent, "session_id", None) or not getattr(agent, "_session_db", None):
            return False
        if (getattr(agent, "platform", "") or "") == "cron":
            return False
        from agent.prompt_caching import marker_retention
        return marker_retention(agent) == "long"
    except Exception:
        return False


def _warmable(kwargs: Dict[str, Any]) -> bool:
    thinking = kwargs.get("thinking") or {}
    if isinstance(thinking, dict) and thinking.get("type") == "enabled":
        return False  # max_tokens 0 is rejected with a thinking budget
    out = kwargs.get("output_config") or {}
    if isinstance(out, dict) and out.get("format"):
        return False  # nor with structured outputs
    return True


def remember(agent, api_kwargs: Dict[str, Any], client=None) -> None:
    """Note this chat's latest request (called right before it is sent)."""
    if not should_keep_warm(agent) or not isinstance(api_kwargs, dict):
        return
    client = client or getattr(agent, "_anthropic_client", None)
    if client is None or not _warmable(api_kwargs):
        return
    kw = {k: v for k, v in api_kwargs.items() if k != "stream"}
    now = time.time()
    with _lock:
        _entries[agent.session_id] = {"client": client, "kwargs": kw, "last_used": now,
                                      "last_warm": now, "model": kw.get("model")}
        while len(_entries) > MAX_SESSIONS:
            oldest = min(_entries, key=lambda s: _entries[s]["last_used"])
            _entries.pop(oldest, None)
    _ensure_thread()


def _warm(session_id: str, entry: Dict[str, Any]) -> None:
    try:
        resp = entry["client"].messages.create(**{**entry["kwargs"], "max_tokens": 0})
        usage = getattr(resp, "usage", None)
        if usage is not None:
            from agent import usage_log
            from agent.usage_pricing import normalize_usage
            usage_log.record("keepwarm", model=str(entry.get("model") or ""), provider="anthropic-api",
                             usage=normalize_usage(usage, provider="anthropic-api", api_mode="anthropic_messages"))
        logger.info("keepwarm: %s refreshed (read %s)", session_id,
                    getattr(usage, "cache_read_input_tokens", "?") if usage is not None else "?")
    except Exception as exc:
        logger.info("keepwarm: %s refresh failed: %s", session_id, str(exc)[:160])


def tick(now: Optional[float] = None) -> int:
    """One pass: drop chats idle past WARM_FOR_S, refresh those due. Returns refreshes sent."""
    now = time.time() if now is None else now
    due = []
    with _lock:
        for sid, e in list(_entries.items()):
            if now - e["last_used"] > WARM_FOR_S:
                _entries.pop(sid, None)
            elif now - e["last_warm"] >= INTERVAL_S:
                e["last_warm"] = now
                due.append((sid, e))
    for sid, e in due:
        _warm(sid, e)
    return len(due)


def _loop() -> None:
    while True:
        time.sleep(_TICK_S)
        try:
            tick()
        except Exception:
            logger.debug("keepwarm tick failed", exc_info=True)


def _ensure_thread() -> None:
    global _thread
    with _lock:
        if _thread is None or not _thread.is_alive():
            _thread = threading.Thread(target=_loop, daemon=True, name="jc-cache-keepwarm")
            _thread.start()
