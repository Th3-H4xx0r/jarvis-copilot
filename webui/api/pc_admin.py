"""PC admin actions: the server's part (contract C6, Pranav's call: phone Face ID + UAC).

The Windows app asks jc-client to run something as admin; jc-client sends the event
``pc_admin_request`` {request_id, command, why}. We alert his iPhone, list it in Agents,
and wait. His Allow carries a Face ID signature over ``jarvis-pc|run-as-admin|<request_id>|<ts>``,
checked here by the same approver key as the car (plugins/toyota/approver.py). Only then
does the PC get ``pc_admin_decision`` approved=true; Windows still shows its UAC prompt.
In memory only; a request lives REQUEST_TTL (the PC stops waiting at the same time).
"""
from __future__ import annotations

import logging
import threading
import time
from typing import Callable, Optional

log = logging.getLogger(__name__)

REQUEST_TTL = 120.0
SIGNED_COMMAND = "run-as-admin"
DOMAIN = "jarvis-pc"


class PcAdminStore:
    def __init__(self, *, send_frame: Callable[[str, dict], bool],
                 alert: Callable[[str, str, dict], None],
                 verify: Callable[[str, str, object, object], None],
                 clock: Callable[[], float] = time.time,
                 name_of: Callable[[str], str] = lambda did: "PC",
                 changed: Callable[[], None] = lambda: None) -> None:
        self._send = send_frame
        self._alert = alert
        self._verify = verify
        self._clock = clock
        self._name_of = name_of
        self._changed = changed
        self._lock = threading.Lock()
        self._requests: dict[str, dict] = {}

    def _sweep(self, now: float) -> None:
        self._requests = {k: r for k, r in self._requests.items() if r["expires"] >= now}

    def on_request(self, device_id: str, data: dict) -> None:
        rid = str((data or {}).get("request_id") or "")
        command = str((data or {}).get("command") or "").strip()
        if not rid or len(rid) > 64 or not command:
            return
        now = self._clock()
        name = self._name_of(device_id) or "PC"
        req = {"id": rid, "device_id": device_id, "device_name": name, "command": command[:2000],
               "why": str(data.get("why") or "")[:500], "created": now, "expires": now + REQUEST_TTL}
        with self._lock:
            self._sweep(now)
            self._requests[rid] = req
        self._changed()
        try:
            self._alert(f"Run as admin on {name}", req["why"] or req["command"][:120],
                        {"kind": "pc_admin", "id": rid, "device_id": device_id})
        except Exception:  # noqa: BLE001
            log.warning("PC admin push failed", exc_info=True)

    def pending(self) -> list[dict]:
        now = self._clock()
        with self._lock:
            self._sweep(now)
            return [dict(r) for r in self._requests.values()]

    def answer(self, rid: str, decision: str, ts, signature) -> dict:
        if decision not in ("allow", "deny"):
            return {"ok": False, "error": "decision must be allow or deny"}
        now = self._clock()
        with self._lock:
            self._sweep(now)
            req = self._requests.get(str(rid or ""))
        if req is None:
            return {"ok": False, "error": "expired"}
        approved = decision == "allow"
        if approved:
            try:
                self._verify(SIGNED_COMMAND, req["id"], ts, signature)
            except Exception as exc:  # noqa: BLE001 — ApprovalError and friends
                return {"ok": False, "error": str(exc)}
        frame = {"type": "pc_admin_decision", "request_id": req["id"], "approved": approved}
        if not self._send(req["device_id"], frame):
            return {"ok": False, "error": "The PC isn't connected."}
        with self._lock:
            self._requests.pop(req["id"], None)
        self._changed()
        return {"ok": True}


_STORE: Optional[PcAdminStore] = None
_STORE_LOCK = threading.Lock()


def _verify(command: str, nonce: str, ts, signature) -> None:
    from plugins.toyota import approver as approval
    approval.approver().verify(command, nonce, ts, signature, domain=DOMAIN)


def store() -> PcAdminStore:
    global _STORE
    with _STORE_LOCK:
        if _STORE is None:
            from api import device_bridge
            from api import mac_power
            _STORE = PcAdminStore(send_frame=device_bridge.send_frame, alert=mac_power._alert_phones,
                                  verify=_verify, name_of=device_bridge.device_name,
                                  changed=mac_power._changed)
        return _STORE
