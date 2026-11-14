"""Power integrations over HTTP: /api/power, and the gate in front of every route."""
from __future__ import annotations

import logging

logger = logging.getLogger(__name__)


def power_gate(handler, parsed) -> bool:
    """Answer 409 when the path belongs to a switched-off Power integration."""
    try:
        from jarvis_power.gate import route_block
        blocked = route_block(parsed.path)
    except Exception:
        logger.debug("power gate unavailable", exc_info=True)
        return False
    if blocked is None:
        return False
    from api.helpers import j
    j(handler, blocked, status=409)
    return True


# ── /api/power ───────────────────────────────────────────────────────────────
CARD_STATE_TIMEOUT = 3.0


def _notify_phone(item: dict) -> None:
    """A push with fixed text (never what Jarvis asked for) and the phone's approval card if
    the app is connected. Best effort, off the request thread."""
    import threading

    def send():
        try:
            from api.coding_routes import _push_device_alert
            _push_device_alert("Jarvis wants to change a Power integration",
                               "Approve it with Face ID.", data={"type": "power_approval"})
        except Exception as exc:
            logger.warning("power approval push failed: %s", type(exc).__name__)
        try:
            from api import device_bridge
            device = device_bridge.device_offering("power_show_approvals")
            if device and device in device_bridge.connected_device_ids():
                device_bridge.invoke_skill(device, "power_show_approvals", {}, timeout=8.0)
        except Exception as exc:
            logger.debug("power approval card nudge failed: %s", type(exc).__name__)

    threading.Thread(target=send, name="power-approval-notify", daemon=True).start()


def _install_notifier() -> None:
    from jarvis_power import approvals
    approvals.notifier = _notify_phone


_install_notifier()


def _is_board(req) -> bool:
    """A paired ESP32 or the Pod (the door alarm's rule): read only."""
    try:
        from api.door_routes import door_caller
        return door_caller(req.handler) == "board"
    except Exception:
        return False


def _audit(req, integration_id: str, body: dict, by: str) -> None:
    """Every switch and settings change lands in the Security Advisor's event log."""
    try:
        from security.events import emit
        from security.netid import actor_for
        emit("device", "power.change", actor_for(req.handler), integration=integration_id,
             enabled=body.get("enabled"), settings=sorted((body.get("settings") or {}).keys()), by=by)
    except Exception:
        logger.debug("power audit event failed", exc_info=True)


def route(req) -> bool:
    """Mounted at /api/power (api/mounts.py)."""
    from jarvis_power import api, approvals, switch
    from jarvis_power.base import PowerError
    from plugins.toyota.approver import ApprovalError

    sub = req.sub.strip("/")
    parts = sub.split("/") if sub else []
    body = req.body if isinstance(req.body, dict) else {}
    try:
        if not parts:
            if req.method != "GET":
                return req.reply(405, {"error": "method not allowed"})
            return req.reply(200, api.rows())
        if parts == ["cards"] and req.method == "GET":
            return req.reply(200, {"cards": api.cards(CARD_STATE_TIMEOUT)})
        if parts[0] == "approvals":
            if len(parts) == 1 and req.method == "GET":
                return req.reply(200, {"approvals": approvals.pending()})
            if len(parts) == 3 and req.method == "POST" and parts[2] in ("approve", "deny"):
                if req.host_signed:
                    return req.reply(403, {"ok": False,
                                           "error": "Power approvals are answered with Face ID."})
                if parts[2] == "approve":
                    return req.reply(200, approvals.approve(parts[1], body))
                return req.reply(200, approvals.deny(parts[1]))
            return req.reply(404, {"error": "not found"})

        integration_id = parts[0]
        if req.method == "POST" and not req.host_signed and _is_board(req):
            return req.reply(403, {"ok": False, "error": "Devices can read Power integrations, not change them."})
        if len(parts) == 1 and req.method == "POST":
            by = "jarvis" if req.host_signed else (str(body.get("client") or "app"))
            _audit(req, integration_id, body, by)
            if by == "jarvis" and not req.host_signed:
                by = "app"                     # only the loopback is Jarvis
            result = None
            if "settings" in body:
                result = switch.request_settings(integration_id, body.get("settings"), by)
                if not result.get("ok"):
                    return req.reply(200, result)
            if "enabled" in body:
                result = switch.request_enabled(integration_id, bool(body["enabled"]), by)
            if result is None:
                return req.reply(400, {"ok": False, "error": "give enabled and/or settings"})
            return req.reply(200, result)
        if parts[1:] == ["ui"] and req.method == "GET":
            return req.reply(200, api.ui(integration_id))
        if parts[1:] == ["ui", "action"] and req.method == "POST":
            action = str(body.get("action") or "").strip()
            if not action:
                return req.reply(400, {"ok": False, "state": {}, "toast": None,
                                       "error": "action is required", "version": None})
            return req.reply(200, api.run_action(integration_id, action, body))
        return req.reply(404, {"error": "not found"})
    except PowerError as exc:
        status = 404 if "no Power integration" in str(exc) else 400
        return req.reply(status, {"ok": False, "error": str(exc)})
    except ApprovalError as exc:
        return req.reply(409 if exc.code == "gone" else 400,
                         {"ok": False, "error": str(exc), "code": exc.code})
