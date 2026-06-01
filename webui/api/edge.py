"""WebUI API for the edge-exposure (Cloudflare tunnel + nginx) subsystem.

Routes are dispatched from ``routes.py`` under ``/api/edge/*`` and therefore
inherit the WebUI's standard auth gate (enforced in ``server.py`` before
dispatch) and, for POST, the CSRF check. Never returns the raw tunnel token —
``state.public_settings`` masks it.
"""
from __future__ import annotations

import logging
from typing import Any, Dict

from api.helpers import j

logger = logging.getLogger(__name__)


def _mgr():
    # `webui/` is on sys.path (the server imports `from api.config import ...`),
    # so the edge package is top-level `edge`, not `webui.edge`.
    from edge import get_manager  # lazy so importing this module stays cheap
    return get_manager()


def handle_edge_get(handler, parsed) -> bool:
    """GET /api/edge/* — returns True if handled."""
    path = parsed.path
    try:
        if path == "/api/edge/status":
            return j(handler, _mgr().status())
        if path == "/api/edge/diagnose":
            return j(handler, _mgr().diagnose())
        if path == "/api/edge/logs":
            from urllib.parse import parse_qs
            qs = parse_qs(parsed.query or "")
            name = (qs.get("name", ["cloudflared"])[0]).strip()
            lines = int((qs.get("lines", ["100"])[0]))
            return j(handler, _mgr().logs(name, min(max(lines, 1), 1000)))
    except Exception as exc:  # surface a clean error, never a traceback
        logger.exception("edge GET %s failed", path)
        return j(handler, {"ok": False, "error": str(exc)}, status=500)
    return False


def handle_edge_post(handler, parsed, body: Dict[str, Any]) -> bool:
    """POST /api/edge/* — returns True if handled."""
    path = parsed.path
    body = body or {}
    try:
        if path == "/api/edge/configure":
            return j(handler, _mgr().configure(body))
        if path == "/api/edge/install":
            tool = (body.get("tool") or "").strip()
            if tool not in ("cloudflared", "nginx"):
                return j(handler, {"ok": False, "error": "tool must be 'cloudflared' or 'nginx'"}, status=400)
            return j(handler, _mgr().install(tool))
        if path == "/api/edge/enable":
            return j(handler, _mgr().enable())
        if path == "/api/edge/disable":
            return j(handler, _mgr().disable())
        if path == "/api/edge/service/start":
            return j(handler, _mgr().start_service((body.get("name") or "").strip()))
        if path == "/api/edge/service/stop":
            return j(handler, _mgr().stop_service((body.get("name") or "").strip()))
    except Exception as exc:
        logger.exception("edge POST %s failed", path)
        return j(handler, {"ok": False, "error": str(exc)}, status=500)
    return False
