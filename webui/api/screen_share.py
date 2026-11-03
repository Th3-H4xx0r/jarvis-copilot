"""
JarvisCopilot Web UI -- Mac screen shares (WebRTC signalling, TURN credentials, replays).

The Mac app captures its display and publishes it over WebRTC; a viewer (the
iPhone app or the web UI) watches and controls it. This server never carries the
video: it only passes the offer / answer / ICE candidates between the two sides
(long-polled), hands out short-lived TURN credentials for coturn
(``use-auth-secret``), and stores the MP4 the Mac uploads when a task share ends.

Contract (docs/superpowers/plans/2026-11-03-live-browser-and-screen.md, Contract B):

  GET  /api/screen/ice                              → {"ice_servers": [...]}
  POST /api/screen/shares {"reason", "task"?}       → {"id", "status": "requested", "ice_servers"}
  GET  /api/screen/shares?active=1                  → {"shares": [...]}
  GET  /api/screen/shares/<id>                      → the share
  POST /api/screen/shares/<id>/signal {...}         → {"ok", "seq"}
  GET  /api/screen/shares/<id>/signal?for=&after=   → long-poll ≤25 s → {"messages": [...]}
  POST /api/screen/shares/<id>/stop                 → {"ok"}
  POST /api/screen/shares/<id>/replay (raw mp4)     → {"ok", "replay_url"}
  GET  /api/screen/replays/<id>.mp4                 → video/mp4, Range supported

Additions that keep the contract's shapes: a signal message may carry
``"viewer": "<id>"`` (several viewers at once — the Mac echoes it on its answer and
candidates; a viewer that sends none only receives messages that carry none), the
Mac marks itself with ``from=mac`` on its list poll (that is what ``mac_online``
reads), and a share also says ``task`` / ``session_id`` so a chat can find the
live share of its running computer task.

Share records live in memory (signal queues) with a small JSON copy under
``get_hermes_home()/screen/`` (so ended shares and their replays survive a
restart). Each share has its own condition variable: a long poll never holds
the registry lock, so it blocks nothing but its own request thread.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import logging
import os
import re
import secrets
import tempfile
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional
from urllib.parse import parse_qs

logger = logging.getLogger(__name__)

CONFIG_SECTION = "screen"
TURN_USER = "jarvis"
TURN_TTL = 12 * 3600
DEFAULT_TURN_PORT = 3478
DEFAULT_STUN = "stun:stun.l.google.com:19302"

LONG_POLL_MAX = 25.0
VIEWER_FRESH = 35.0          # a viewer whose last poll is older than this has left
MAC_FRESH = 6.0              # the Mac polls the list every ~1-2 s
ANYTIME_IDLE_END = 90.0      # an anytime share nobody watches ends after this
MAX_SHARE_AGE = 2 * 3600.0   # nothing runs longer than this
RETENTION = 14 * 86400.0
CLEANUP_EVERY = 3600.0
MAX_MESSAGES = 600           # per share; old ones fall off the front
MAX_SDP = 200_000
MAX_REPLAY_BYTES = 500 * 1024 * 1024
_CHUNK = 1024 * 1024

REASONS = ("anytime", "task")
SIGNAL_TYPES = ("offer", "answer", "candidate", "bye")
_ID_RE = re.compile(r"^[A-Za-z0-9_-]{6,40}$")
_VIEWER_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,64}$")


def _now() -> float:
    return time.time()


def _iso(ts: Optional[float]) -> Optional[str]:
    if not ts:
        return None
    return datetime.fromtimestamp(ts, timezone.utc).isoformat(timespec="seconds")


def _root() -> Path:
    from jarviscopilot_constants import get_hermes_home
    return Path(get_hermes_home()) / "screen"


def _replays_dir() -> Path:
    return _root() / "replays"


def replay_path(share_id: str) -> Path:
    return _replays_dir() / f"{share_id}.mp4"


# ── TURN credentials ─────────────────────────────────────────────────────────

def _section() -> dict:
    from api import config as api_config
    stored = api_config._load_yaml_config_file(api_config._get_config_path())
    sec = stored.get(CONFIG_SECTION) if isinstance(stored, dict) else None
    return sec if isinstance(sec, dict) else {}


_secret_lock = threading.Lock()


def ensure_turn_secret() -> str:
    """The coturn ``static-auth-secret`` from ``screen.turn_secret``, made on first use."""
    secret = str(_section().get("turn_secret") or "").strip()
    if secret:
        return secret
    from api import config as api_config
    with _secret_lock, api_config._cfg_lock:
        path = api_config._get_config_path()
        stored = api_config._load_yaml_config_file(path)
        sec = stored.get(CONFIG_SECTION)
        if not isinstance(sec, dict):
            sec = {}
        secret = str(sec.get("turn_secret") or "").strip()
        if not secret:
            secret = secrets.token_hex(32)
            sec["turn_secret"] = secret
            sec.setdefault("turn_host", "")
            sec.setdefault("turn_port", DEFAULT_TURN_PORT)
            stored[CONFIG_SECTION] = sec
            api_config._save_yaml_config_file(path, stored)
            try:
                os.chmod(path, 0o600)
            except OSError:
                pass
    try:
        api_config.reload_config()
    except Exception:
        pass
    return secret


def turn_credentials(secret: str, *, now: Optional[float] = None, ttl: int = TURN_TTL) -> tuple:
    """coturn's TURN REST scheme: user ``<expiry>:jarvis``, password base64(HMAC-SHA1(secret, user))."""
    expiry = int((now if now is not None else _now()) + ttl)
    username = f"{expiry}:{TURN_USER}"
    digest = hmac.new(secret.encode("utf-8"), username.encode("utf-8"), hashlib.sha1).digest()
    return username, base64.b64encode(digest).decode("ascii")


# ── Cloudflare TURN (the relay when phone/web and Mac can't reach each other) ──
#
# The server is reachable only through the Cloudflare tunnel, which carries HTTP but not
# TURN's UDP/TCP, so the relay is Cloudflare's managed TURN: the server mints short-lived
# credentials from a TURN key (Settings → Providers → Tool keys, KEY_ID:API_TOKEN).
CLOUDFLARE_STUN = "stun:stun.cloudflare.com:3478"
_CF_TTL = 12 * 3600
_cf_lock = threading.Lock()
_cf_cache: dict = {"key": "", "servers": None, "until": 0.0, "failed_until": 0.0}


def _cloudflare_key() -> tuple:
    raw = (os.environ.get("CLOUDFLARE_TURN_KEY") or "").strip()
    if not raw:
        try:
            from api.providers import _get_hermes_home, _load_env_file
            raw = str(_load_env_file(_get_hermes_home() / ".env").get("CLOUDFLARE_TURN_KEY") or "").strip()
        except Exception:
            raw = ""
    key_id, _, token = raw.partition(":")
    return (key_id.strip(), token.strip()) if key_id.strip() and token.strip() else ("", "")


def _cloudflare_servers(now: float) -> Optional[list]:
    """Cloudflare's ICE servers (STUN + TURN with fresh credentials), cached for half
    their lifetime; None when no key is set or Cloudflare can't be reached."""
    key_id, token = _cloudflare_key()
    if not key_id:
        return None
    with _cf_lock:
        if _cf_cache["key"] == key_id and _cf_cache["servers"] and now < _cf_cache["until"]:
            return _cf_cache["servers"]
        if _cf_cache["key"] == key_id and now < _cf_cache["failed_until"]:
            return None
        try:
            import httpx

            resp = httpx.post(
                f"https://rtc.live.cloudflare.com/v1/turn/keys/{key_id}/credentials/generate-ice-servers",
                headers={"Authorization": f"Bearer {token}"}, json={"ttl": _CF_TTL}, timeout=8)
            resp.raise_for_status()
            raw = resp.json().get("iceServers")
            items = raw if isinstance(raw, list) else [raw] if isinstance(raw, dict) else []
            servers = []
            for item in items:
                urls = item.get("urls") if isinstance(item, dict) else None
                urls = [urls] if isinstance(urls, str) else [str(u) for u in (urls or [])]
                # Port 53 is blocked in browsers and only stalls ICE.
                urls = [u for u in urls if not re.search(r":53(\?|$)", u)]
                if not urls:
                    continue
                entry = {"urls": urls}
                if item.get("username"):
                    entry["username"] = item["username"]
                    entry["credential"] = item.get("credential", "")
                servers.append(entry)
            if not servers:
                raise ValueError("Cloudflare returned no ICE servers")
            _cf_cache.update(key=key_id, servers=servers, until=now + _CF_TTL / 2, failed_until=0.0)
            return servers
        except Exception as exc:
            logger.warning("Cloudflare TURN credentials failed: %s", exc)
            _cf_cache.update(key=key_id, servers=None, until=0.0, failed_until=now + 60)
            return None


def ice_servers(*, now: Optional[float] = None) -> list:
    cloudflare = _cloudflare_servers(now if now is not None else _now())
    if cloudflare:
        has_stun = any(any(str(u).startswith("stun:") for u in s.get("urls", [])) for s in cloudflare)
        return ([] if has_stun else [{"urls": [CLOUDFLARE_STUN]}]) + cloudflare
    sec = _section()
    host = str(sec.get("turn_host") or "").strip()
    try:
        port = int(sec.get("turn_port") or DEFAULT_TURN_PORT)
    except (TypeError, ValueError):
        port = DEFAULT_TURN_PORT
    servers = []
    stun = [f"stun:{host}:{port}"] if host else []
    extra = sec.get("stun_urls")
    if isinstance(extra, list):
        stun += [str(u) for u in extra if str(u).startswith("stun:")]
    elif not host:
        stun.append(DEFAULT_STUN)
    if stun:
        servers.append({"urls": stun})
    if host:
        user, cred = turn_credentials(ensure_turn_secret(), now=now)
        servers.append({"urls": [f"turn:{host}:{port}?transport=udp", f"turn:{host}:{port}?transport=tcp"],
                        "username": user, "credential": cred})
    return servers


# ── the registry ─────────────────────────────────────────────────────────────

class _Share:
    __slots__ = ("id", "reason", "task", "session_id", "status", "created_at", "started_at", "ended_at",
                 "error", "replay", "messages", "seq", "cond", "viewers", "mac_seen")

    def __init__(self, sid: str, reason: str, task: str = "", session_id: str = "", created_at: float = 0.0):
        self.id = sid
        self.reason = reason
        self.task = task
        self.session_id = session_id
        self.status = "requested"
        self.created_at = created_at or _now()
        self.started_at: Optional[float] = None
        self.ended_at: Optional[float] = None
        self.error: Optional[str] = None
        self.replay = False
        self.messages: list = []
        self.seq = 0
        self.cond = threading.Condition()
        self.viewers: dict = {}
        self.mac_seen = 0.0

    def record(self) -> dict:
        return {"id": self.id, "reason": self.reason, "task": self.task, "session_id": self.session_id,
                "status": self.status, "created_at": self.created_at, "started_at": self.started_at,
                "ended_at": self.ended_at, "error": self.error, "replay": self.replay}

    @classmethod
    def from_record(cls, rec: dict) -> Optional["_Share"]:
        sid = str(rec.get("id") or "")
        if not _ID_RE.match(sid):
            return None
        s = cls(sid, str(rec.get("reason") or "anytime"), str(rec.get("task") or ""),
                str(rec.get("session_id") or ""), float(rec.get("created_at") or 0) or _now())
        s.status = str(rec.get("status") or "ended")
        s.started_at = rec.get("started_at")
        s.ended_at = rec.get("ended_at")
        s.error = rec.get("error")
        s.replay = bool(rec.get("replay"))
        return s


class Registry:
    def __init__(self, root: Optional[Path] = None):
        self._lock = threading.Lock()
        self._shares: dict = {}
        self._root = root
        self._mac_seen = 0.0
        self._last_cleanup = 0.0
        self._loaded = False

    # paths (a test passes its own root)
    def root(self) -> Path:
        return self._root or _root()

    def _state_file(self) -> Path:
        return self.root() / "shares.json"

    def _ensure_loaded(self) -> None:
        if self._loaded:
            return
        self._loaded = True
        try:
            data = json.loads(self._state_file().read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return
        now = _now()
        for rec in data.get("shares") or [] if isinstance(data, dict) else []:
            s = _Share.from_record(rec) if isinstance(rec, dict) else None
            if s is None:
                continue
            if s.status != "ended":  # the signalling died with the old process
                s.status = "ended"
                s.ended_at = now
                s.error = s.error or "the server restarted"
            self._shares[s.id] = s

    def _save(self) -> None:
        try:
            path = self._state_file()
            path.parent.mkdir(parents=True, exist_ok=True)
            payload = json.dumps({"shares": [s.record() for s in self._shares.values()]}, indent=1)
            fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".shares-", suffix=".tmp")
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(payload)
            os.replace(tmp, path)
        except OSError as exc:
            logger.warning("screen shares: could not save state: %s", exc)

    # views
    def view(self, s: _Share, now: Optional[float] = None) -> dict:
        now = now if now is not None else _now()
        return {
            "id": s.id, "reason": s.reason, "status": s.status,
            "mac_online": (now - max(self._mac_seen, s.mac_seen)) <= MAC_FRESH,
            "viewers": sum(1 for t in s.viewers.values() if now - t <= VIEWER_FRESH),
            "started_at": _iso(s.started_at), "ended_at": _iso(s.ended_at),
            "replay_url": f"/api/screen/replays/{s.id}.mp4" if s.replay else None,
            "error": s.error,
            "task": s.task or None, "session_id": s.session_id or None,
            "created_at": _iso(s.created_at),
        }

    # lifecycle
    def create(self, reason: str, task: str = "", session_id: str = "") -> dict:
        if reason not in REASONS:
            raise ValueError("reason must be anytime or task")
        sid = "scr_" + secrets.token_hex(8)
        with self._lock:
            self._ensure_loaded()
            self._sweep_locked(_now())
            s = _Share(sid, reason, str(task or "")[:300], str(session_id or "")[:120])
            self._shares[sid] = s
            self._save()
            out = self.view(s)
        self._maybe_cleanup()
        _announce(out)
        return out

    def get(self, sid: str) -> Optional[dict]:
        with self._lock:
            self._ensure_loaded()
            self._sweep_locked(_now())
            s = self._shares.get(sid)
            return self.view(s) if s else None

    def list(self, *, active: bool, from_mac: bool = False) -> list:
        now = _now()
        with self._lock:
            self._ensure_loaded()
            if from_mac:
                self._mac_seen = now
            self._sweep_locked(now)
            shares = [s for s in self._shares.values() if not active or s.status != "ended"]
            shares.sort(key=lambda s: s.created_at, reverse=True)
            out = [self.view(s, now) for s in shares[: (50 if not active else 20)]]
        if from_mac:
            self._maybe_cleanup()
        return out

    def stop(self, sid: str, error: Optional[str] = None) -> bool:
        with self._lock:
            self._ensure_loaded()
            s = self._shares.get(sid)
            if s is None:
                return False
            changed = self._end_locked(s, error)
            if changed:
                self._save()
        if changed:
            _announce({"id": sid, "status": "ended"})
        return True

    def _end_locked(self, s: _Share, error: Optional[str] = None) -> bool:
        if s.status == "ended":
            return False
        s.status = "ended"
        s.ended_at = _now()
        if error and not s.error:
            s.error = error
        with s.cond:
            s.seq += 1
            s.messages.append({"seq": s.seq, "from": "mac", "type": "bye", "reason": error or "stopped"})
            s.cond.notify_all()
        return True

    def _sweep_locked(self, now: float) -> None:
        changed = False
        for s in self._shares.values():
            if s.status == "ended":
                continue
            age = now - s.created_at
            if age > MAX_SHARE_AGE:
                changed |= self._end_locked(s, "the share ran too long")
            elif s.reason == "anytime" and age > ANYTIME_IDLE_END:
                last = max(s.viewers.values(), default=s.created_at)
                if now - last > ANYTIME_IDLE_END:
                    changed |= self._end_locked(s, "no one is watching")
        if changed:
            self._save()

    # signalling
    def post_signal(self, sid: str, msg: dict) -> dict:
        src = msg.get("from")
        kind = msg.get("type")
        if src not in ("viewer", "mac"):
            raise ValueError("from must be viewer or mac")
        if kind not in SIGNAL_TYPES:
            raise ValueError("type must be offer, answer, candidate or bye")
        clean = {"from": src, "type": kind}
        if kind in ("offer", "answer"):
            sdp = msg.get("sdp")
            if not isinstance(sdp, str) or not sdp or len(sdp) > MAX_SDP:
                raise ValueError("sdp is required")
            clean["sdp"] = sdp
        if kind == "candidate":
            c = msg.get("candidate")
            if not isinstance(c, dict) or not isinstance(c.get("candidate"), str):
                raise ValueError("candidate must be {candidate, sdpMid, sdpMLineIndex}")
            idx = c.get("sdpMLineIndex")
            clean["candidate"] = {"candidate": c["candidate"][:2000],
                                  "sdpMid": None if c.get("sdpMid") is None else str(c.get("sdpMid"))[:64],
                                  "sdpMLineIndex": idx if isinstance(idx, int) else None}
        viewer = msg.get("viewer")
        if viewer is not None and viewer != "":
            if not isinstance(viewer, str) or not _VIEWER_RE.match(viewer):
                raise ValueError("viewer must be a short id")
            clean["viewer"] = viewer
        now = _now()
        with self._lock:
            self._ensure_loaded()
            s = self._shares.get(sid)
            if s is None:
                raise KeyError(sid)
            if s.status == "ended":
                raise LookupError("the share has ended")
            if src == "mac":
                s.mac_seen = now
                self._mac_seen = now
                if s.status == "requested":
                    s.status = "live"
                    s.started_at = now
                    self._save()
            else:
                s.viewers[clean.get("viewer", "")] = now
            if src == "viewer" and kind == "bye":
                s.viewers.pop(clean.get("viewer", ""), None)
        with s.cond:
            s.seq += 1
            clean["seq"] = s.seq
            s.messages.append(clean)
            if len(s.messages) > MAX_MESSAGES:
                del s.messages[: len(s.messages) - MAX_MESSAGES]
            s.cond.notify_all()
            return {"ok": True, "seq": clean["seq"]}

    def wait_signal(self, sid: str, for_side: str, after: int, *, viewer: str = "",
                    timeout: float = LONG_POLL_MAX) -> dict:
        if for_side not in ("viewer", "mac"):
            raise ValueError("for must be viewer or mac")
        want_from = "mac" if for_side == "viewer" else "viewer"
        now = _now()
        with self._lock:
            self._ensure_loaded()
            s = self._shares.get(sid)
            if s is None:
                raise KeyError(sid)
            if for_side == "mac":
                s.mac_seen = now
                self._mac_seen = now
                if s.status == "requested":  # the Mac is capturing: the share is live
                    s.status = "live"
                    s.started_at = now
                    self._save()
            else:
                s.viewers[viewer] = now

        def pick() -> list:
            out = []
            for m in s.messages:
                if m["seq"] <= after or m["from"] != want_from:
                    continue
                if for_side == "viewer":
                    to = m.get("viewer")
                    # Addressed to this viewer; a share-wide bye reaches everyone.
                    if viewer and not (to == viewer or (to is None and m["type"] == "bye")):
                        continue
                    if not viewer and to is not None:
                        continue
                out.append(m)
            return out

        deadline = time.monotonic() + max(0.0, min(float(timeout), LONG_POLL_MAX))
        with s.cond:
            found = pick()
            while not found and s.status != "ended":
                left = deadline - time.monotonic()
                if left <= 0:
                    break
                s.cond.wait(left)
                found = pick()
            status = s.status
        if for_side == "viewer":
            with self._lock:
                if s.status != "ended":
                    s.viewers[viewer] = _now()
        return {"messages": found, "status": status}

    # replays
    def store_replay(self, sid: str, rfile, length: int) -> dict:
        with self._lock:
            self._ensure_loaded()
            s = self._shares.get(sid)
        if s is None:
            raise KeyError(sid)
        if length <= 0 or length > MAX_REPLAY_BYTES:
            raise ValueError(f"Content-Length must be between 1 byte and {MAX_REPLAY_BYTES // (1024 * 1024)} MB")
        root = self.root() / "replays"
        root.mkdir(parents=True, exist_ok=True)
        fd, tmp_name = tempfile.mkstemp(dir=root, prefix=f".{sid}-", suffix=".part")
        tmp = Path(tmp_name)
        try:
            remaining = length
            head = b""
            with os.fdopen(fd, "wb") as out:
                while remaining:
                    chunk = rfile.read(min(_CHUNK, remaining))
                    if not chunk:
                        raise ValueError("body shorter than Content-Length")
                    if len(head) < 12:
                        head += chunk[: 12 - len(head)]
                    out.write(chunk)
                    remaining -= len(chunk)
            if head[4:8] != b"ftyp":
                raise ValueError("not an MP4 file")
            os.replace(tmp, root / f"{sid}.mp4")
        finally:
            tmp.unlink(missing_ok=True)
        with self._lock:
            s.replay = True
            self._save()
            return self.view(s)

    def replay_file(self, sid: str) -> Optional[Path]:
        if not _ID_RE.match(sid or ""):
            return None
        p = self.root() / "replays" / f"{sid}.mp4"
        return p if p.is_file() else None

    # retention
    def _maybe_cleanup(self, now: Optional[float] = None) -> None:
        now = now if now is not None else _now()
        if now - self._last_cleanup < CLEANUP_EVERY:
            return
        self._last_cleanup = now
        self.cleanup(now)

    def cleanup(self, now: Optional[float] = None) -> int:
        """Forget shares and delete replays older than 14 days. Returns how many shares went."""
        now = now if now is not None else _now()
        removed = 0
        with self._lock:
            self._ensure_loaded()
            for sid in list(self._shares):
                s = self._shares[sid]
                if s.status == "ended" and now - (s.ended_at or s.created_at) > RETENTION:
                    del self._shares[sid]
                    removed += 1
            if removed:
                self._save()
            known = set(self._shares)
        rdir = self.root() / "replays"
        try:
            entries = list(rdir.iterdir())
        except OSError:
            entries = []
        for p in entries:
            try:
                stale = now - p.stat().st_mtime > RETENTION
                orphan = p.suffix == ".mp4" and p.stem not in known
                partial = p.name.endswith(".part") and now - p.stat().st_mtime > 6 * 3600
                if stale or orphan or partial:
                    p.unlink()
            except OSError:
                continue
        return removed


def _announce(share: dict) -> None:
    """Nudge the Mac app over its existing link (device-bridge topic ``screen_shares``),
    so a new share starts without waiting for its next list poll."""
    try:
        from api import device_bridge
        device_bridge.publish("screen_shares", {"id": share.get("id"), "status": share.get("status")})
    except Exception:
        logger.debug("screen_shares publish failed", exc_info=True)


_REGISTRY: Optional[Registry] = None
_REGISTRY_LOCK = threading.Lock()


def registry() -> Registry:
    global _REGISTRY
    with _REGISTRY_LOCK:
        if _REGISTRY is None:
            _REGISTRY = Registry()
        return _REGISTRY


def reset_for_tests(root: Optional[Path] = None) -> Registry:
    global _REGISTRY
    with _REGISTRY_LOCK:
        _REGISTRY = Registry(root)
        return _REGISTRY


# ── in-process API (agent/computer uses these inside the web UI process) ────

def start_task_share(task: str, session_id: str = "") -> dict:
    return registry().create("task", task, session_id)


def end_share(share_id: str) -> bool:
    return registry().stop(share_id)


# ── HTTP ─────────────────────────────────────────────────────────────────────

PREFIX = "/api/screen/"
_SHARE = re.compile(r"^/api/screen/shares/([A-Za-z0-9_-]+)$")
_SIGNAL = re.compile(r"^/api/screen/shares/([A-Za-z0-9_-]+)/signal$")
_STOP = re.compile(r"^/api/screen/shares/([A-Za-z0-9_-]+)/stop$")
_REPLAY_UP = re.compile(r"^/api/screen/shares/([A-Za-z0-9_-]+)/replay$")
_REPLAY_GET = re.compile(r"^/api/screen/replays/([A-Za-z0-9_-]+)\.mp4$")


def _q(parsed, name: str, default: str = "") -> str:
    return (parse_qs(parsed.query).get(name) or [default])[0]


def _truthy(v: str) -> bool:
    return str(v).strip().lower() in ("1", "true", "yes", "on")


def handle_get(handler, parsed) -> bool:
    from api.helpers import j
    path = parsed.path
    if path == "/api/screen/ice":
        return j(handler, {"ice_servers": ice_servers()}) or True
    if path == "/api/screen/shares":
        shares = registry().list(active=_truthy(_q(parsed, "active")), from_mac=_q(parsed, "from") == "mac")
        return j(handler, {"shares": shares}) or True
    m = _SIGNAL.match(path)
    if m:
        try:
            after = int(_q(parsed, "after", "0") or 0)
        except ValueError:
            after = 0
        try:
            wait = float(_q(parsed, "wait", str(LONG_POLL_MAX)) or LONG_POLL_MAX)
        except ValueError:
            wait = LONG_POLL_MAX
        viewer = _q(parsed, "viewer")
        if viewer and not _VIEWER_RE.match(viewer):
            return j(handler, {"error": "viewer must be a short id"}, status=400) or True
        try:
            out = registry().wait_signal(m.group(1), _q(parsed, "for"), after, viewer=viewer, timeout=wait)
        except KeyError:
            return j(handler, {"error": "no such share"}, status=404) or True
        except ValueError as exc:
            return j(handler, {"error": str(exc)}, status=400) or True
        return j(handler, out) or True
    m = _SHARE.match(path)
    if m:
        share = registry().get(m.group(1))
        if share is None:
            return j(handler, {"error": "no such share"}, status=404) or True
        return j(handler, share) or True
    m = _REPLAY_GET.match(path)
    if m:
        target = registry().replay_file(m.group(1))
        if target is None:
            return j(handler, {"error": "no replay"}, status=404) or True
        from api.routes import _serve_file_bytes
        _serve_file_bytes(handler, target, "video/mp4", "inline", "private, max-age=3600")
        return True
    return False


def handle_post(handler, parsed) -> bool:
    """Every /api/screen POST, before the router reads a JSON body (the replay is raw MP4)."""
    from api.helpers import j, read_body
    path = parsed.path
    m = _REPLAY_UP.match(path)
    if m:
        try:
            length = int(handler.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        try:
            share = registry().store_replay(m.group(1), handler.rfile, length)
        except KeyError:
            return j(handler, {"ok": False, "error": "no such share"}, status=404) or True
        except ValueError as exc:
            return j(handler, {"ok": False, "error": str(exc)}, status=400) or True
        return j(handler, {"ok": True, "replay_url": share["replay_url"]}) or True
    if not path.startswith(PREFIX):
        return False
    try:
        body = read_body(handler)
    except ValueError as exc:
        return j(handler, {"error": str(exc)}, status=413) or True
    if not isinstance(body, dict):
        body = {}
    if path == "/api/screen/shares":
        reason = str(body.get("reason") or "anytime")
        try:
            share = registry().create(reason, str(body.get("task") or ""), str(body.get("session_id") or ""))
        except ValueError as exc:
            return j(handler, {"error": str(exc)}, status=400) or True
        return j(handler, {**share, "ice_servers": ice_servers()}) or True
    m = _SIGNAL.match(path)
    if m:
        try:
            out = registry().post_signal(m.group(1), body)
        except KeyError:
            return j(handler, {"ok": False, "error": "no such share"}, status=404) or True
        except LookupError as exc:
            return j(handler, {"ok": False, "error": str(exc)}, status=410) or True
        except ValueError as exc:
            return j(handler, {"ok": False, "error": str(exc)}, status=400) or True
        return j(handler, out) or True
    m = _STOP.match(path)
    if m:
        err = body.get("error")
        ok = registry().stop(m.group(1), str(err)[:200] if err else None)
        if not ok:
            return j(handler, {"ok": False, "error": "no such share"}, status=404) or True
        return j(handler, {"ok": True}) or True
    return False
