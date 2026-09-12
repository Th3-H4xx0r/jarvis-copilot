"""Every Jarvis device and wearable, for the tray menu.

Two sources, because they are two different things:

* ``GET /api/devices`` — the paired devices the server knows about (this Mac, the
  phone, a browser, the ESP32 board), each with whether it is online and whether
  a skill call would actually reach it.
* the phone's ``wearables_list`` skill — the Bluetooth wearables hanging off it
  (ring, bottle, scale), which are not devices of their own: they are skills the
  phone offers. Only the phone knows whether one is currently connected.

Both are fetched on a slow cadence off the UI thread and cached, so opening the
menu never waits on the network, and a server that is down leaves the last known
list in place rather than an empty menu.
"""
from __future__ import annotations

import logging
import threading
import time
from dataclasses import dataclass, field

logger = logging.getLogger(__name__)

# The roster is for glancing at, not for monitoring — this is often enough to be
# current when the menu opens without waking the phone every couple of seconds.
REFRESH_SECONDS = 45.0
# Asking the phone for its wearables goes over the bridge to the device itself,
# so it gets a short leash.
_WEARABLE_TIMEOUT = 8.0
_WEARABLE_SKILL = "wearables_list"


@dataclass(frozen=True)
class DeviceRow:
    """One line in the menu."""

    name: str
    kind: str
    online: bool
    detail: str = ""
    #: "ring" / "bottle" / "scale" / "esp32" when this is a wearable.
    wearable: str = ""
    #: A section heading rather than a device ("Devices", "Wearables").
    header: bool = False

    @property
    def title(self) -> str:
        """What the menu item's text is set to.

        Plain text, because that is all pystray can put in a menu. On macOS it is
        replaced with a styled attributed title and the status dot is drawn —
        see ``mac_popover._style_rows``. The plain form is the fallback, and the
        key the two halves match on, so it has to stay unique and stable.
        """
        return f"{self.name} — {self.detail}" if self.detail else self.name


def kind_symbol(kind: str, name: str = "") -> str:
    """SF Symbol for a device. Wearables use their own rendered picture.

    The name matters as much as the kind: everything that paired through a web
    page is recorded as "browser", including the ESP32 board and this Mac, so a
    globe on all of them tells you nothing. The name is what distinguishes them.
    """
    k = (kind or "").lower()
    n = (name or "").lower()
    if "esp32" in n or "board" in n:
        return "cpu"
    if k.startswith("mobile-ios") or k.startswith("ios") or "iphone" in n:
        return "iphone"
    if k.startswith("mobile"):
        return "ipad"
    if k.startswith("watch"):
        return "applewatch"
    if k.startswith("desktop") or "macbook" in n or "imac" in n or "mac" in n:
        return "laptopcomputer"
    if k.startswith("browser"):
        return "safari"
    return "display"


def _ago(seconds: float) -> str:
    if seconds < 90:
        return "just now"
    if seconds < 3600:
        return f"{int(seconds // 60)}m ago"
    if seconds < 86400:
        return f"{int(seconds // 3600)}h ago"
    return f"{int(seconds // 86400)}d ago"


class DeviceRoster:
    """Cached view of the devices and wearables, refreshed in the background."""

    def __init__(self) -> None:
        self.rows: list = []
        self.error: str = ""
        self._fetched_at = 0.0
        self._lock = threading.Lock()
        self._busy = False

    def maybe_refresh(self, force: bool = False) -> None:
        """Kick off a refresh if the cache is stale. Never blocks the caller."""
        with self._lock:
            if self._busy:
                return
            if not force and (time.monotonic() - self._fetched_at) < REFRESH_SECONDS:
                return
            self._busy = True
        threading.Thread(target=self._refresh, daemon=True, name="tray-roster").start()

    def _refresh(self) -> None:
        try:
            rows, error = fetch()
            with self._lock:
                # A failed fetch keeps the previous list: a menu that empties
                # itself every time the tunnel hiccups is worse than a stale one.
                if rows or not self.rows:
                    self.rows = rows
                self.error = error
                self._fetched_at = time.monotonic()
        except Exception:
            logger.exception("tray: device roster refresh failed")
            with self._lock:
                self._fetched_at = time.monotonic()
        finally:
            with self._lock:
                self._busy = False


def _client():
    from jc_client import credentials
    from jc_client.protocol import HttpClient

    creds = credentials.load()
    if not creds.paired:
        return None
    return HttpClient(creds.server_url, cookie=creds.cookie,
                      expected_fingerprint=creds.cert_fingerprint,
                      cf_client_id=creds.cf_client_id,
                      cf_client_secret=creds.cf_client_secret)


def fetch() -> tuple:
    """(rows, error). Devices first, then whatever wearables the phone reports."""
    import json

    client = _client()
    if client is None:
        return [], "not paired"
    try:
        response = client.request_json("GET", "/api/devices")
        devices = json.loads(response.body).get("devices", [])
    except Exception as exc:
        logger.debug("tray: /api/devices failed: %s", exc)
        return [], str(exc)

    now = time.time()
    rows: list = []
    wearable_host = ""
    for device in devices:
        online = bool(device.get("online"))
        last_seen = float(device.get("last_seen") or 0)
        detail = "" if online else (
            f"last seen {_ago(now - last_seen)}" if last_seen else "never seen")
        rows.append(DeviceRow(name=str(device.get("name") or "Unnamed"),
                              kind=str(device.get("kind") or ""),
                              online=online, detail=detail))
        # The wearables live on whichever device offers the skill — the phone.
        if not wearable_host and device.get("invokable"):
            names = {s.get("name") for s in (device.get("skills") or [])}
            if _WEARABLE_SKILL in names:
                wearable_host = str(device.get("id") or "")

    wearables = _wearables(client, wearable_host) if wearable_host else []
    # Grouped the way the system's own network menus group things, rather than
    # one long undifferentiated list.
    out: list = []
    if rows:
        out.append(DeviceRow(name="Devices", kind="", online=False, header=True))
        out.extend(rows)
    if wearables:
        out.append(DeviceRow(name="Wearables", kind="", online=False, header=True))
        out.extend(wearables)
    return out, ""


def _wearables(client, device_id: str) -> list:
    """The Bluetooth wearables the phone is holding, with their real status."""
    import json

    try:
        response = client.request_json("POST", "/api/devices/skills/invoke", {
            "device_id": device_id, "skill": _WEARABLE_SKILL, "args": {},
            "timeout": _WEARABLE_TIMEOUT,
        })
        payload = json.loads(response.body)
    except Exception as exc:
        logger.debug("tray: wearables_list failed: %s", exc)
        return []
    if not payload.get("ok", True):
        return []
    result = payload.get("result") or payload
    entries = result.get("devices") or result.get("wearables") or []

    rows = []
    for entry in entries:
        model = str(entry.get("model") or "")
        name = str(entry.get("name") or model or "Wearable")
        rows.append(DeviceRow(
            name=name,
            kind="wearable",
            online=bool(entry.get("connected")),
            # The phone already words this ("Connected", "-57 dBm", "Not found").
            detail=str(entry.get("status") or ""),
            wearable=wearable_kind(model, name),
        ))
    return rows


def wearable_kind(model: str, name: str) -> str:
    """Which picture to show. Matched on the model the phone reports."""
    blob = f"{model} {name}".lower()
    if "r12" in blob or "ring" in blob:
        return "ring"
    if "vsitoo" in blob or "bottle" in blob:
        return "bottle"
    if "esf" in blob or "scale" in blob:
        return "scale"
    if "esp32" in blob:
        return "esp32"
    return ""
