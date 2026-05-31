"""In-memory ring buffer of memory-related log lines for the webui panel.

Captures two streams without polluting the gateway log:
  - "jarvis_memory.events" — user-facing memory activity (captures, mirrors,
    reflections, migrations) logged via log_event(); propagate=False so it only
    goes to this ring, never the file.
  - WARNING+ from the plugins.memory.jarvis_memory package (errors), additionally
    ring-buffered (they still go to the file as usual).

The provider (agent process == webui process in the gateway) installs the handler
and emits events; the webui /api/jarvis-memory/logs handler reads the ring.
"""
from __future__ import annotations

import logging
import threading
from collections import deque
from typing import List

EVENTS_LOGGER = "jarvis_memory.events"
_PKG_LOGGER = "plugins.memory.jarvis_memory"

_BUF: "deque[dict]" = deque(maxlen=500)
_LOCK = threading.Lock()
_INSTALLED = False

_events = logging.getLogger(EVENTS_LOGGER)


class _RingHandler(logging.Handler):
    def emit(self, record: logging.LogRecord) -> None:
        try:
            msg = record.getMessage()
        except Exception:
            return
        with _LOCK:
            _BUF.append({
                "ts": record.created,
                "level": record.levelname,
                "logger": record.name,
                "msg": msg,
            })


def install_handler() -> None:
    """Idempotently attach the ring handler. Safe to call repeatedly."""
    global _INSTALLED
    if _INSTALLED:
        return
    h = _RingHandler()
    h.setLevel(logging.DEBUG)
    ev = logging.getLogger(EVENTS_LOGGER)
    ev.setLevel(logging.INFO)
    ev.propagate = False          # ring only — never the gateway file/console
    ev.addHandler(h)
    # Also ring-buffer the package's own WARNING+ records (errors) — these still
    # propagate to the file; we don't change the package logger's level.
    logging.getLogger(_PKG_LOGGER).addHandler(h)
    _INSTALLED = True


def log_event(msg: str, *args) -> None:
    """Record a user-facing memory event (shown live in the panel)."""
    try:
        _events.info(msg, *args)
    except Exception:
        pass


def get_logs(limit: int = 200) -> List[dict]:
    with _LOCK:
        items = list(_BUF)
    return items[-limit:]
