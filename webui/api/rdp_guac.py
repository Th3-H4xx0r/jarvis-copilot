"""The web's Remote Desktop gateway (plan 2026-11-15-remote-desktop, Task 4): a Guacamole tunnel.

``wss://<host>/api/rdp/guac/<session_id>?w=&h=&dpi=`` (WebSocket subprotocol ``guacamole``) speaks
the Guacamole protocol to guacamole-common-js in the browser. Server side it connects to the local
guacd (127.0.0.1:4822 only), does the handshake itself — ``select rdp``, ``size``/``audio``/``video``/
``image``, then ``connect`` with the session's host, username and the password held in memory for
this one connection — and then proxies whole instructions both ways. The browser never sees the
password.

Tunnel details guacamole-common-js expects (as Apache Guacamole's own Java tunnel does): the first
instruction is the internal-opcode one carrying the tunnel id (``0.,36.<uuid>;``), and the JS
tunnel's internal ``ping`` instructions are answered here, never forwarded to guacd.

Files: RDP drive redirection of ``<HERMES_HOME>/rdp/drive/<session>`` ("Jarvis" in Explorer); the
browser uploads/downloads through Guacamole's filesystem objects. A watcher deletes any file over
2 GB (and tells the browser), and the folder is removed when the session ends.

guacd's auth failures (status 0x0301 / 0x0207, or an RDP logon-failure message) reach the browser
as one message: ``PASSWORD_REFUSED``.
"""
from __future__ import annotations

import codecs
import ipaddress
import logging
import os
import re
import shutil
import socket
import threading
import uuid
from pathlib import Path
from typing import Optional
from urllib.parse import parse_qs

log = logging.getLogger(__name__)

GUACD = ("127.0.0.1", 4822)
# RDP security for guacd. Always NLA for the real PC; scripts/dev/xrdp-test.sh sets "any" for the
# xrdp test container, which can't do NLA. Never set this on the server.
SECURITY = os.getenv("JC_RDP_GUAC_SECURITY", "nla")
RDP_PORT = 3389
TAILSCALE = ipaddress.ip_network("100.64.0.0/10")
MAX_FILE = 2 * 1024 ** 3
DRIVE_CHECK_S = 3.0
HANDSHAKE_TIMEOUT = 15.0
PASSWORD_REFUSED = ("Windows refused the saved password — update it in Jarvis on the PC "
                    "(Settings → PC power)")
_AUTH_STATUSES = {str(0x0301), str(0x0207)}
_AUTH_WORDS = re.compile(r"logon failure|authentication fail|invalid credential|wrong password|access denied", re.I)
_PATH = re.compile(r"^/api/rdp/guac/([A-Za-z0-9_-]{8,64})$")


# ── the Guacamole protocol ───────────────────────────────────────────────────
def guac_encode(opcode: str, *args: str) -> str:
    """One instruction: each element as ``<length>.<value>`` (length in code points), ``,``-joined,
    ``;``-terminated."""
    return ",".join(f"{len(e)}.{e}" for e in (str(opcode), *(str(a) for a in args))) + ";"


class GuacStream:
    """Incremental parser: ``feed(text)`` → ``[(instruction elements, raw text)]`` for every instruction
    completed so far; a partial instruction waits for the next feed."""

    def __init__(self) -> None:
        self._buf = ""
        self._pos = 0          # where the current (incomplete) instruction starts
        self._elems: list = []
        self._at = 0           # where parsing resumes inside the buffer

    def feed(self, text: str) -> list:
        self._buf += text
        out = []
        buf = self._buf
        i = self._at
        while True:
            dot = buf.find(".", i)
            if dot < 0:
                break
            try:
                n = int(buf[i:dot])
            except ValueError:
                raise ValueError(f"bad Guacamole element length {buf[i:dot][:20]!r}") from None
            end = dot + 1 + n
            if end >= len(buf):           # value and its terminator not here yet
                break
            self._elems.append(buf[dot + 1:end])
            term = buf[end]
            i = end + 1
            if term == ";":
                out.append((self._elems, buf[self._pos:i]))
                self._elems = []
                self._pos = i
            elif term != ",":
                raise ValueError("bad Guacamole element terminator")
        # drop what's been handed out; keep the partial instruction
        self._buf = buf[self._pos:]
        self._at = i - self._pos
        self._pos = 0
        return out


def guac_parse(buf: str) -> list:
    """Every complete instruction in ``buf`` (an incomplete tail is ignored)."""
    return [ins for ins, _ in GuacStream().feed(buf)]


def map_error(ins: list) -> list:
    """guacd's error for a refused sign-in → his message; any other instruction unchanged."""
    if ins and ins[0] == "error":
        message = ins[1] if len(ins) > 1 else ""
        status = ins[2] if len(ins) > 2 else ""
        if status in _AUTH_STATUSES or _AUTH_WORDS.search(message):
            return ["error", PASSWORD_REFUSED, status or str(0x0301)]
    return ins


# ── files ────────────────────────────────────────────────────────────────────
def check_drive(folder: Path, limit: int = MAX_FILE) -> list:
    """Delete every file over ``limit`` bytes under ``folder``; their paths (relative) for the browser."""
    removed = []
    folder = Path(folder)
    for root, _dirs, files in os.walk(folder):
        for name in files:
            p = Path(root) / name
            try:
                if p.stat().st_size > limit:
                    p.unlink()
                    removed.append(str(p.relative_to(folder)))
            except OSError:
                continue
    if removed:
        log.info("rdp drive: removed %d file(s) over the 2 GB limit", len(removed))
    return removed


def _drive_root() -> Path:
    """Where per-session transfer folders live. JC_RDP_DRIVE_ROOT moves them out of HERMES_HOME when
    guacd runs as its own user and can't reach it (the server: /var/lib/jarvis-rdp/drive)."""
    override = os.getenv("JC_RDP_DRIVE_ROOT", "").strip()
    if override:
        return Path(override)
    from jarviscopilot_constants import get_hermes_home
    return get_hermes_home() / "rdp" / "drive"


# ── sessions ─────────────────────────────────────────────────────────────────
def session_id_of(path: str) -> Optional[str]:
    m = _PATH.match(path or "")
    return m.group(1) if m else None


def size_from_query(query: str) -> tuple:
    q = parse_qs(query or "")

    def num(key, default, lo, hi):
        try:
            v = int(float(q.get(key, [default])[0]))
        except (TypeError, ValueError):
            return default
        return max(lo, min(hi, v))
    return num("w", 1280, 480, 4096), num("h", 720, 480, 4096), num("dpi", 96, 48, 384)


def admit(sid: str, store) -> tuple:
    """``(session, "")`` once an approved web session takes its one tunnel, else ``(None, why)``."""
    sess = store.get(sid)
    if sess is None:
        return None, "No such Remote Desktop session"
    if sess.client != "web":
        return None, "This session isn't for the web"
    if not store.settings().get("allow_web", True):
        return None, "Remote Desktop from the web is switched off in its settings"
    if sess.state != "approved":
        return None, {"approving": "Waiting for Face ID", "connected": "This session is already connected"}.get(
            sess.state, "This session has ended")
    try:
        if ipaddress.ip_address(sess.host) not in TAILSCALE:
            raise ValueError
    except ValueError:
        log.warning("rdp tunnel %s refused: target %s is not a Tailscale address", sid, sess.host)
        store.end(sid, "bad target")
        return None, "The PC's address isn't a Tailscale address"
    if not (sess.credential or {}).get("password"):
        return None, "No password for this session"
    got = store.mark_connected(sid)
    if got is None:
        return None, "This session is already connected"
    return got, ""


def connect_args(sess, drive_path: Path, width: int, height: int, dpi: int) -> dict:
    password = (sess.credential or {}).get("password") or ""
    return {"hostname": sess.host, "port": str(RDP_PORT), "username": sess.username, "password": password,
            "width": str(width), "height": str(height), "dpi": str(dpi), "security": SECURITY,
            "ignore-cert": "true", "resize-method": "display-update", "enable-drive": "true",
            "drive-name": "Jarvis", "drive-path": str(drive_path), "create-drive-path": "true",
            "enable-audio-input": "false", "color-depth": "24"}


class GuacError(Exception):
    pass


def _send(sock: socket.socket, text: str) -> None:
    sock.sendall(text.encode("utf-8"))


def handshake(sock: socket.socket, sess, drive_path: Path, width: int, height: int, dpi: int,
              stream: GuacStream, decoder) -> list:
    """guacd's side of the connection, up to ``ready``. Returns any instructions guacd sent right after
    ``ready`` in the same read (they go to the browser). Raises GuacError."""
    _send(sock, guac_encode("select", "rdp"))
    pending: list = []

    def next_ins():
        while not pending:
            data = sock.recv(65536)
            if not data:
                raise GuacError("guacd closed the connection")
            pending.extend(stream.feed(decoder.decode(data)))
        return pending.pop(0)

    ins, _ = next_ins()
    if ins[0] == "error":
        raise GuacError(ins[1] if len(ins) > 1 else "guacd refused")
    if ins[0] != "args":
        raise GuacError(f"guacd sent {ins[0]!r} instead of args")
    values = connect_args(sess, drive_path, width, height, dpi)
    _send(sock, guac_encode("size", str(width), str(height), str(dpi)))
    _send(sock, guac_encode("audio", "audio/L16"))
    _send(sock, guac_encode("video"))
    _send(sock, guac_encode("image", "image/png", "image/jpeg", "image/webp"))
    # guacd lists its parameter names (the first is its protocol version, echoed back as-is)
    names = ins[1:]
    out = [n if n.startswith("VERSION_") else values.get(n, "") for n in names]
    _send(sock, guac_encode("connect", *out))
    ins, raw = next_ins()
    if ins[0] == "error":
        raise GuacError(map_error(ins)[1])
    if ins[0] != "ready":
        raise GuacError(f"guacd sent {ins[0]!r} instead of ready")
    return list(pending)


def run(sess, browser, store, *, guacd: tuple = GUACD, width: int = 1280, height: int = 720, dpi: int = 96,
        drive_root: Optional[Path] = None) -> None:
    """Handshake with guacd for the admitted session, then proxy until either side closes; ends the
    session and removes its drive folder."""
    sid = sess.id
    drive = Path(drive_root or _drive_root()) / sid
    stopped = threading.Event()
    sock: Optional[socket.socket] = None
    send_lock = threading.Lock()

    def to_browser(text: str) -> None:
        with send_lock:
            browser.send(text)

    def close_all():
        stopped.set()
        for fn in (browser.close, (lambda: sock and sock.shutdown(socket.SHUT_RDWR)), (lambda: sock and sock.close())):
            try:
                fn()
            except Exception:  # noqa: BLE001
                pass

    try:
        drive.mkdir(parents=True, exist_ok=True)
        os.chmod(drive, 0o2770)   # guacd (its own user, group of the setgid parent on the server) writes here
        if not store.attach(sid, close_all):
            close_all()
            return
        try:
            sock = socket.create_connection(guacd, timeout=HANDSHAKE_TIMEOUT)
        except OSError as exc:
            log.warning("rdp tunnel %s: guacd unreachable (%s)", sid, exc)
            to_browser(guac_encode("error", "The Remote Desktop gateway isn't running on the server", "512"))
            return
        stream = GuacStream()
        decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        try:
            early = handshake(sock, sess, drive, width, height, dpi, stream, decoder)
        except (GuacError, OSError, ValueError) as exc:
            msg = str(exc) if str(exc) == PASSWORD_REFUSED else f"Couldn't start Remote Desktop: {exc}"
            log.warning("rdp tunnel %s: handshake failed (%s)", sid, "password refused" if str(exc) == PASSWORD_REFUSED
                        else type(exc).__name__)
            to_browser(guac_encode("error", msg, "769" if str(exc) == PASSWORD_REFUSED else "512"))
            return
        finally:
            # the password was only needed for connect: drop it from memory now
            if sess.credential:
                sess.credential = None
        sock.settimeout(None)
        log.info("rdp tunnel %s open", sid)
        to_browser(guac_encode("", str(uuid.uuid4())))
        for ins, raw in early:
            to_browser(guac_encode(*map_error(ins)) if ins[0] == "error" else raw)

        def watch_drive():
            while not stopped.wait(DRIVE_CHECK_S):
                for name in check_drive(drive):
                    try:
                        to_browser(guac_encode("jc-notice", f"{name} is over 2 GB and was removed"))
                    except Exception:  # noqa: BLE001
                        return

        threading.Thread(target=watch_drive, daemon=True, name="rdp-drive-watch").start()

        def guacd_to_browser():
            try:
                while not stopped.is_set():
                    data = sock.recv(65536)
                    if not data:
                        break
                    store.touch(sid)
                    parts = stream.feed(decoder.decode(data))
                    if parts:
                        to_browser("".join(guac_encode(*map_error(ins)) if ins[0] == "error" else raw
                                           for ins, raw in parts))
            except Exception:  # noqa: BLE001
                pass
            finally:
                close_all()

        reader = threading.Thread(target=guacd_to_browser, daemon=True, name="rdp-guacd-reader")
        reader.start()
        incoming = GuacStream()
        try:
            while not stopped.is_set():
                text = browser.recv()
                if text is None:
                    break
                store.touch(sid)
                forward = []
                for ins, raw in incoming.feed(text):
                    if ins and ins[0] == "":          # the JS tunnel's internal opcode (ping): answer it here
                        if len(ins) > 1 and ins[1] == "ping":
                            to_browser(raw)
                        continue
                    forward.append(raw)
                if forward:
                    _send(sock, "".join(forward))
        except Exception:  # noqa: BLE001
            pass
        finally:
            close_all()
            reader.join(timeout=2)
    finally:
        close_all()
        store.end(sid, "disconnected")
        shutil.rmtree(drive, ignore_errors=True)
        log.info("rdp tunnel %s closed", sid)


# ── the browser's WebSocket (text frames) ────────────────────────────────────
class WsTextChannel:
    """A wsproto server WebSocket carrying text messages: recv() → str | None, send(str)."""

    def __init__(self, sock: socket.socket, ws) -> None:
        self._sock = sock
        self._ws = ws
        self._lock = threading.Lock()
        self._closed = False
        self._parts: list = []
        self._ready: list = []

    def recv(self) -> Optional[str]:
        from wsproto.events import CloseConnection, Ping, TextMessage
        while not self._closed:
            if self._ready:
                return self._ready.pop(0)
            try:
                data = self._sock.recv(65536)
            except OSError:
                return None
            if not data:
                return None
            try:
                self._ws.receive_data(data)
            except Exception:  # noqa: BLE001
                return None
            for ev in self._ws.events():
                if isinstance(ev, TextMessage):
                    self._parts.append(ev.data)
                    if ev.message_finished:
                        self._ready.append("".join(self._parts))
                        self._parts = []
                elif isinstance(ev, Ping):
                    with self._lock:
                        try:
                            self._sock.sendall(self._ws.send(ev.response()))
                        except OSError:
                            return None
                elif isinstance(ev, CloseConnection):
                    return None
        return None

    def send(self, text: str) -> None:
        from wsproto.events import TextMessage
        with self._lock:
            self._sock.sendall(self._ws.send(TextMessage(data=text)))

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        try:
            from wsproto.events import CloseConnection
            with self._lock:
                self._sock.sendall(self._ws.send(CloseConnection(code=1000)))
        except Exception:  # noqa: BLE001
            pass
        for fn in (lambda: self._sock.shutdown(socket.SHUT_RDWR), self._sock.close):
            try:
                fn()
            except OSError:
                pass


def handle_websocket(handler, parsed) -> bool:
    """server.do_GET's WebSocket dispatch: claims /api/rdp/guac/<id> (True), else False."""
    sid = session_id_of(parsed.path)
    if sid is None:
        return False
    import json
    from api import rdp_sessions, ws_upgrade
    try:
        from jarvis_power import gate
        if gate.route_block(parsed.path):
            ws_upgrade.reply(handler, 409, b'{"error":"Remote Desktop is switched off"}')
            return True
    except Exception:  # noqa: BLE001
        log.debug("power gate check failed", exc_info=True)
    store = rdp_sessions.store()
    sess, why = admit(sid, store)
    if sess is None:
        ws_upgrade.reply(handler, 403, json.dumps({"error": why}).encode())
        return True
    upgraded = ws_upgrade.accept(handler, subprotocol="guacamole")
    if upgraded is None:
        store.end(sid, "upgrade failed")
        return True
    ws, sock = upgraded
    width, height, dpi = size_from_query(parsed.query)
    run(sess, WsTextChannel(sock, ws), store, width=width, height=height, dpi=dpi)
    return True
