"""Wake Mac, keep-awake and Mac password requests: the server's part (spec 2026-11-02).

Per Mac (device id): the keep-awake and timer switches, a pending wake request,
the Mac app's APNs token, and the last power status jc-client sent. Stored in
$HERMES_HOME/webui/mac_power.json. Password requests live only in memory and
expire after REQUEST_TTL; they never carry a password, and the server only
relays Pranav's signed answer to the Mac (it can't and doesn't verify it: the
Mac does, so a server compromise can't get the password typed).

    wake(device)      intent + an APNs push to the Mac app (fast path)
    checkin(device)   the Mac's timer check-in: {wake, keep_awake, timer_on}
    keep_awake / timer / let_sleep / unlock   frames to the Mac
    answer(id, ...)   relay his answer to the Mac that asked
"""
from __future__ import annotations

import json
import logging
import os
import threading
import time
from pathlib import Path
from typing import Callable, Iterable, Optional

log = logging.getLogger(__name__)

INTENT_MAX = 1200.0       # a wake request older than this is forgotten
KEEP_AWAKE_MAX = 12 * 3600.0   # "Keep Mac awake" turns itself off after this
REQUEST_TTL = 120.0
MAC_TOPIC = "com.jarviscopilot.mac"
_KIND_TITLE = {"sudo": "sudo needs your Mac password", "admin": "Admin password requested",
               "keychain": "Keychain wants your Mac password", "unlock": "Unlock your Mac"}


def _default_path() -> Path:
    from jarviscopilot_constants import get_hermes_home
    return get_hermes_home() / "webui" / "mac_power.json"


class MacPowerStore:
    def __init__(self, path: Optional[Path] = None, *,
                 send_frame: Callable[[str, dict], bool] = lambda d, f: False,
                 push: Callable[[str, str], dict] = lambda token, env: {"ok": False},
                 alert: Callable[[str, str, dict], None] = lambda title, body, data: None,
                 changed: Callable[[], None] = lambda: None,
                 connected: Callable[[], Iterable[str]] = lambda: (),
                 clock: Callable[[], float] = time.time) -> None:
        self._path = Path(path) if path else _default_path()
        self._send = send_frame
        self._push = push
        self._alert = alert
        self._changed = changed
        self._connected = connected
        self._clock = clock
        self._lock = threading.RLock()
        self._requests: dict = {}
        try:
            self._devices = json.loads(self._path.read_text())
            if not isinstance(self._devices, dict):
                self._devices = {}
        except (OSError, ValueError):
            self._devices = {}

    # ── state ────────────────────────────────────────────────────────────
    def device(self, did: str) -> dict:
        with self._lock:
            d = self._devices.setdefault(did, {})
            d.setdefault("keep_awake", False)
            d.setdefault("timer_on", True)
            d.setdefault("wake_requested_at", None)
            return d

    def _save(self) -> None:
        try:
            self._path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self._path.with_suffix(".tmp")
            tmp.write_text(json.dumps(self._devices))
            os.replace(tmp, self._path)
        except OSError:
            log.warning("mac_power state not saved", exc_info=True)

    def _update(self, did: str, **fields) -> dict:
        with self._lock:
            d = self.device(did)
            d.update(fields)
            self._save()
        self._changed()
        return d

    # ── from the phone / web ─────────────────────────────────────────────
    def wake(self, did: str) -> dict:
        d = self._update(did, wake_requested_at=self._clock())
        push = d.get("push") or {}
        pushed = False
        if push.get("token"):
            try:
                pushed = bool((self._push(push["token"], push.get("env") or "") or {}).get("ok"))
            except Exception:  # noqa: BLE001
                log.warning("Wake Mac push failed", exc_info=True)
        return {"ok": True, "pushed": pushed}

    def _keep(self, d: dict) -> bool:
        """Keep-awake, unless it's been on longer than KEEP_AWAKE_MAX (then it's off)."""
        if d.get("keep_awake") and self._clock() - float(d.get("keep_awake_at") or 0) > KEEP_AWAKE_MAX:
            d["keep_awake"] = False
            self._save()
        return bool(d.get("keep_awake"))

    def sync(self, did: str) -> None:
        """A Mac (re)connected: hand it the switches, which may have changed while
        it was away or since jc-client restarted."""
        with self._lock:
            if did not in self._devices:
                return
            d = self.device(did)
            frame = {"type": "mac_power_set", "keep_awake": self._keep(d), "timer_on": bool(d["timer_on"])}
        self._send(did, frame)

    def keep_awake(self, did: str, on: bool) -> dict:
        self._update(did, keep_awake=bool(on), keep_awake_at=self._clock())
        return {"ok": True, "delivered": self._send(did, {"type": "mac_power_set", "keep_awake": bool(on)})}

    def timer(self, did: str, on: bool) -> dict:
        self._update(did, timer_on=bool(on))
        return {"ok": True, "delivered": self._send(did, {"type": "mac_power_set", "timer_on": bool(on)})}

    def let_sleep(self, did: str) -> dict:
        self._update(did, keep_awake=False, wake_requested_at=None)
        return {"ok": True, "delivered": self._send(did, {"type": "mac_power_set", "let_sleep": True})}

    def unlock(self, did: str) -> dict:
        if did not in set(self._connected()):
            return {"ok": False, "error": "The Mac isn't awake. Wake it first."}
        return {"ok": bool(self._send(did, {"type": "mac_password_unlock"}))}

    def answer(self, rid: str, decision: str, ts, signature) -> dict:
        now = self._clock()
        with self._lock:
            req = self._requests.get(str(rid or ""))
            if req is None or req["expires"] < now:
                return {"ok": False, "error": "That request is gone (answered or expired)."}
            did = req["device_id"]
        frame = {"type": "mac_password_answer", "id": rid, "decision": decision, "ts": ts,
                 "signature": signature}
        if not self._send(did, frame):
            return {"ok": False, "error": "The Mac isn't connected."}
        return {"ok": True}

    # ── from the Mac ─────────────────────────────────────────────────────
    def checkin(self, did: str) -> dict:
        with self._lock:
            d = self.device(did)
            at = d.get("wake_requested_at")
            wake = at is not None and self._clock() - at <= INTENT_MAX
            if at is not None:
                d["wake_requested_at"] = None
                self._save()
            out = {"wake": wake, "keep_awake": self._keep(d), "timer_on": bool(d["timer_on"])}
        if wake:
            self._changed()
        return out

    def on_status(self, did: str, data: dict) -> None:
        keep = ("state", "held", "reason", "keep_awake", "timer_on", "battery", "on_ac", "lid")
        fields = {"status": {k: data.get(k) for k in keep}, "seen_at": self._clock()}
        if data.get("state") == "awake":
            fields["wake_requested_at"] = None
        self._update(did, **fields)

    def on_token(self, did: str, data: dict) -> None:
        token = str(data.get("token") or "").strip()
        if token:
            self._update(did, push={"token": token[:200], "env": str(data.get("env") or "")[:16]})

    def on_set(self, did: str, data: dict) -> None:
        """The Mac menu bar changed a switch (already applied there): just remember it."""
        fields = {}
        if "keep_awake" in data:
            fields["keep_awake"] = bool(data["keep_awake"])
            fields["keep_awake_at"] = self._clock()
        if "timer_on" in data:
            fields["timer_on"] = bool(data["timer_on"])
        if data.get("let_sleep"):
            fields.update(keep_awake=False, wake_requested_at=None)
        if fields:
            self._update(did, **fields)

    def on_password_request(self, did: str, data: dict) -> None:
        rid = str(data.get("id") or "")
        if not rid:
            return
        kind = str(data.get("kind") or "admin")
        req = {"id": rid, "kind": kind, "context": str(data.get("context") or "")[:2400],
               "nonce": str(data.get("nonce") or ""), "created": data.get("created") or self._clock(),
               "expires": float(data.get("expires") or self._clock() + REQUEST_TTL), "device_id": did}
        with self._lock:
            self._requests[rid] = req
        self._changed()
        try:
            self._alert(_KIND_TITLE.get(kind, "Mac password requested"), req["context"] or "Tap to review",
                        {"kind": "mac_password", "id": rid, "device_id": did})
        except Exception:  # noqa: BLE001
            log.warning("Mac password push failed", exc_info=True)

    def on_password_done(self, did: str, data: dict) -> None:
        with self._lock:
            self._requests.pop(str(data.get("id") or ""), None)
        self._changed()

    # ── for the Agents list ──────────────────────────────────────────────
    def list_payload(self, name_of: Callable[[str], str]) -> dict:
        now = self._clock()
        connected = set(self._connected())
        with self._lock:
            self._requests = {k: r for k, r in self._requests.items() if r["expires"] >= now}
            requests = [dict(r) for r in self._requests.values()]
            macs = []
            for did, d in self._devices.items():
                status = d.get("status") or {}
                if not status and not (d.get("push") or {}).get("token"):
                    continue
                awake = did in connected
                macs.append({"device_id": did, "name": name_of(did) or "Mac",
                             "state": "awake" if awake else "sleeping",
                             "held": bool(status.get("held")) if awake else False,
                             "reason": (status.get("reason") or "") if awake else "",
                             "keep_awake": self._keep(d), "timer_on": bool(d.get("timer_on", True)),
                             "battery": status.get("battery"), "on_ac": status.get("on_ac"),
                             "lid": status.get("lid"), "seen_at": d.get("seen_at"),
                             "wake_requested_at": d.get("wake_requested_at")})
        return {"mac": macs, "password_requests": requests}


_STORE: Optional[MacPowerStore] = None
_STORE_LOCK = threading.Lock()


def _push_wake(token: str, env: str) -> dict:
    from api.push.apns import send_apns
    sandbox = True if env == "development" else False if env == "production" else None
    return send_apns(token, {"kind": "mac_wake"}, alert={"title": "Jarvis", "body": "Waking your Mac"},
                     topic=MAC_TOPIC, sandbox=sandbox)


def _alert_phones(title: str, body: str, data: dict) -> None:
    from api.push import alert_phones
    alert_phones(title, body, data=data, category="MAC_PASSWORD", level="time-sensitive")


def _changed() -> None:
    try:
        from api.agents_core import core
        c = core()
        if c is not None:
            c._changed()
    except Exception:  # noqa: BLE001
        log.debug("agents list publish failed", exc_info=True)


def store() -> MacPowerStore:
    global _STORE
    with _STORE_LOCK:
        if _STORE is None:
            from api import device_bridge
            _STORE = MacPowerStore(send_frame=device_bridge.send_frame, push=_push_wake,
                                   alert=_alert_phones, changed=_changed,
                                   connected=device_bridge.connected_device_ids)
        return _STORE


def approval_key() -> Optional[str]:
    """The iPhone's Face ID approval key (the car approver's), for the Mac to pin."""
    try:
        from plugins.toyota import approver as approval
        return approval.approver().registered()
    except Exception:  # noqa: BLE001
        log.debug("approval key unavailable", exc_info=True)
        return None
