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
import re
import logging
import os
import threading
import time
from pathlib import Path
from typing import Callable, Iterable, Optional

log = logging.getLogger(__name__)

INTENT_MAX = 1200.0       # a wake request older than this is forgotten
GRANT_MAX_S = 30 * 86400.0   # an unlock permission lasts at most 30 days (his pick 2026-11-20)
_GRANT_ID = re.compile(r"^[0-9a-f]{32}$")
CHECKIN_EVERY = 900.0     # the sleeping Mac's timer check-in (jc_client/mac_power.py CHECKIN)
KEEP_AWAKE_MAX = 12 * 3600.0   # "Keep Mac awake" turns itself off after this
PC_STATUS_FRESH = 150.0        # the PC reports every 60 s: three missed reports = not awake
SLEEP_QUIET = 10.0             # an "awake" report this soon after a sleep mark is its last one going down
REQUEST_TTL = 120.0
LIGHT_FRESH = 150.0            # the power button board reports its light every 60 s (PcRole.cpp)
BUTTON_SKILL = "esp32_pc_press"
LIGHTS = frozenset({"on", "asleep", "off", "unknown"})
TAP_MS = 300                   # a short press: wake / boot / Windows' power-button action (Sleep)
FORCE_OFF_MS = 6000            # held past ~4 s the board cuts power
WAKE_CONFIRM_S = 15.0          # no light after a wake press by then: try the Wi-Fi wake too
SLEEP_CONFIRM_S = 25.0         # still lit after a software sleep by then: press the button
WAKE_REPEAT_S = 20.0           # a second Wake this soon after a button wake never presses again (it would sleep it)
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
        self._spawn = lambda fn: threading.Thread(target=fn, daemon=True, name="mac-power-wol").start()
        self._sleep = time.sleep
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

    # ── the PC power button (spec 2026-11-23) ────────────────────────────
    # An ESP32 on the PC's front-panel header (JarvisEsp32 pc_button role) presses its power and
    # reset buttons and reports the power light: steady = on, blinking = asleep, dark = off.
    def _boards(self) -> list:
        return [d for d in self._connected() if BUTTON_SKILL in set(self._skills_of(d))]

    def _pcs(self) -> list:
        with self._lock:
            return [did for did, d in self._devices.items() if (d.get("status") or {}) and self._is_pc(did)]

    def _autolink(self) -> None:
        """One board and one PC: link them. Anything else is ambiguous and stays unlinked."""
        boards, pcs = self._boards(), self._pcs()
        if len(boards) != 1 or len(pcs) != 1:
            return
        with self._lock:
            d = self.device(pcs[0])
            if d.get("button_board") != boards[0]:
                d["button_board"] = boards[0]
                self._save()

    def _linked_board(self, pc: str) -> str:
        if not (self._devices.get(pc) or {}).get("button_board"):
            self._autolink()
        return str((self._devices.get(pc) or {}).get("button_board") or "")

    def button_board(self, pc: str) -> str:
        """The PC's linked power button board, when it's connected (else "")."""
        if not self._is_pc(pc):
            return ""
        board = self._linked_board(pc)
        return board if board and board in set(self._connected()) else ""

    def _pc_of_board(self, board: str) -> str:
        with self._lock:
            return next((did for did, d in self._devices.items() if d.get("button_board") == board), "")

    def on_light(self, board: str, data: dict) -> None:
        """The board's pc_power_light event: on a change and every 60 s."""
        pc = self._pc_of_board(board)
        if not pc:
            self._autolink()
            pc = self._pc_of_board(board)
        if not pc:
            return
        state = str(data.get("light") or "unknown")
        state = state if state in LIGHTS else "unknown"
        now = self._clock()
        try:
            since = now - max(0.0, float(data.get("since_s") or 0))
        except (TypeError, ValueError):
            since = now
        with self._lock:
            d = self.device(pc)
            prev = (d.get("light") or {}).get("light")
            d["light"] = {"light": state, "since": since, "at": now}
            if state in ("on", "asleep"):
                # Unwired LED pins read 0 V, the same as a dark light: trust "off" only once it has been lit.
                d["light_trusted"] = True
            self._save()
        if prev != state:
            self._changed()

    def light(self, pc: str) -> str:
        """"on" | "asleep" | "off" | "unknown" (no board, board offline, or no news for LIGHT_FRESH)."""
        if not self.button_board(pc):
            return "unknown"
        rec = self._devices.get(pc) or {}
        cur = rec.get("light") or {}
        # Only once he says the LED wires are connected: GPIO 34/35 float when unwired and read noise (live
        # 2026-11-23: the card flipped between on / asleep / off).
        if not rec.get("light_wired") or not cur or not rec.get("light_trusted") \
                or self._clock() - float(cur.get("at") or 0) > LIGHT_FRESH:
            return "unknown"
        return str(cur.get("light") or "unknown")

    def set_light_wired(self, pc: str, wired: bool) -> dict:
        """He connected (or removed) the power-light wires; until then the light is ignored."""
        self._update(pc, light_wired=bool(wired))
        return {"ok": True, "light_wired": bool(wired)}

    def _power_button(self, pc: str) -> dict:
        board = self._linked_board(pc)
        return {"linked": bool(board), "connected": bool(board) and board in set(self._connected()),
                "name": (self._name_of(board) or "Power button") if board else "", "light": self.light(pc),
                "light_wired": bool((self._devices.get(pc) or {}).get("light_wired"))}

    def press(self, pc: str, button: str, ms: int, expect: list) -> dict:
        """Press a button through the board. The board itself refuses when the light isn't in expect."""
        board = self.button_board(pc)
        if not board:
            return {"ok": False, "error": "The power button isn't connected."}
        res = self._invoke(board, BUTTON_SKILL, {"button": button, "ms": int(ms), "expect": list(expect)}) or {}
        inner = res.get("result") if isinstance(res.get("result"), dict) else {}
        if res.get("ok") and inner.get("ok") is not False:
            return {"ok": True, **{k: v for k, v in inner.items() if k != "ok"}}
        return {"ok": False, "error": str(inner.get("error") or res.get("error") or "The power button didn't answer.")}

    def _reporting(self, pc: str) -> bool:
        """jc-client is up and reporting: the PC is running whatever the light says."""
        d = self._devices.get(pc) or {}
        return (pc in set(self._connected()) and d.get("sleeping_at") is None
                and self._clock() - float(d.get("seen_at") or 0) <= PC_STATUS_FRESH)

    def _wake_by_button(self, pc: str) -> Optional[dict]:
        """Wake or boot the PC with its power button; None when the board can't (then the Wi-Fi path)."""
        if not self.button_board(pc):
            return None
        if self._reporting(pc) or self.light(pc) == "on":
            # Already on (or still booting from the last tap): a press now would sleep it.
            self._update(pc, wake_requested_at=self._clock())
            return {"ok": True, "already_on": True}
        last = float((self._devices.get(pc) or {}).get("button_wake_at") or 0)
        if self._clock() - last < WAKE_REPEAT_S:
            # Still resuming from the last tap (the light isn't steady for ~3 s): one press only.
            return {"ok": True, "sent": True, "via": "power button"}
        res = self.press(pc, "power", TAP_MS, ["asleep", "off", "unknown"])
        if not res.get("ok"):
            log.info("PC power button press didn't happen: %s", res.get("error"))
            return None
        now = self._clock()
        self._update(pc, wake_requested_at=now, button_wake_at=now, power_action_at=now)

        def confirm() -> None:
            self._sleep(WAKE_CONFIRM_S)
            if self.light(pc) != "on" and not self._reporting(pc):
                log.info("PC still dark %ss after the power button: trying the Wi-Fi wake too", WAKE_CONFIRM_S)
                self._wake_pc(pc)
        self._spawn(confirm)
        return {"ok": True, "sent": True, "via": "power button"}

    def _sleep_fallback(self, pc: str, asked_at: float) -> None:
        """After a software sleep: if the PC is still lit, press the button (only when Windows' power
        button means Sleep, and never on an unknown light or after a newer wake)."""
        if not self.button_board(pc):
            return

        def confirm() -> None:
            self._sleep(SLEEP_CONFIRM_S)
            d = self._devices.get(pc) or {}
            if float(d.get("wake_requested_at") or 0) > asked_at or float(d.get("power_action_at") or 0) > asked_at:
                return   # woken or restarted since: never sleep it again
            if float((d.get("light") or {}).get("since") or 0) > asked_at:
                return   # the light changed after the request: it slept and came back (keyboard, mouse)
            if self.light(pc) == "on" and (d.get("status") or {}).get("button_action") == "sleep":
                log.info("PC still on %ss after the software sleep: pressing the power button", SLEEP_CONFIRM_S)
                self.press(pc, "power", TAP_MS, ["on"])
        self._spawn(confirm)

    def restart(self, did: str) -> dict:
        return self._power_frame(did, "restart")

    def shutdown(self, did: str) -> dict:
        return self._power_frame(did, "shutdown")

    def _power_frame(self, did: str, what: str) -> dict:
        """A clean Windows restart / shutdown, carried out by jc-client on the PC."""
        delivered = bool(self._send(did, {"type": "mac_power_set", "ts": self._clock(), what: True}))
        if not delivered:
            return {"ok": False, "error": f"The {self.noun(did)} isn't connected."}
        self._update(did, keep_awake=False, wake_requested_at=None, power_action_at=self._clock())
        if self._is_pc(did):
            self.on_sleeping(did)
        return {"ok": True, "delivered": True}

    def force(self, pc: str, action: str) -> dict:
        """Force restart (reset button) or force off (hold power). Only after his Face ID (api/pc_power.py)."""
        if action == "force_restart":
            res = self.press(pc, "reset", TAP_MS, ["any"])
        elif action == "force_off":
            res = self.press(pc, "power", FORCE_OFF_MS, ["any"])
        else:
            return {"ok": False, "error": "Unknown power action."}
        if res.get("ok"):
            # Off or restarting now: drop any wake in flight (live: Force off left the card on "Waking…").
            self._update(pc, power_action_at=self._clock(), wake_requested_at=None)
            self.on_sleeping(pc)
        return res

    def _wol_args(self, did: str) -> dict:
        status = (self._devices.get(did) or {}).get("status") or {}
        args = {"mac": str(status.get("wifi_mac") or "")}
        if status.get("wifi_ip"):
            args["ip"] = str(status["wifi_ip"])   # also straight to it: some routers hold broadcasts
        return args

    def _wake_pc(self, did: str) -> dict:
        """Wake-on-wireless-LAN: a magic packet from another device on the home network — the always-on
        Pod first, then a computer; with none awake, the Mac sends it when it next wakes (its timer
        check-in, at most 15 minutes away). Live 2026-11-18: only the Mac could send, and it sleeps too."""
        status = (self._devices.get(did) or {}).get("status") or {}
        wake = status.get("wake") or {}
        own = bool(status.get("timer_on"))   # the PC wakes itself every 15 minutes to ask (jc_client/pc_wake.py)
        no_signal = ("This PC's Wi-Fi adapter can't be woken remotely." if wake.get("capable") is False else
                     "The PC hasn't told Jarvis its network address yet." if not status.get("wifi_mac") else "")
        if no_signal and not own:
            return {"ok": False, "error": no_signal}
        senders = [] if no_signal else [d for d in self._connected()
                                         if d != did and "wol_send" in set(self._skills_of(d))]
        # Devices that never sleep (the Pod: no computer control, and it registers no platform) first, then the
        # Mac, then any other computer (review: the Pod's platform reads "macos").
        senders.sort(key=lambda d: 0 if "ui_look" not in set(self._skills_of(d)) else
                     {"macos": 1, "windows": 2}.get(self._os_of(d) or "", 1))
        args, last = (self._wol_args(did) if not no_signal else {}), ""
        for sender in senders:
            via = self._name_of(sender) or "your other computer"
            res = self._invoke(sender, "wol_send", dict(args)) or {}
            inner = res.get("result") if isinstance(res.get("result"), dict) else {}
            if res.get("ok") and inner.get("ok") is not False:
                self._update(did, wake_requested_at=self._clock())  # only once the signal went (else "Waking…" stuck)
                return {"ok": True, "sent": True, "via": via}
            last = f"{via} couldn't send the wake signal: {inner.get('error') or res.get('error') or 'no answer'}"
        mac = self._sleeping_mac_sender(did) if not no_signal else ""
        if mac or own:
            # Nobody awake can send it: keep the wake pending for the Mac's next check-in (or its connect)
            # and the PC's own.
            self._update(did, wake_requested_at=self._clock())
            d = self.device(mac) if mac else {}
            if (d.get("push") or {}).get("token"):
                try:
                    self._push(d["push"]["token"], d["push"].get("env") or "")
                except Exception:  # noqa: BLE001
                    log.warning("Wake Mac push (for the PC) failed", exc_info=True)
            return {"ok": True, "pending": True, "via": (self._name_of(mac) or "your Mac") if mac else "the PC itself",
                    "within_min": int(CHECKIN_EVERY // 60)}
        return {"ok": False, "error": last or "No other computer is online to wake the PC."}

    def _sleeping_mac_sender(self, pc: str) -> str:
        """A known Mac whose wake timer is on (it checks in every 15 minutes even asleep)."""
        awake = set(self._connected())   # an awake Mac that failed won't check in until it sleeps
        with self._lock:
            for did, d in self._devices.items():
                if (did != pc and did not in awake and not self._is_pc(did) and d.get("timer_on", True)
                        and (d.get("status") or {})):
                    return did
        return ""

    def _pending_pc_wakes(self) -> list:
        """Magic packets owed to PCs whose wake no one awake could send (newest INTENT_MAX)."""
        now, out = self._clock(), []
        with self._lock:
            for did, d in self._devices.items():
                at = d.get("wake_requested_at")
                if self._is_pc(did) and at is not None and now - float(at) <= INTENT_MAX \
                        and (d.get("status") or {}).get("wifi_mac") and did not in set(self._connected()):
                    out.append(self._wol_args(did))
        return out

    def wake(self, did: str) -> dict:
        if self._is_pc(did):
            return self._wake_by_button(did) or self._wake_pc(did)
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
        with self._lock:
            grant = self._grant_live(self.device(did))
        if grant:
            self._send(did, {"type": "mac_unlock_grant", "grant": grant})
        if not self._is_pc(did) and "wol_send" in set(self._skills_of(did)):
            owed = self._pending_pc_wakes()
            if owed:
                self._spawn(lambda: [self._invoke(did, "wol_send", a) for a in owed])

    # ── unlock permission (his ask 2026-11-20: unlock without a Face ID every time) ──────────────
    # His iPhone signs one permission with Face ID; the computer checks it against the key it pins before it
    # types anything, so the server only stores and relays it (it can't make one). Stopping needs no signature.
    def _grant_ok(self, did: str, g) -> str:
        now = self._clock()
        if not isinstance(g, dict):
            return "the permission is missing"
        try:
            ts, until = int(g.get("ts")), int(g.get("until"))
        except (TypeError, ValueError):
            return "the permission's times are wrong"
        if not _GRANT_ID.match(str(g.get("id") or "")) or not str(g.get("signature") or ""):
            return "the permission isn't signed"
        if str(g.get("device") or "") != did:
            return "the permission is for another computer"
        if ts > now + 120 or until <= now or until - ts > GRANT_MAX_S + 60:
            return "the permission's dates aren't allowed (30 days at most)"
        return ""

    def _grant_live(self, d: dict):
        g = d.get("unlock_grant")
        if isinstance(g, dict) and float(g.get("until") or 0) > self._clock():
            return g
        return None

    def set_unlock_grant(self, did: str, grant) -> dict:
        why = self._grant_ok(did, grant)
        if why:
            return {"ok": False, "error": why}
        g = {k: grant[k] for k in ("id", "ts", "until", "device", "signature")}
        g["ts"], g["until"] = int(g["ts"]), int(g["until"])
        self._update(did, unlock_grant=g)
        self._send(did, {"type": "mac_unlock_grant", "grant": g})
        return {"ok": True, "until": g["until"]}

    def revoke_unlock_grant(self, did: str) -> dict:
        with self._lock:
            d = self.device(did)
            g = d.pop("unlock_grant", None)
            self._save()
        self._changed()
        if isinstance(g, dict):
            self._send(did, {"type": "mac_unlock_grant", "revoke": g.get("id")})
        return {"ok": True}

    def keep_awake(self, did: str, on: bool) -> dict:
        self._update(did, keep_awake=bool(on), keep_awake_at=self._clock())
        return {"ok": True, "delivered": self._send(did, {"type": "mac_power_set", "ts": self._clock(), "keep_awake": bool(on)})}

    def timer(self, did: str, on: bool) -> dict:
        self._update(did, timer_on=bool(on))
        return {"ok": True, "delivered": self._send(did, {"type": "mac_power_set", "ts": self._clock(), "timer_on": bool(on)})}

    def let_sleep(self, did: str) -> dict:
        asked_at = self._clock()
        self._update(did, keep_awake=False, wake_requested_at=None)
        delivered = self._send(did, {"type": "mac_power_set", "ts": self._clock(), "let_sleep": True})
        if delivered and self._is_pc(did):
            self.on_sleeping(did)   # the PC suspends at once (the Mac may decline: it says when it sleeps)
        if self._is_pc(did):
            self._sleep_fallback(did, asked_at)
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
        owed = self._pending_pc_wakes() if not self._is_pc(did) else []
        if owed:
            out["wol"] = owed   # the Mac sends these during its dark wake, then sleeps again
        if wake:
            self._changed()
        return out

    def on_status(self, did: str, data: dict) -> None:
        keep = ("state", "held", "reason", "keep_awake", "timer_on", "battery", "on_ac", "lid",
                "os", "wifi_mac", "wifi_ip", "wake", "app", "button_action")
        fields = {"status": {k: data.get(k) for k in keep}, "seen_at": self._clock()}
        slept = (self._devices.get(did) or {}).get("sleeping_at")
        going_down = slept is not None and self._clock() - float(slept) < SLEEP_QUIET and self._is_pc(did)
        if data.get("state") == "awake" and not going_down:
            fields["wake_requested_at"] = None
            fields["sleeping_at"] = None
        self._update(did, **fields)
        if self._is_pc(did) and self._linked_board(did) and (self._devices.get(did) or {}).get("timer_on", True):
            # His ask 2026-11-23: with the power button the PC's 15-minute self-wake (old flow) only wakes it
            # for nothing. Turn it off once a board is linked.
            self.timer(did, False)

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
                state, reason = ("awake", status.get("reason") or "") if awake else ("sleeping", "")
                button = self._power_button(did) if self._is_pc(did) else None
                if button and not awake:
                    # The power light fills in while jc-client isn't reporting (a live report wins:
                    # a miswired light must never hide a running PC).
                    if button["light"] == "on":
                        state, reason = "awake", "starting"
                    elif button["light"] == "off":
                        state = "off"
                macs.append({"device_id": did, "name": name_of(did) or self.noun(did),
                             "state": state,
                             "held": bool(status.get("held")) if awake else False,
                             "reason": reason,
                             "keep_awake": self._keep(d), "timer_on": bool(d.get("timer_on", True)),
                             "battery": status.get("battery"), "on_ac": status.get("on_ac"),
                             "lid": status.get("lid"), "seen_at": d.get("seen_at"),
                             "wake_requested_at": d.get("wake_requested_at"),
                             "os": status.get("os") or self._os_of(did) or "macos",
                             "wake_capable": (status.get("wake") or {}).get("capable"),
                             # The PC: jc-client up but the Jarvis app gone (None = not reported, a Mac).
                             "app_running": status.get("app") if awake and "app" in status else None,
                             "wake_reason": (status.get("wake") or {}).get("reason"),
                             "unlock_grant_until": (self._grant_live(d) or {}).get("until"),
                             **({"power_button": button} if button else {})})
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
            device_bridge.on_device_event("pc_power_light", _STORE.on_light)
        return _STORE


def approval_key() -> Optional[str]:
    """The iPhone's Face ID approval key (the car approver's), for the Mac to pin."""
    try:
        from plugins.toyota import approver as approval
        return approval.approver().registered()
    except Exception:  # noqa: BLE001
        log.debug("approval key unavailable", exc_info=True)
        return None
