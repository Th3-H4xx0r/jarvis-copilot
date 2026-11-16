"""Remote Desktop sessions (spec docs/superpowers/specs/2026-11-15-remote-desktop-design.md, plan Task 1).

The PC's Jarvis app posts its RDP status (edition, RDP on, Tailscale-only firewall, its Tailscale
address, the Windows username, how long since keyboard/mouse input, locked, the game in front,
whether a password is saved). A session request is refused with a code when the PC is asleep,
offline, on Windows Home, not set up, or has no saved password; a game in front or someone at the
PC returns a warning he confirms (``confirm=True``). A session then waits up to 60 s for his Face ID
(``approving``); the PC releases the password for that one session (Task 2), the iPhone relay or
the web gateway opens it (``connected``), and it ends on Disconnect, after ``idle_minutes`` without
traffic, or when the integration is switched off.

Secrets: the credential lives only on the in-memory Session (web: the plaintext password the
gateway needs for NLA; iPhone: ciphertext only it can open). It is never written, logged, put in
the audit or returned as plaintext, and is dropped as soon as the session ends.
"""
from __future__ import annotations

import json
import logging
import secrets
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Optional

log = logging.getLogger(__name__)

APPROVAL_TTL = 60.0      # his Face ID must answer within this
OFFLINE_AFTER = 90.0     # no status for longer → offline
IN_USE_IDLE = 120.0      # keyboard/mouse input more recently than this, unlocked → someone's there
RDP_PORT = 3389
MAX_AUDIT = 200
CLIENTS = ("ios", "web")
DEFAULT_SETTINGS = {"idle_minutes": 30, "warn_game": True, "allow_web": True, "transfer_folder": "Downloads\\Jarvis"}
_STATUS_KEYS = ("device_id", "edition", "rdp_enabled", "firewall_scoped", "username", "tailscale_ip", "idle_s",
                "locked", "game", "remote_session", "has_password")
_LIVE = ("approving", "approved", "connected")


@dataclass
class Session:
    id: str
    device_id: str
    client: str
    state: str
    host: str
    username: str
    enc_pub: Optional[str]
    created: float
    last_activity: float
    expires_at: float
    port: int = RDP_PORT
    credential: Optional[dict] = None      # memory only; never written, logged or shown as plaintext
    error: str = ""
    reason: str = ""
    ended_at: Optional[float] = None
    closers: list = field(default_factory=list)   # live relay/tunnel connections (Tasks 3–4)

    def __repr__(self) -> str:   # never let a credential reach a log line through repr()
        return f"Session(id={self.id!r}, device={self.device_id!r}, client={self.client!r}, state={self.state!r})"


class RdpSessions:
    def __init__(self, *, clock: Callable[[], float] = time.time,
                 send_frame: Callable[[str, dict], bool] = lambda d, f: False,
                 sleeping: Callable[[str], bool] = lambda d: False,
                 game_name: Callable[[str], str] = lambda exe: exe,
                 settings: Callable[[], dict] = lambda: {},
                 device_name: Callable[[str], str] = lambda d: "",
                 audit_path: Optional[Path] = None) -> None:
        self._clock = clock
        self._send = send_frame
        self._sleeping = sleeping
        self._game_name = game_name
        self._settings_fn = settings
        self._device_name = device_name
        self._audit_path = Path(audit_path) if audit_path else None
        self._lock = threading.RLock()
        self._status: dict[str, tuple[float, dict]] = {}
        self._sessions: dict[str, Session] = {}
        self._audit: list[dict] = self._load_audit()

    # ── settings / status ────────────────────────────────────────────────
    def settings(self) -> dict:
        try:
            got = self._settings_fn() or {}
        except Exception:  # noqa: BLE001
            got = {}
        return {**DEFAULT_SETTINGS, **{k: v for k, v in got.items() if v is not None}}

    def put_status(self, device_id: str, status: dict) -> None:
        clean = {k: status.get(k) for k in _STATUS_KEYS}
        clean["device_id"] = device_id
        with self._lock:
            self._status[device_id] = (self._clock(), clean)

    def status(self, device_id: str) -> Optional[dict]:
        """The PC's last status while it's fresh (else None: offline)."""
        with self._lock:
            got = self._status.get(device_id)
        if not got or self._clock() - got[0] > OFFLINE_AFTER:
            return None
        return dict(got[1])

    def statuses(self) -> list[dict]:
        """Every PC's fresh status (no secrets are ever in it), for Jarvis's status tool and the UIs."""
        with self._lock:
            ids = list(self._status)
        return [st for st in (self.status(d) for d in ids) if st]

    def _name(self, device_id: str) -> str:
        try:
            return self._device_name(device_id) or "Your PC"
        except Exception:  # noqa: BLE001
            return "Your PC"

    # ── sessions ─────────────────────────────────────────────────────────
    def create(self, device_id: str, client: str, confirm: bool = False, enc_pub: Optional[str] = None) -> dict:
        self.sweep()
        name = self._name(device_id)
        if client not in CLIENTS:
            return {"error": "Unknown client", "code": "client"}
        try:
            asleep = bool(self._sleeping(device_id))
        except Exception:  # noqa: BLE001
            asleep = False
        if asleep:
            return {"error": f"{name} is asleep", "code": "asleep"}
        st = self.status(device_id)
        if st is None:
            return {"error": f"{name} is offline", "code": "offline"}
        if "home" in str(st.get("edition") or "").lower():
            return {"error": f"{name} runs Windows 11 Home, which can't host Remote Desktop. "
                             "Upgrade to Windows 11 Pro.", "code": "edition"}
        if not st.get("rdp_enabled") or not st.get("tailscale_ip") or not st.get("username"):
            return {"error": f"Remote Desktop isn't set up on {name} yet (Jarvis on the PC → Settings → PC power)",
                    "code": "not_ready"}
        if not st.get("has_password"):
            return {"error": "Save your Windows password in Jarvis on the PC first (Settings → PC power)",
                    "code": "no_password"}
        cfg = self.settings()
        if client == "web" and not cfg.get("allow_web", True):
            return {"error": "Remote Desktop from the web is switched off in its settings", "code": "web_off"}
        if client == "ios" and not enc_pub:
            return {"error": "The iPhone didn't send its key", "code": "client"}
        if not confirm:
            game = st.get("game")
            if game and cfg.get("warn_game", True):
                try:
                    gname = self._game_name(game) or game
                except Exception:  # noqa: BLE001
                    gname = game
                return {"warn": "game", "game_name": gname}
            idle = st.get("idle_s")
            if isinstance(idle, (int, float)) and idle < IN_USE_IDLE and not st.get("locked"):
                return {"warn": "in_use"}
        now = self._clock()
        sess = Session(id=secrets.token_urlsafe(18), device_id=device_id, client=client, state="approving",
                       host=str(st["tailscale_ip"]), username=str(st["username"]),
                       enc_pub=enc_pub if client == "ios" else None, created=now, last_activity=now,
                       expires_at=now + APPROVAL_TTL)
        with self._lock:
            self._sessions[sess.id] = sess
        self._record(sess)
        log.info("rdp session %s: %s from %s, waiting for Face ID", sess.id, device_id, client)
        self._request_credential(sess)
        return {"session": {"id": sess.id, "state": sess.state, "expires_at": sess.expires_at}}

    @staticmethod
    def context(sess: Session, device: str) -> str:
        """The text his Face ID signature covers: canonical JSON, byte for byte the same on the server,
        jc-client, the iPhone and the PC app (≤ 2400 chars, the broker's limit)."""
        return json.dumps({"session": sess.id, "client": sess.client, "enc_pub": sess.enc_pub,
                           "device": device}, sort_keys=True, separators=(",", ":"))[:2400]

    def _request_credential(self, sess: Session) -> None:
        """Ask the PC (its jc-client) to get his Face ID and release the password for this session."""
        frame = {"type": "rdp_credential_request", "session_id": sess.id, "client": sess.client,
                 "context": self.context(sess, self._name(sess.device_id))}
        try:
            delivered = bool(self._send(sess.device_id, frame))
        except Exception:  # noqa: BLE001
            delivered = False
        if not delivered:
            with self._lock:
                self._close(sess, "cancelled", "pc unreachable", f"{self._name(sess.device_id)} didn't answer")

    def get(self, sid: str) -> Optional[Session]:
        self.sweep()
        with self._lock:
            return self._sessions.get(str(sid or ""))

    def public(self, sid: str) -> Optional[dict]:
        """What a client may see: never a plaintext password; the iPhone's ciphertext once approved."""
        sess = self.get(sid)
        if sess is None:
            return None
        out = {"id": sess.id, "state": sess.state, "client": sess.client, "device_id": sess.device_id,
               "expires_at": sess.expires_at, "username": sess.username}
        if sess.error:
            out["error"] = sess.error
        if sess.client == "ios" and sess.state in ("approved", "connected") and sess.credential:
            c = sess.credential
            out["credential"] = {k: c.get(k) for k in ("ciphertext", "ephemeral_pub", "nonce")}
        return out

    def on_credential(self, device_id: str, data: dict) -> None:
        """The PC's answer (its jc-client's ``rdp_credential`` event): the session's credential, or why not."""
        data = data if isinstance(data, dict) else {}
        sid = str(data.get("session_id") or "")
        with self._lock:
            sess = self._sessions.get(sid)
            if sess is None or sess.device_id != device_id or sess.state != "approving":
                log.info("rdp credential for %s dropped (no matching approving session)", sid or "?")
                return
            if self._clock() > sess.expires_at:
                self._close(sess, "cancelled", "approval expired", "No answer on your iPhone in 60 seconds")
                return
            if not data.get("ok"):
                self._close(sess, "cancelled", "refused", str(data.get("error") or "Not allowed")[:200])
                return
            cred = data.get("credential") if isinstance(data.get("credential"), dict) else {}
            if sess.client == "web":
                pw = cred.get("password")
                if not isinstance(pw, str) or not pw:
                    log.warning("rdp credential for %s refused: not a web credential", sid)
                    return
                sess.credential = {"password": pw}
            else:
                parts = {k: cred.get(k) for k in ("ciphertext", "ephemeral_pub", "nonce")}
                if not all(isinstance(v, str) and v for v in parts.values()):
                    log.warning("rdp credential for %s refused: not an iPhone credential", sid)
                    return
                sess.credential = parts
            sess.state = "approved"
            sess.last_activity = self._clock()
        log.info("rdp session %s approved", sid)
        self._record(sess)

    def mark_connected(self, sid: str) -> Optional[Session]:
        """The relay/tunnel opened: approved → connected (one connection per session)."""
        with self._lock:
            sess = self._sessions.get(str(sid or ""))
            if sess is None or sess.state != "approved":
                return None
            sess.state = "connected"
            sess.last_activity = self._clock()
        self._record(sess)
        return sess

    def touch(self, sid: str) -> None:
        with self._lock:
            sess = self._sessions.get(str(sid or ""))
            if sess is not None:
                sess.last_activity = self._clock()

    def attach(self, sid: str, closer: Callable[[], None]) -> bool:
        """Register a live relay/tunnel so end/off close it. False if the session is already over."""
        with self._lock:
            sess = self._sessions.get(str(sid or ""))
            if sess is None or sess.state not in _LIVE:
                return False
            sess.closers.append(closer)
            return True

    def end(self, sid: str, reason: str) -> None:
        with self._lock:
            sess = self._sessions.get(str(sid or ""))
            if sess is None or sess.state not in _LIVE:
                return
            closers = self._close(sess, "ended", reason)   # he ended it (cancelled = denied/expired/off)
        self._run_closers(closers)

    def on_off(self) -> None:
        """The integration was switched off: cancel/close every session at once."""
        closers = []
        with self._lock:
            for sess in list(self._sessions.values()):
                if sess.state in _LIVE:
                    closers += self._close(sess, "cancelled", "switched off", "Remote Desktop was switched off")
        self._run_closers(closers)

    def sweep(self) -> None:
        """Approvals past 60 s are cancelled; open sessions idle past ``idle_minutes`` end."""
        now = self._clock()
        idle_s = max(60.0, float(self.settings().get("idle_minutes") or 30) * 60.0)
        closers = []
        with self._lock:
            for sess in list(self._sessions.values()):
                if sess.state == "approving" and now > sess.expires_at:
                    closers += self._close(sess, "cancelled", "approval expired", "No answer on your iPhone in 60 seconds")
                elif sess.state in ("approved", "connected") and now - sess.last_activity > idle_s:
                    closers += self._close(sess, "ended", "idle")
            # forget finished sessions after an hour (the audit keeps the record)
            for sid in [s.id for s in self._sessions.values() if s.ended_at and now - s.ended_at > 3600]:
                self._sessions.pop(sid, None)
        self._run_closers(closers)

    def live(self) -> list[dict]:
        self.sweep()
        with self._lock:
            return [{"id": s.id, "device_id": s.device_id, "client": s.client, "state": s.state,
                     "created": s.created} for s in self._sessions.values() if s.state in _LIVE]

    def _close(self, sess: Session, state: str, reason: str, error: str = "") -> list:
        """Caller holds the lock. Returns the closers to run outside it."""
        sess.state = state
        sess.reason = reason
        if error:
            sess.error = error
        sess.credential = None
        sess.ended_at = self._clock()
        closers, sess.closers = sess.closers, []
        log.info("rdp session %s %s (%s)", sess.id, state, reason)
        self._record(sess)
        return closers

    @staticmethod
    def _run_closers(closers: list) -> None:
        for fn in closers:
            try:
                fn()
            except Exception:  # noqa: BLE001
                log.debug("rdp closer failed", exc_info=True)

    # ── audit (no secrets) ───────────────────────────────────────────────
    def _load_audit(self) -> list:
        if not self._audit_path:
            return []
        try:
            data = json.loads(self._audit_path.read_text())
            return data if isinstance(data, list) else []
        except (OSError, ValueError):
            return []

    def _record(self, sess: Session) -> None:
        entry = {"session": sess.id, "device_id": sess.device_id, "device": self._name(sess.device_id),
                 "client": sess.client, "state": sess.state, "started": sess.created,
                 "ended": sess.ended_at, "reason": sess.reason}
        with self._lock:
            self._audit = [e for e in self._audit if e.get("session") != sess.id]
            self._audit.insert(0, entry)
            del self._audit[MAX_AUDIT:]
            snapshot = list(self._audit)
        if self._audit_path:
            try:
                self._audit_path.parent.mkdir(parents=True, exist_ok=True)
                tmp = self._audit_path.with_suffix(".tmp")
                tmp.write_text(json.dumps(snapshot))
                tmp.replace(self._audit_path)
            except OSError:
                log.warning("rdp audit not saved", exc_info=True)

    def audit(self) -> list:
        with self._lock:
            return [dict(e) for e in self._audit]


# ── the process-wide store ───────────────────────────────────────────────────
_STORE: Optional[RdpSessions] = None
_STORE_LOCK = threading.Lock()


def _settings() -> dict:
    try:
        from jarvis_power import discovery
        return discovery.get("remote-desktop").read_settings()
    except Exception:  # noqa: BLE001
        return {}


def _sleeping(device_id: str) -> bool:
    from api import mac_power
    return mac_power.store().sleeping(device_id)


def _game_name(exe: str) -> str:
    from api import pc_stats_games
    return pc_stats_games.name_of(exe)


def _device_name(device_id: str) -> str:
    from api import device_bridge
    return device_bridge.device_name(device_id) or ""


def _send_frame(device_id: str, frame: dict) -> bool:
    from api import device_bridge
    return bool(device_bridge.send_frame(device_id, frame))


def store() -> RdpSessions:
    global _STORE
    with _STORE_LOCK:
        if _STORE is None:
            from jarviscopilot_constants import get_hermes_home
            _STORE = RdpSessions(send_frame=_send_frame, sleeping=_sleeping, game_name=_game_name,
                                 settings=_settings, device_name=_device_name,
                                 audit_path=get_hermes_home() / "rdp" / "audit.json")
            try:   # the PC's answer: {"type": "event", "name": "rdp_credential", "data": {...}}
                from api import device_bridge
                device_bridge.on_device_event("rdp_credential", _STORE.on_credential)
            except Exception:  # noqa: BLE001
                log.warning("rdp_credential event not registered", exc_info=True)
        return _STORE


def create(device_id: str, client: str, confirm: bool = False, enc_pub: Optional[str] = None) -> dict:
    return store().create(device_id, client, confirm, enc_pub)


def get(sid: str) -> Optional[Session]:
    return store().get(sid)


def end(sid: str, reason: str) -> None:
    store().end(sid, reason)


def on_off() -> None:
    if _STORE is not None:
        _STORE.on_off()
