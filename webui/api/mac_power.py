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
PC_STATUS_FRESH = 150.0        # the PC reports every 60 s: three missed reports = not awake
SLEEP_QUIET = 10.0             # an "awake" report this soon after a sleep mark is its last one going down
REQUEST_TTL = 120.0
MAC_TOPIC = "com.jarviscopilot.mac"
# How a request can end without him needing a push about it.
_QUIET_ENDINGS = frozenset({"Not allowed", "No answer in 2 minutes"})
_KIND_TITLE = {"sudo": "sudo needs your Mac password", "admin": "Admin password requested",
               "keychain": "Keychain wants your Mac password", "unlock": "Unlock your Mac",
               "rdp": "Remote Desktop", "admin-run": "Run as admin on your PC",
               "pc-run": "Approve a command on your PC"}
# IT-agent approvals: the push shows why, never the command (the sheet shows the exact command), and a
# helper failure is reported on the job card, not as "password not filled".
_COMMAND_KINDS = frozenset({"admin-run", "pc-run"})


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
                 clock: Callable[[], float] = time.time,
                 invoke: Callable[[str, str, dict], dict] = lambda d, skill, args: {"ok": False},
                 os_of: Callable[[str], str] = lambda d: "macos",
                 skills_of: Callable[[str], Iterable[str]] = lambda d: (),
                 name_of: Callable[[str], str] = lambda d: "") -> None:
        self._path = Path(path) if path else _default_path()
        self._send = send_frame
        self._push = push
        self._alert = alert
        self._changed = changed
        self._connected = connected
        self._clock = clock
        # The PC (spec 2026-11-15 §6b): woken by another computer's wol_send skill.
        self._invoke = invoke
        self._os_of = os_of
        self._skills_of = skills_of
        self._name_of = name_of
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
    def _is_pc(self, did: str) -> bool:
        status = (self._devices.get(did) or {}).get("status") or {}
        return (status.get("os") or self._os_of(did)) == "windows"

    def noun(self, did: str) -> str:
        """"PC" for the Windows PC, "Mac" otherwise — what his messages call it."""
        return "PC" if self._is_pc(did) else "Mac"

    def _wake_pc(self, did: str) -> dict:
        """Wake-on-wireless-LAN: a magic packet from another computer on the home network."""
        status = (self._devices.get(did) or {}).get("status") or {}
        wake = status.get("wake") or {}
        if wake.get("capable") is False:
            return {"ok": False, "error": "This PC's Wi-Fi adapter can't be woken remotely."}
        mac = str(status.get("wifi_mac") or "")
        if not mac:
            return {"ok": False, "error": "The PC hasn't told Jarvis its network address yet."}
        senders = [d for d in self._connected() if d != did and "wol_send" in set(self._skills_of(d))]
        senders.sort(key=lambda d: self._os_of(d) != "macos")      # the Mac first
        if not senders:
            return {"ok": False, "error": "No other computer is online to wake the PC."}
        via = self._name_of(senders[0]) or "your other computer"
        args = {"mac": mac}
        if status.get("wifi_ip"):
            args["ip"] = str(status["wifi_ip"])   # also straight to it: some routers hold broadcasts
        res = self._invoke(senders[0], "wol_send", args) or {}
        inner = res.get("result") if isinstance(res.get("result"), dict) else {}
        if not res.get("ok") or inner.get("ok") is False:
            return {"ok": False, "error": f"{via} couldn't send the wake signal: "
                                          f"{inner.get('error') or res.get('error') or 'no answer'}"}
        self._update(did, wake_requested_at=self._clock())  # only once the signal went (else "Waking…" stuck)
        return {"ok": True, "sent": True, "via": via}

    def wake(self, did: str) -> dict:
        if self._is_pc(did):
            return self._wake_pc(did)
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
            frame = {"type": "mac_power_set", "ts": self._clock(), "keep_awake": self._keep(d), "timer_on": bool(d["timer_on"])}
            if d.get("sleeping_at") is not None:
                d["sleeping_at"] = None   # it connected: awake again
                self._save()
        self._send(did, frame)

    def keep_awake(self, did: str, on: bool) -> dict:
        self._update(did, keep_awake=bool(on), keep_awake_at=self._clock())
        return {"ok": True, "delivered": self._send(did, {"type": "mac_power_set", "ts": self._clock(), "keep_awake": bool(on)})}

    def timer(self, did: str, on: bool) -> dict:
        self._update(did, timer_on=bool(on))
        return {"ok": True, "delivered": self._send(did, {"type": "mac_power_set", "ts": self._clock(), "timer_on": bool(on)})}

    def let_sleep(self, did: str) -> dict:
        self._update(did, keep_awake=False, wake_requested_at=None)
        delivered = self._send(did, {"type": "mac_power_set", "ts": self._clock(), "let_sleep": True})
        if delivered and self._is_pc(did):
            self.on_sleeping(did)   # the PC suspends at once (the Mac may decline: it says when it sleeps)
        return {"ok": True, "delivered": delivered}

    def on_sleeping(self, did: str) -> None:
        """The PC said it's going to sleep (device_sleeping) or was told to. A sleeping PC's socket
        can look open for minutes, so the card would keep it "awake" with no Wake button; this
        marks it asleep until it reports in again (on_status / sync)."""
        if self._is_pc(did):
            self._update(did, sleeping_at=self._clock())

    def sleeping(self, did: str) -> bool:
        """The device said it's going to sleep (or was told to) and hasn't reported in since."""
        with self._lock:
            return (self._devices.get(did) or {}).get("sleeping_at") is not None

    def lock(self, did: str) -> dict:
        return {"ok": True, "delivered": bool(self._send(did, {"type": "mac_power_set", "ts": self._clock(), "lock": True}))}

    def unlock(self, did: str) -> dict:
        # The PC unlocks like the Mac: its jc-client asks his iPhone for Face ID, the Jarvis app
        # checks the signed yes and its helper service types the password on the lock screen.
        if did not in set(self._connected()):
            return {"ok": False, "error": ("The PC isn't awake. Wake it first." if self._is_pc(did)
                                           else "The Mac isn't awake. Wake it first.")}
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
            return {"ok": False, "error": f"The {self.noun(did)} isn't connected."}
        with self._lock:
            req["answered"] = True     # off the list now: a reload mustn't bring the card back
        self._changed()
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
        keep = ("state", "held", "reason", "keep_awake", "timer_on", "battery", "on_ac", "lid",
                "os", "wifi_mac", "wifi_ip", "wake", "app")
        fields = {"status": {k: data.get(k) for k in keep}, "seen_at": self._clock()}
        slept = (self._devices.get(did) or {}).get("sleeping_at")
        going_down = slept is not None and self._clock() - float(slept) < SLEEP_QUIET and self._is_pc(did)
        if data.get("state") == "awake" and not going_down:
            fields["wake_requested_at"] = None
            fields["sleeping_at"] = None
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
        if kind in _COMMAND_KINDS:
            req["why"] = str(data.get("why") or "")[:300]
        with self._lock:
            self._requests[rid] = req
        self._changed()
        try:
            title = "Unlock your PC" if kind == "unlock" and self._is_pc(did) else _KIND_TITLE.get(
                kind, f"{self.noun(did)} password requested")
            if kind in _COMMAND_KINDS:
                body = req["why"][:120] or "Approve with Face ID"
            elif kind == "rdp":
                body = _rdp_text(req["context"])
            else:
                body = req["context"] or "Tap to review"
            self._alert(title, body, {"kind": "mac_password", "id": rid, "device_id": did})
        except Exception:  # noqa: BLE001
            log.warning("Mac password push failed", exc_info=True)

    def on_password_done(self, did: str, data: dict) -> None:
        with self._lock:
            req = self._requests.pop(str(data.get("id") or ""), None)
        self._changed()
        error = str(data.get("error") or "")
        # He said yes but the Mac couldn't fill it (not set up, wrong password,
        # dialog gone…): say why, or it looks like Allow did nothing.
        if (req is not None and not data.get("ok") and error and error not in _QUIET_ENDINGS
                and req.get("kind") not in _COMMAND_KINDS):
            try:
                self._alert(f"{self.noun(did)} password not filled", error, {"kind": "mac_password_failed",
                                                               "id": req["id"], "device_id": did})
            except Exception:  # noqa: BLE001
                log.warning("Mac password failure push failed", exc_info=True)

    def app_down(self, did: str) -> bool:
        """The PC's jc-client is connected but says the Jarvis app isn't linked (Screen, Remote Desktop and
        PC Stats all go through the app)."""
        if did not in set(self._connected()):
            return False
        with self._lock:
            status = (self._devices.get(did) or {}).get("status") or {}
        return status.get("app") is False

    # ── for the Agents list ──────────────────────────────────────────────
    def list_payload(self, name_of: Callable[[str], str]) -> dict:
        now = self._clock()
        connected = set(self._connected())
        with self._lock:
            self._requests = {k: r for k, r in self._requests.items() if r["expires"] >= now}
            requests = [{k: v for k, v in r.items() if k != "answered"}
                        for r in self._requests.values() if not r.get("answered")]
            macs = []
            for did, d in self._devices.items():
                status = d.get("status") or {}
                if not status and not (d.get("push") or {}).get("token"):
                    continue
                awake = did in connected and d.get("sleeping_at") is None
                if awake and self._is_pc(did) and now - float(d.get("seen_at") or 0) > PC_STATUS_FRESH:
                    awake = False  # it stopped reporting: asleep (its socket can look open for minutes)
                macs.append({"device_id": did, "name": name_of(did) or self.noun(did),
                             "state": "awake" if awake else "sleeping",
                             "held": bool(status.get("held")) if awake else False,
                             "reason": (status.get("reason") or "") if awake else "",
                             "keep_awake": self._keep(d), "timer_on": bool(d.get("timer_on", True)),
                             "battery": status.get("battery"), "on_ac": status.get("on_ac"),
                             "lid": status.get("lid"), "seen_at": d.get("seen_at"),
                             "wake_requested_at": d.get("wake_requested_at"),
                             "os": status.get("os") or self._os_of(did) or "macos",
                             "wake_capable": (status.get("wake") or {}).get("capable"),
                             # The PC: jc-client up but the Jarvis app gone (None = not reported, a Mac).
                             "app_running": status.get("app") if awake and "app" in status else None,
                             "wake_reason": (status.get("wake") or {}).get("reason")})
        return {"mac": macs, "password_requests": requests}


def _rdp_text(context: str) -> str:
    """A Remote Desktop request's signed context (canonical JSON) in his words."""
    try:
        ctx = json.loads(context or "{}")
    except ValueError:
        ctx = {}
    device = str(ctx.get("device") or "your PC")
    where = "from the web" if ctx.get("client") == "web" else "from your iPhone"
    return f"Connect to {device} {where}"


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
                                   connected=device_bridge.connected_device_ids,
                                   invoke=lambda d, skill, args: device_bridge.invoke_skill(d, skill, args, timeout=10.0),
                                   os_of=device_bridge.device_os,
                                   skills_of=lambda d: [s.get("name") for s in device_bridge.skills_for_device(d)],
                                   name_of=device_bridge.device_name)
        return _STORE


def approval_key() -> Optional[str]:
    """The iPhone's Face ID approval key (the car approver's), for the Mac to pin."""
    try:
        from plugins.toyota import approver as approval
        return approval.approver().registered()
    except Exception:  # noqa: BLE001
        log.debug("approval key unavailable", exc_info=True)
        return None
