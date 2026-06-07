"""Server side of the binary WS<->TCP relay for coding-session file sync.

The new sync engine (Mutagen, running on the desktop) reaches hermes over SSH.
hermes is only reachable via the cloudflared tunnel, so the desktop's SSH stream
is carried by THIS relay: a dedicated WebSocket endpoint
(``/api/devices/tcp-relay``) that — once authenticated exactly like the device
bridge — bridges raw binary WS frames to a local TCP connection to the server's
own ``sshd`` (``127.0.0.1:22``). It is a dumb byte pipe: it never parses the SSH
stream; auth + crypto are end-to-end SSH inside the already-TLS/CF-Access tunnel.

Design for testability: the byte-copying core (:func:`relay_pump`) works over a
tiny :class:`Channel` duplex-byte interface, so it is unit-tested with in-memory
channels and a loopback TCP echo — no real WebSocket needed. ``handle_tcp_relay``
is the thin glue that wraps the wsproto WebSocket and the target socket as
Channels and runs the pump.
"""
from __future__ import annotations

import logging
import os
import socket
import threading

log = logging.getLogger(__name__)

_TARGET_HOST = os.getenv("JC_SYNC_SSH_HOST", "127.0.0.1")
_TARGET_PORT_ENV = "JC_SYNC_SSH_PORT"
_RECV_CHUNK = 65536
_CONNECT_TIMEOUT = 10.0


def _target_port() -> int:
    try:
        return int(os.getenv(_TARGET_PORT_ENV, "22"))
    except (TypeError, ValueError):
        return 22


# ── byte-pump core (transport-agnostic, unit-tested) ──────────────────────────


class Channel:
    """Minimal duplex byte channel. ``recv()`` returns bytes, or ``b""``/None on
    close; ``send(data)`` writes; ``close()`` is idempotent."""

    def recv(self) -> bytes | None:  # pragma: no cover - interface
        raise NotImplementedError

    def send(self, data: bytes) -> None:  # pragma: no cover - interface
        raise NotImplementedError

    def close(self) -> None:  # pragma: no cover - interface
        raise NotImplementedError


def relay_pump(a: Channel, b: Channel) -> None:
    """Copy bytes A->B and B->A until either side closes, then close both.

    Runs one thread per direction and blocks until both finish. Any error on a
    direction tears the whole relay down (a half-open SSH tunnel is useless).
    Never raises out.
    """
    stop = threading.Event()

    def _copy(src: Channel, dst: Channel) -> None:
        try:
            while not stop.is_set():
                data = src.recv()
                if not data:          # b"" or None == peer closed
                    break
                dst.send(data)
        except Exception as exc:  # noqa: BLE001 — any error ends the relay
            log.debug("tcp-relay copy ended: %s", exc)
        finally:
            stop.set()
            # Nudge both ends so the other direction's blocking recv() returns.
            for ch in (src, dst):
                try:
                    ch.close()
                except Exception:
                    pass

    t1 = threading.Thread(target=_copy, args=(a, b), daemon=True,
                          name="tcp-relay-a2b")
    t2 = threading.Thread(target=_copy, args=(b, a), daemon=True,
                          name="tcp-relay-b2a")
    t1.start()
    t2.start()
    t1.join()
    t2.join()


# ── concrete channels ─────────────────────────────────────────────────────────


class SocketChannel(Channel):
    """A plain TCP socket as a Channel."""

    def __init__(self, sock: socket.socket):
        self._sock = sock
        self._closed = False

    def recv(self) -> bytes | None:
        try:
            return self._sock.recv(_RECV_CHUNK)  # b"" on clean close
        except OSError:
            return None

    def send(self, data: bytes) -> None:
        self._sock.sendall(data)

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        try:
            self._sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self._sock.close()
        except OSError:
            pass


class WsSocketChannel(Channel):
    """A wsproto SERVER WebSocket (over a raw socket) as a binary Channel.

    ``recv()`` returns the next inbound BYTES message payload (text/ping/pong are
    handled internally; close returns None). ``send()`` emits one binary
    message. Reassembles multi-chunk messages before returning them.
    """

    def __init__(self, sock: socket.socket, ws):
        from wsproto.events import (  # local import: wsproto optional
            BytesMessage, TextMessage, Ping, Pong, CloseConnection,
        )
        self._sock = sock
        self._ws = ws
        self._send_lock = threading.Lock()
        self._closed = False
        self._buf = bytearray()
        self._ev = {
            "bytes": BytesMessage, "text": TextMessage, "ping": Ping,
            "pong": Pong, "close": CloseConnection,
        }

    def recv(self) -> bytes | None:
        from wsproto.events import (
            BytesMessage, Ping, Pong, CloseConnection,
        )
        while not self._closed:
            try:
                data = self._sock.recv(_RECV_CHUNK)
            except OSError:
                return None
            if not data:
                return None
            try:
                self._ws.receive_data(data)
            except Exception:
                return None
            for event in self._ws.events():
                if isinstance(event, BytesMessage):
                    self._buf += event.data or b""
                    if getattr(event, "message_finished", True):
                        out = bytes(self._buf)
                        self._buf.clear()
                        if out:
                            return out
                elif isinstance(event, Ping):
                    self._safe_send_raw(self._ws.send(Pong(payload=event.payload)))
                elif isinstance(event, (Pong,)):
                    pass
                elif isinstance(event, CloseConnection):
                    return None
                # TextMessage: ignore (sync stream is binary-only)
        return None

    def send(self, data: bytes) -> None:
        from wsproto.events import Message
        with self._send_lock:
            self._safe_send_raw(self._ws.send(Message(data=data, message_finished=True)))

    def _safe_send_raw(self, payload: bytes) -> None:
        try:
            self._sock.sendall(payload)
        except OSError as exc:
            raise exc

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        try:
            self._sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self._sock.close()
        except OSError:
            pass


# ── endpoint glue ─────────────────────────────────────────────────────────────


def handle_tcp_relay(handler, parsed) -> bool:
    """Called from server.do_GET on a WS upgrade. Returns True iff this module
    claims the path (so the caller doesn't fall through to other WS handlers)."""
    if parsed.path != "/api/devices/tcp-relay":
        return False
    try:
        from wsproto import WSConnection, ConnectionType
        from wsproto.events import Request, AcceptConnection
    except Exception:
        _plain(handler, 503, '{"error":"wsproto not installed"}')
        return True

    # Auth: same gate as the device bridge — must map to a paired device.
    try:
        from api.device_bridge import _resolve_device_for_handler, _reconstruct_request
    except Exception:
        _plain(handler, 500, '{"error":"relay unavailable"}')
        return True
    device = _resolve_device_for_handler(handler)
    if not device:
        _plain(handler, 401, '{"error":"no matching paired device for this session"}')
        return True

    sock = handler.connection
    try:
        sock.settimeout(None)
    except Exception:
        pass
    ws = WSConnection(ConnectionType.SERVER)
    try:
        ws.receive_data(_reconstruct_request(handler))
    except Exception:
        return True
    accepted = False
    for event in ws.events():
        if isinstance(event, Request):
            try:
                sock.sendall(ws.send(AcceptConnection()))
                accepted = True
            except Exception:
                return True
            break
    if not accepted:
        return True

    # Connect to the local sshd (never anything but localhost:22 by default).
    try:
        tcp = socket.create_connection((_TARGET_HOST, _target_port()),
                                       timeout=_CONNECT_TIMEOUT)
        tcp.settimeout(None)
    except OSError as exc:
        log.warning("tcp-relay: cannot reach %s:%s: %s",
                    _TARGET_HOST, _target_port(), exc)
        try:
            WsSocketChannel(sock, ws).close()
        except Exception:
            pass
        return True

    log.info("tcp-relay: device=%s -> %s:%s open",
             device.get("id"), _TARGET_HOST, _target_port())
    try:
        relay_pump(WsSocketChannel(sock, ws), SocketChannel(tcp))
    finally:
        log.info("tcp-relay: device=%s closed", device.get("id"))
    return True


def _plain(handler, status: int, body: str) -> None:
    try:
        handler.send_response(status)
        handler.send_header("Content-Type", "application/json")
        handler.end_headers()
        handler.wfile.write(body.encode("utf-8"))
    except Exception:
        pass
