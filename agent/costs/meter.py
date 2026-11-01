"""The local meter: services with no billing API are priced from what Jarvis itself sent.

``record("parallel", "search", 1, mode="fast")`` is called on the hot path of a web search,
a speech stream or a TTS request, so it must never raise and never slow the caller down
noticeably — one SQLite INSERT inside a blanket ``try``. A lost event costs a fraction of a
cent of accuracy; a raised one would break the search.
"""
from __future__ import annotations

import logging
from typing import Any

logger = logging.getLogger(__name__)


def record(service: str, kind: str, units: float, **meta: Any) -> None:
    try:
        if not units or units < 0:
            return
        from agent.costs.store import get_store
        get_store().record_event(service, kind, float(units),
                                 {k: v for k, v in meta.items() if v is not None} or None)
    except Exception:
        logger.debug("cost meter: dropped %s/%s event", service, kind, exc_info=True)
