"""Live buttons on the phones: their push tokens (``/api/live/*``) and the pushes made with them.

The Control Center tiles and the Lock Screen card / Dynamic Island follow server-side state (the door
alarm, plugins/door_alarm/live_buttons.py) even while Jarvis sleeps on the phone:

- a **control refresh** (APNs ``widgets`` push) to every control push token makes iOS reload the tiles;
- a **Live Activity** push updates or ends a running card (its own token, per source: ``door``), or
  push-to-starts one on a phone that registered a ``<source>-start`` token and has no card running.

Tokens are kept per paired device in ``<root>/live/tokens.json`` (0600, atomic writes) under the root
Jarvis home, like the door alarm's own files: a profile switch moves HERMES_HOME for the whole process,
and the door alarm's thread must find the tokens whichever profile is active.

``handle_live_request(method, path, body, host_signed=False, caller=None, device_id=None)`` →
``(status, payload)``. Only a paired phone or browser session registers — never Jarvis over the
host-signed loopback (it must not aim the alarm's card or tiles at another device), never a board::

    POST /control-tokens {tokens: [hex]}      this device's control push tokens (replaces its list)
    POST /activity-token {source, token}      a running card's token ("door") or a push-to-start
                                              token ("door-start"); token "" forgets it
"""
from __future__ import annotations

import json
import logging
import os
import re
import tempfile
import threading
import time
from pathlib import Path
from typing import Callable, Optional

LIVE_PATH_PREFIX = "/api/live"
LIVE_PATHS = ("/api/live/control-tokens", "/api/live/activity-token")
log = logging.getLogger(__name__)

_TOKEN = re.compile(r"^[0-9a-f]{16,400}$")
_SOURCE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
MAX_CONTROL_TOKENS = 32
MAX_ACTIVITY_SOURCES = 32


def default_root() -> Path:
    from jarviscopilot_constants import get_default_hermes_root

    return get_default_hermes_root() / "live"


def _token(value) -> Optional[str]:
    if not isinstance(value, str):
        return None
    value = value.strip().lower()
    return value if _TOKEN.match(value) else None


class LiveTokens:
    """``{"devices": {<device id>: {"controls": [hex], "activities": {<source>: {"token", "at"}}}}}``."""

    def __init__(self, root: Path | None = None, clock: Callable[[], float] = time.time) -> None:
        self.root = Path(root) if root else default_root()
        self.clock = clock
        self._lock = threading.RLock()

    @property
    def path(self) -> Path:
        return self.root / "tokens.json"

    def _read(self) -> dict:
        try:
            data = json.loads(self.path.read_text())
        except (OSError, ValueError):
            return {"devices": {}}
        if not isinstance(data, dict) or not isinstance(data.get("devices"), dict):
            return {"devices": {}}
        return data

    def _write(self, data: dict) -> None:
        self.root.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=self.root, prefix=".tokens.json.")
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w") as fh:
                json.dump(data, fh, indent=1, sort_keys=True)
            os.replace(tmp, self.path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    def _device(self, data: dict, device: str) -> dict:
        dev = data["devices"].setdefault(device, {})
        if not isinstance(dev.get("controls"), list):
            dev["controls"] = []
        if not isinstance(dev.get("activities"), dict):
            dev["activities"] = {}
        return dev

    def _prune(self, data: dict, device: str) -> None:
        dev = data["devices"].get(device) or {}
        if not dev.get("controls") and not dev.get("activities"):
            data["devices"].pop(device, None)

    # ── writes ──

    def set_controls(self, device: str, tokens: list[str]) -> list[str]:
        with self._lock:
            data = self._read()
            dev = self._device(data, device)
            dev["controls"] = list(dict.fromkeys(tokens))
            dev["controls_at"] = self.clock()
            self._prune(data, device)
            self._write(data)
            return list(dev["controls"])

    def set_activity(self, device: str, source: str, token: str) -> None:
        """``token`` "" forgets this device's ``source`` token."""
        with self._lock:
            data = self._read()
            acts = self._device(data, device)["activities"]
            if token:
                acts[source] = {"token": token, "at": self.clock()}
            else:
                acts.pop(source, None)
            self._prune(data, device)
            self._write(data)

    def forget_control(self, token: str) -> None:
        with self._lock:
            data = self._read()
            for device in list(data["devices"]):
                dev = self._device(data, device)
                dev["controls"] = [t for t in dev["controls"] if t != token]
                self._prune(data, device)
            self._write(data)

    def forget_activity(self, device: str, source: str, token: Optional[str] = None) -> None:
        """Forget ``device``'s ``source`` token — only if it is still ``token`` (a newer card's stays)."""
        with self._lock:
            data = self._read()
            if device not in data["devices"]:
                return
            acts = self._device(data, device)["activities"]
            entry = acts.get(source) or {}
            if token is None or entry.get("token") == token:
                acts.pop(source, None)
                self._prune(data, device)
                self._write(data)

    # ── reads ──

    def controls(self) -> list[tuple[str, str]]:
        """(device, token), each token once."""
        out, seen = [], set()
        for device, dev in sorted(self._read()["devices"].items()):
            for token in (dev.get("controls") or []) if isinstance(dev, dict) else []:
                if isinstance(token, str) and token not in seen:
                    seen.add(token)
                    out.append((device, token))
        return out

    def sources(self, device: str) -> set[str]:
        dev = self._read()["devices"].get(device)
        return set((dev.get("activities") or {}) if isinstance(dev, dict) else {})

    def activities(self, source: str) -> list[tuple[str, str, float]]:
        """(device, token, registered at) for every device with a ``source`` token."""
        out = []
        for device, dev in sorted(self._read()["devices"].items()):
            entry = ((dev.get("activities") or {}) if isinstance(dev, dict) else {}).get(source)
            if isinstance(entry, dict) and isinstance(entry.get("token"), str) and entry["token"]:
                out.append((device, entry["token"], float(entry.get("at") or 0)))
        return out


_STORE: Optional[LiveTokens] = None
_STORE_LOCK = threading.Lock()


def store() -> LiveTokens:
    global _STORE
    with _STORE_LOCK:
        if _STORE is None:
            _STORE = LiveTokens()
        return _STORE


# ── pushes ──

def _apns(name: str) -> Callable:
    from api.push import apns
    return getattr(apns, name)


def _send(sender: Callable, *args, **kw) -> dict:
    try:
        return sender(*args, **kw) or {}
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": f"raised: {exc}"}


def _dead(res: dict) -> bool:
    """APNs says this token will never work again (not a transient failure, not a bad payload)."""
    status, error = res.get("status"), str(res.get("error") or "")
    return status == 410 or (status == 400 and ("BadDeviceToken" in error or "DeviceTokenNotForTopic" in error))


def refresh_controls(tokens: LiveTokens | None = None, sender: Callable | None = None) -> int:
    """A ``widgets`` push to every control token: the tiles re-read their timelines now."""
    tokens = tokens or store()
    sender = sender or _apns("send_control_refresh")
    sent = 0
    for device, token in tokens.controls():
        res = _send(sender, token, expiration=int(time.time()) + 600)
        if res.get("ok"):
            sent += 1
            continue
        log.info("live buttons: control refresh to %s (…%s) failed: %s", device, token[-6:], res.get("error"))
        if _dead(res):
            tokens.forget_control(token)
    return sent


def push_activity(source: str, content_state: dict, *, event: str = "update", stale_after: Optional[int] = None,
                  dismissal_after: Optional[int] = None, expiration: Optional[int] = None,
                  tokens: LiveTokens | None = None, sender: Callable | None = None) -> int:
    """Update (or ``event="end"``) every running ``source`` card. An ended card's token is
    forgotten whatever APNs answered — the card is over either way."""
    tokens = tokens or store()
    sender = sender or _apns("send_live_activity")
    sent = 0
    for device, token, _at in tokens.activities(source):
        res = _send(sender, token, content_state, event=event, priority=10, stale_after=stale_after,
                    dismissal_after=dismissal_after, expiration=expiration)
        if res.get("ok"):
            sent += 1
        else:
            log.info("live buttons: %s card %s to %s (…%s) failed: %s", source, event, device, token[-6:],
                     res.get("error"))
        if event == "end" or _dead(res):
            tokens.forget_activity(device, source, token)
    return sent


def needs_start(source: str, tokens: LiveTokens | None = None) -> bool:
    """A phone wants ``source`` cards (a ``<source>-start`` token) and has none running."""
    tokens = tokens or store()
    running = {device for device, _t, _a in tokens.activities(source)}
    return any(device not in running for device, _t, _a in tokens.activities(f"{source}-start"))


def start_activity(source: str, content_state: dict, *, attributes_type: str, attributes: dict, alert: dict,
                   stale_after: Optional[int] = None, expiration: Optional[int] = None,
                   tokens: LiveTokens | None = None, sender: Callable | None = None) -> int:
    """Push-to-start a ``source`` card on each phone that wants one and has none running (iOS 17.2+).
    ``input-push-token`` asks iOS for the new card's own token, which the app then reports."""
    tokens = tokens or store()
    sender = sender or _apns("send_live_activity")
    running = {device for device, _t, _a in tokens.activities(source)}
    extra = {"attributes-type": attributes_type, "attributes": attributes, "alert": alert, "input-push-token": 1}
    sent = 0
    for device, token, _at in tokens.activities(f"{source}-start"):
        if device in running:
            continue
        res = _send(sender, token, content_state, event="start", priority=10, stale_after=stale_after,
                    extra=extra, expiration=expiration)
        if res.get("ok"):
            sent += 1
            continue
        log.info("live buttons: %s card start on %s (…%s) failed: %s", source, device, token[-6:], res.get("error"))
        if _dead(res):
            tokens.forget_activity(device, f"{source}-start", token)
    return sent


def forget_stale(source: str, before: float, tokens: LiveTokens | None = None) -> None:
    """Forget ``source`` card tokens registered before ``before`` (cards nobody ended)."""
    tokens = tokens or store()
    for device, token, at in tokens.activities(source):
        if at < before:
            tokens.forget_activity(device, source, token)


# ── HTTP ──

def live_caller(handler) -> tuple[Optional[str], Optional[str]]:
    """(device id, caller kind) for the request's paired session; kind "board" = an ESP32 or the Pod."""
    try:
        from api import device_bridge
        from api.auth import parse_cookie
        from api.door_routes import caller_kind
        from api.pairing import find_device_by_session
        device = find_device_by_session(parse_cookie(handler) or "") or {}
        if device.get("id"):
            skills = [str(s.get("name") or "") for s in device_bridge.skills_for_device(device["id"])]
            return str(device["id"]), caller_kind(device, skills)
    except Exception:
        log.debug("live caller lookup failed", exc_info=True)
    return None, None


def handle_live_request(method, path, body, host_signed=False, caller=None, device_id=None, tokens=None):
    body = body if isinstance(body, dict) else {}
    p = (path or "").partition("?")[0].rstrip("/") or "/"
    if p not in ("/control-tokens", "/activity-token"):
        return 404, {"ok": False, "error": "unknown live endpoint"}
    if method != "POST":
        return 405, {"ok": False, "error": f"method {method} not allowed"}
    if host_signed:
        return 403, {"ok": False, "error": "Only a paired phone registers its live-button tokens.",
                     "code": "forbidden"}
    if caller == "board":
        return 403, {"ok": False, "error": "Devices can't register live-button tokens.", "code": "forbidden"}
    tokens = tokens or store()
    device = str(device_id or "").strip()[:128]
    if not device:
        # Sessions with no paired device would all share one token list and overwrite each other.
        return 403, {"ok": False, "error": "Only a paired phone registers its live-button tokens.",
                     "code": "forbidden"}
    try:
        if p == "/control-tokens":
            raw = body.get("tokens")
            if not isinstance(raw, list):
                return 400, {"ok": False, "error": "tokens must be a list of hex push tokens"}
            clean = [_token(t) for t in raw]
            if any(t is None for t in clean):
                return 400, {"ok": False, "error": "a token isn't a hex push token"}
            clean = list(dict.fromkeys(clean))
            if len(clean) > MAX_CONTROL_TOKENS:
                return 400, {"ok": False, "error": f"at most {MAX_CONTROL_TOKENS} control tokens"}
            return 200, {"ok": True, "count": len(tokens.set_controls(device, clean))}
        source = body.get("source")
        if not isinstance(source, str) or not _SOURCE.match(source):
            return 400, {"ok": False, "error": "source must be a short name like \"door\""}
        raw = body.get("token")
        if not isinstance(raw, str):
            return 400, {"ok": False, "error": "token required (\"\" forgets it)"}
        token = _token(raw) if raw.strip() else ""
        if token is None:
            return 400, {"ok": False, "error": "token isn't a hex push token"}
        if token and len(tokens.sources(device) | {source}) > MAX_ACTIVITY_SOURCES:
            return 400, {"ok": False, "error": "too many live sources"}
        tokens.set_activity(device, source, token)
        return 200, {"ok": True}
    except OSError as exc:
        log.warning("live buttons: couldn't save tokens: %s", exc)
        return 500, {"ok": False, "error": "couldn't save the token"}
