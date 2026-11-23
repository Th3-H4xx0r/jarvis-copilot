"""Face ID approvals for the PC power button's force actions: ``/api/pc-power`` (spec 2026-11-23).

Force restart (the reset button) and Force off (power held 6 s) can lose unsaved work, so each needs
his Face ID. A frozen PC can't check a signature, so the server checks it here with the approver
key the car uses (plugins/toyota/approver.py), in its own domain so no other approval can be
replayed as one of these. Jarvis (host-signed) may ask; only his phone may answer.

    POST /force {device_id, action, source?}         → {ok, approval}   (card, web, Jarvis)
    GET  /approvals                                   → {approvals}      (the phone's Face ID card)
    POST /approvals/<id>/approve {ts, signature}      → runs it          (phone only)
    POST /approvals/<id>/deny
"""
from __future__ import annotations

import logging
import threading
from typing import Callable

log = logging.getLogger(__name__)

DOMAIN = "jarvis-pc-power"
COMMANDS = {"force_restart": "Force restart PC", "force_off": "Force off PC"}


class PcPowerApprovals:
    def __init__(self, *, power: Callable, verify: Callable, notify: Callable = lambda title, data: None,
                 clock: Callable | None = None) -> None:
        from plugins.toyota.approver import Approvals
        self._power = power
        self._verify = verify
        self._notify = notify
        kw = {"clock": clock} if clock else {}
        self._approvals = Approvals(titles=COMMANDS, label="PC power", **kw)
        self._device: dict = {}
        self._lock = threading.Lock()

    def request(self, pc: str, action: str, source: str = "Pranav") -> dict:
        if action not in COMMANDS:
            return {"ok": False, "error": "Unknown power action."}
        if not self._power().button_board(pc):
            return {"ok": False, "error": "No power button is linked to this PC."}
        try:
            item = self._approvals.create(action, source)
        except Exception as exc:  # noqa: BLE001 — ApprovalError (rate limit)
            return {"ok": False, "error": str(exc)}
        with self._lock:
            self._device[item["id"]] = pc
        self._notify(item["title"], {"approval_id": item["id"], "command": action})
        return {"ok": True, "approval": item}

    def pending(self) -> list:
        return self._approvals.pending()

    def approve(self, approval_id: str, ts, signature) -> dict:
        try:
            item = self._approvals.peek(approval_id)
            self._verify(item["command"], item["id"], ts, signature)
            self._approvals.take(approval_id)
        except Exception as exc:  # noqa: BLE001 — gone, bad signature, replay
            return {"ok": False, "error": str(exc) or "That approval didn't check out."}
        with self._lock:
            pc = self._device.pop(item["id"], "")
        if not pc:
            return {"ok": False, "error": "That approval lost its PC. Ask again."}
        out = self._power().force(pc, item["command"]) or {}
        return {"ok": bool(out.get("ok")), **out}

    def deny(self, approval_id: str) -> dict:
        try:
            item = self._approvals.take(approval_id)
        except Exception as exc:  # noqa: BLE001
            return {"ok": False, "error": str(exc)}
        with self._lock:
            self._device.pop(item["id"], None)
        return {"ok": True}


_STORE: PcPowerApprovals | None = None
_STORE_LOCK = threading.Lock()


def _verify(command: str, nonce: str, ts, signature) -> None:
    from plugins.toyota import approver as approval
    approval.approver().verify(command, nonce, ts, signature, domain=DOMAIN)


def _notify_phone(title: str, data: dict) -> None:
    """A push so the phone shows the Face ID card for a request made on the web or by Jarvis."""
    def send():
        try:
            from api.coding_routes import _push_device_alert
            _push_device_alert(title, "Approve it with Face ID.", data={"type": "pc_power_approval", **data})
        except Exception as exc:  # noqa: BLE001
            log.warning("PC power push failed: %s", type(exc).__name__)
        try:   # the phone's Face ID card right away when its app is connected (PcPowerApprovals.swift)
            from api import device_bridge
            device = device_bridge.device_offering("pc_power_show_approvals")
            if device and device in device_bridge.connected_device_ids():
                device_bridge.invoke_skill(device, "pc_power_show_approvals", {}, timeout=8.0)
        except Exception as exc:  # noqa: BLE001
            log.debug("PC power card nudge failed: %s", type(exc).__name__)
    threading.Thread(target=send, name="pc-power-notify", daemon=True).start()


def store() -> PcPowerApprovals:
    global _STORE
    with _STORE_LOCK:
        if _STORE is None:
            from api import mac_power
            _STORE = PcPowerApprovals(power=mac_power.store, verify=_verify, notify=_notify_phone)
        return _STORE


def create_force_request(pc: str, action: str, source: str = "Jarvis") -> dict:
    """For the computer_power tool: ask his phone, never act."""
    return store().request(pc, action, source)


def route(req) -> bool:
    """Mounted at /api/pc-power (api/mounts.py)."""
    parts = [p for p in req.sub.strip("/").split("/") if p]
    body = req.body if isinstance(req.body, dict) else {}
    if parts == ["force"] and req.method == "POST":
        pc = str(body.get("device_id") or "").strip()
        if not pc:
            return req.reply(400, {"ok": False, "error": "device_id is required"})
        source = "Jarvis" if req.host_signed else str(body.get("source") or "Pranav")[:40]
        out = store().request(pc, str(body.get("action") or ""), source)
        return req.reply(200 if out.get("ok") else 409, out)
    if parts == ["approvals"] and req.method == "GET":
        return req.reply(200, {"approvals": store().pending()})
    if len(parts) == 3 and parts[0] == "approvals" and parts[2] in ("approve", "deny") and req.method == "POST":
        if req.host_signed:
            return req.reply(403, {"ok": False, "error": "Force actions are answered with Face ID on the iPhone."})
        if parts[2] == "deny":
            out = store().deny(parts[1])
        elif not (body.get("ts") and body.get("signature")):
            return req.reply(400, {"ok": False, "error": "an approval needs the Face ID signature"})
        else:
            out = store().approve(parts[1], body.get("ts"), body.get("signature"))
        return req.reply(200 if out.get("ok") else 409, out)
    return req.reply(404, {"error": "not found"})
