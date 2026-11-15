"""PC power on Windows (spec 2026-11-15 §6b): what the Agents card shows for the PC and what
it can do from the phone, through the Mac's own frames so the server and the phone need no
second protocol:

* up: ``{"type": "event", "name": "mac_power_status", "data": {...}}`` at connect, on every
  change and every STATUS_EVERY s, with ``os: "windows"``, the Wi-Fi MAC and whether its
  adapter can wake the PC (the server's Wake PC sends a magic packet from another computer);
* down: ``mac_power_set`` with ``keep_awake`` / ``let_sleep`` / ``lock``;
* app link: ``mac_power_state`` / ``mac_power_set`` (UI_REQUESTS), like the Mac app's.

Keep awake is ``SetThreadExecutionState`` (no admin). There is no dark wake on Windows, so
no timer; Unlock is impossible (Windows never lets anything type into its lock screen).
"""
from __future__ import annotations

import json
import logging
import re
import socket
import subprocess
import threading
from typing import Callable, Optional

log = logging.getLogger(__name__)

ES_CONTINUOUS = 0x80000000
ES_SYSTEM_REQUIRED = 0x00000001
STATUS_EVERY = 60.0
_MAC_RE = re.compile(r"^[0-9a-f]{12}$")
_IPV4_RE = re.compile(r"^(?:\d{1,3}\.){3}\d{1,3}$")


# ── Wake-on-LAN ────────────────────────────────────────────────────────────────
def magic_packet(mac: str) -> bytes:
    hexes = re.sub(r"[^0-9a-fA-F]", "", str(mac or "")).lower()
    if not _MAC_RE.match(hexes):
        raise ValueError("bad MAC address")
    return b"\xff" * 6 + bytes.fromhex(hexes) * 16


def send_wol(mac: str, broadcast: str = "255.255.255.255", port: int = 9, ip: str = "") -> dict:
    """Send a Wake-on-LAN magic packet on this computer's network (the Mac wakes the PC).

    A sleeping Wi-Fi card (WoWLAN) only hears what its access point passes on, and some access
    points hold back broadcasts for sleeping clients: with the PC's address the packet also goes
    straight to it (its card answers ARP while asleep) and to its /24's broadcast, each three
    times, on ports 9 and 7."""
    try:
        packet = magic_packet(mac)
    except ValueError:
        return {"ok": False, "error": "bad MAC address"}
    hosts = [broadcast]
    if _IPV4_RE.match(ip or ""):
        hosts += [ip, ip.rsplit(".", 1)[0] + ".255"]
    targets = [(h, p) for h in dict.fromkeys(hosts) for p in dict.fromkeys((int(port), 7))]
    sent, errors = [], []
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        for _ in range(3):
            for host, p in targets:
                try:
                    s.sendto(packet, (host, p))
                    sent.append(f"{host}:{p}")
                except OSError as exc:
                    errors.append(str(exc))
    finally:
        s.close()
    if not sent:
        return {"ok": False, "error": f"couldn't send: {errors[0] if errors else 'no target'}"}
    return {"ok": True, "sent_to": ", ".join(dict.fromkeys(sent))}


def lan_ip() -> str:
    """This PC's address on the home network (the interface with the default route). Connecting a
    UDP socket sends nothing; it only picks the route."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("192.0.2.1", 9))
        addr = s.getsockname()[0]
        return addr if _IPV4_RE.match(addr) and not addr.startswith("127.") else ""
    except OSError:
        return ""
    finally:
        s.close()


def _installed_app(pid: int) -> bool:
    from jc_client.pc_admin import is_jarvis_app
    return is_jarvis_app(pid)


# ── what the PC can do ─────────────────────────────────────────────────────────
_WIFI_PS = (
    "$a = Get-NetAdapter -Physical | Where-Object { $_.NdisPhysicalMedium -eq 9 -or $_.Name -like '*Wi-Fi*' } "
    "| Select-Object -First 1; if ($a) { $m = (Get-NetAdapterAdvancedProperty -Name $a.Name "
    "-RegistryKeyword '*WakeOnMagicPacket' -ErrorAction SilentlyContinue).RegistryValue; "
    "@{name=$a.Name; description=$a.InterfaceDescription; mac=$a.MacAddress; magic=\"$m\"} | ConvertTo-Json -Compress }"
)


def _run(argv: list, timeout: float = 15.0) -> str:
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=timeout,
                              creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0)).stdout or ""
    except (OSError, subprocess.SubprocessError):
        return ""


def _devquery() -> str:
    return _run(["powercfg", "/devicequery", "wake_programmable"])


def _wifi() -> Optional[dict]:
    out = _run(["powershell", "-NoProfile", "-NonInteractive", "-Command", _WIFI_PS]).strip()
    try:
        data = json.loads(out) if out else None
    except ValueError:
        return None
    return data if isinstance(data, dict) else None


def wake_capability(devquery: Callable[[], str] = _devquery, wifi: Callable[[], Optional[dict]] = _wifi) -> dict:
    """Whether a magic packet can wake this PC over Wi-Fi: its adapter must be listed by
    ``powercfg /devicequery wake_programmable`` and must not have magic-packet wake off."""
    return _capability(devquery(), wifi())


def _capability(devquery_out: str, adapter: Optional[dict]) -> dict:
    if not adapter:
        return {"capable": False, "adapter": "", "reason": "no Wi-Fi adapter found"}
    desc = str(adapter.get("description") or adapter.get("name") or "")
    listed = {line.strip().lower() for line in (devquery_out or "").splitlines() if line.strip()}
    if desc.lower() not in listed:
        return {"capable": False, "adapter": desc, "reason": "this Wi-Fi adapter can't wake the PC"}
    if str(adapter.get("magic") or "").strip() == "0":
        return {"capable": False, "adapter": desc, "reason": "wake on magic packet is off for this Wi-Fi adapter"}
    return {"capable": True, "adapter": desc, "reason": ""}


def probe(devquery: Callable[[], str] = _devquery, wifi: Callable[[], Optional[dict]] = _wifi) -> tuple:
    """``(wake capability, "aa:bb:cc:dd:ee:ff" or "")`` from one look at the Wi-Fi adapter."""
    adapter = wifi()
    raw = re.sub(r"[^0-9a-fA-F]", "", str((adapter or {}).get("mac") or "")).lower()
    mac = ":".join(raw[i:i + 2] for i in range(0, 12, 2)) if len(raw) == 12 else ""
    return _capability(devquery(), adapter), mac


def _win_set_state(flags: int) -> int:
    import ctypes
    return int(ctypes.windll.kernel32.SetThreadExecutionState(flags))


def _win_lock() -> None:
    import ctypes
    ctypes.windll.user32.LockWorkStation()


def _win_suspend() -> None:
    import ctypes
    ctypes.windll.powrprof.SetSuspendState(0, 0, 0)


def _battery() -> tuple:
    try:
        import psutil
        b = psutil.sensors_battery()
        return (int(b.percent), bool(b.power_plugged)) if b else (None, None)
    except Exception:  # noqa: BLE001
        return (None, None)


class PcPower:
    UI_REQUESTS = frozenset({"mac_power_state", "mac_power_set", "password_fill_result"})
    power = None   # the Mac's MacPower hold logic has no Windows twin (AgentsLink takes None)

    def __init__(self, send_up: Callable[[dict], object], *, set_state: Callable[[int], int] = _win_set_state,
                 lock: Callable[[], None] = _win_lock, suspend: Callable[[], None] = _win_suspend,
                 probe: Callable[[], tuple] = probe, battery: Callable[[], tuple] = _battery,
                 lan_ip: Callable[[], str] = lan_ip, ui_broadcast: Callable[[dict], None] = lambda m: None,
                 is_app: Optional[Callable[[int], bool]] = None) -> None:
        self._send_up = send_up
        self._lan_ip = lan_ip
        # Unlock PC (the Mac's "Unlock Mac" flow): his iPhone's Face ID yes comes back through the
        # broker; the Jarvis app checks it against its pinned key and types through its helper.
        from jc_client.password_broker import PasswordBroker
        self._ui = ui_broadcast
        self._is_app = is_app or _installed_app
        self._fills: dict = {}    # request id -> (Event, reply holder)
        self._fill_lock = threading.Lock()
        self.passwords = PasswordBroker(lambda m: self._send_up(m), ui_broadcast, self._ask_app)
        self._set_state = set_state
        self._lock = lock
        self._suspend = suspend
        self._probe_fn = probe
        self._battery = battery
        self._keep = False
        self._holder = None   # (thread, release event) while keep-awake is on
        self._probed: Optional[tuple] = None
        self._state_lock = threading.Lock()
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None

    # ── state ────────────────────────────────────────────────────────────
    def keep_awake(self, on: bool) -> dict:
        """SetThreadExecutionState holds only for the thread that calls it, and requests come in
        on any thread: one holder thread sets it and clears it, so off really lets the PC sleep."""
        with self._state_lock:
            self._keep = bool(on)
            holder = self._holder
            if on and holder is None:
                release = threading.Event()
                ready = threading.Event()
                self._holder = (threading.Thread(target=self._hold, args=(release, ready), daemon=True,
                                                 name="pc-keep-awake"), release)
                self._holder[0].start()
                holder_ready = ready
            elif not on and holder is not None:
                self._holder = None
                holder[1].set()
                holder[0].join(timeout=2)
                holder_ready = None
            else:
                holder_ready = None
        if holder_ready is not None:
            holder_ready.wait(timeout=2)
        return {"ok": True, "keep_awake": bool(on)}

    def _hold(self, release: threading.Event, ready: threading.Event) -> None:
        self._set_state(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)
        ready.set()
        release.wait()
        self._set_state(ES_CONTINUOUS)

    def _wake_and_mac(self) -> tuple:
        if self._probed is None:
            try:
                self._probed = self._probe_fn()
            except Exception:  # noqa: BLE001
                self._probed = ({"capable": False, "adapter": "", "reason": "couldn't check the Wi-Fi adapter"}, "")
        return self._probed

    def status(self) -> dict:
        wake, mac = self._wake_and_mac()
        battery, on_ac = self._battery()
        with self._state_lock:
            keep = self._keep
        return {"os": "windows", "state": "awake", "held": keep, "reason": "manual" if keep else "",
                "keep_awake": keep, "timer_on": False, "battery": battery, "on_ac": on_ac, "lid": None,
                "wifi_mac": mac, "wifi_ip": self._lan_ip(), "wake": dict(wake)}

    def status_event(self) -> dict:
        return {"type": "event", "name": "mac_power_status", "data": self.status()}

    def _report(self) -> None:
        try:
            self._send_up(self.status_event())
        except Exception:  # noqa: BLE001
            log.debug("pc power status send failed", exc_info=True)

    # ── from the server / the app ────────────────────────────────────────
    def handle_frame(self, frame: dict) -> None:
        t = frame.get("type")
        if t == "mac_power_set":
            self._apply(frame)
        elif t == "mac_password_unlock":
            if not any(p["kind"] == "unlock" for p in self.passwords.pending()):
                threading.Thread(target=self.passwords.request, args=("unlock", "Unlock PC"), daemon=True,
                                 name="jc-pc-unlock").start()
        elif t == "mac_password_answer":
            self.passwords.on_answer(str(frame.get("id") or ""), str(frame.get("decision") or ""),
                                     frame.get("ts"), frame.get("signature"))

    def _ask_app(self, msg: dict, timeout: float) -> dict:
        """password_fill to the Jarvis app (broadcast); it answers with password_fill_result."""
        rid = str(msg.get("id") or "")
        event, holder = threading.Event(), {}
        with self._fill_lock:
            self._fills[rid] = (event, holder)
        try:
            self._ui(msg)
            if not event.wait(timeout):
                return {"ok": False, "error": "The Jarvis app on the PC didn't answer"}
            return holder
        finally:
            with self._fill_lock:
                self._fills.pop(rid, None)

    def _apply(self, change: dict) -> None:
        if "keep_awake" in change:
            self.keep_awake(bool(change["keep_awake"]))
            self._report()
        if change.get("let_sleep"):
            self.keep_awake(False)
            self._report()
            self._suspend()
        if change.get("lock"):
            self._lock()

    def ui_request(self, req: dict) -> dict:
        kind = req.get("type")
        if kind == "mac_power_state":
            return {"ok": True, **self.status()}
        if kind == "mac_power_set":
            self._apply(req)
            return {"ok": True, **self.status()}
        if kind == "password_fill_result":
            # Only the installed Jarvis app may hand in a result (any process of his can reach the link).
            if not self._is_app(int(req.get("_peer_pid") or 0)):
                return {"ok": False, "error": "not the Jarvis app"}
            with self._fill_lock:
                waiter = self._fills.get(str(req.get("request_id") or ""))
            if waiter is None:
                return {"ok": False}
            event, holder = waiter
            holder.update({k: req[k] for k in ("ok", "error") if k in req})
            event.set()
            return {"ok": True}
        return {"ok": False, "error": "unknown power request"}

    def on_connected(self) -> None:
        self._report()

    # ── lifecycle (the service's power object) ───────────────────────────
    def start(self) -> None:
        if self._thread is not None:
            return
        self._thread = threading.Thread(target=self._loop, daemon=True, name="pc-power")
        self._thread.start()

    def _loop(self) -> None:
        while not self._stop.wait(STATUS_EVERY):
            self._report()

    def wait_while_quiet(self, stop) -> None:
        """The Mac holds reconnects during a quiet timer check-in; the PC has none."""

    def close(self) -> None:
        self._stop.set()
        if self._keep:
            self.keep_awake(False)
