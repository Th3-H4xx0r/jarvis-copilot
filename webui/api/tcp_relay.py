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
# Cap a single reassembled WS message so a misbehaving (but authenticated)
# device can't OOM us with endless un-finished continuation frames. SSH packets
# are small; 8 MiB is far more than any real one. Mirrors the device bridge.
_MAX_MSG_BYTES = 8 * 1024 * 1024


# Cap concurrent relays so an authenticated-but-misbehaving device can't exhaust
# threads/fds/sshd MaxStartups by opening many at once.
_MAX_CONCURRENT_RELAYS = 32

# Relay-level keepalive cadence. The proxy chain (cloudflared/nginx/CF) holds the
# LAST data frame of a quiescent WS stream until its idle reap (~2 min), which
# stalls SSH's close + keepalive handshakes. A TEXT frame this often keeps the
# stream non-quiescent so held frames flush within a few seconds. Must be well
# under Mutagen's own ssh ServerAliveInterval (10s, CountMax=1) so the agent
# connection's keepalive round-trips aren't held past its timeout.
_KEEPALIVE_INTERVAL = 3.0
_relay_count = 0
_relay_count_lock = threading.Lock()


def _target_port() -> int:
    try:
        return int(os.getenv(_TARGET_PORT_ENV, "22"))
    except (TypeError, ValueError):
        return 22


def _is_loopback(host: str) -> bool:
    """True iff every address ``host`` resolves to is a loopback address."""
    import ipaddress
    try:
        infos = socket.getaddrinfo(host, None)
    except OSError:
        return False
    addrs = {info[4][0] for info in infos}
    if not addrs:
        return False
    try:
        return all(ipaddress.ip_address(a).is_loopback for a in addrs)
    except ValueError:
        return False


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


# Touch this file on the server to get per-chunk relay tracing in the journal
# for the NEXT connections (one log line per chunk forwarded + per direction
# end, with monotonic timestamps). Off unless the file exists, so production is
# silent; invaluable for diagnosing teardown/latency through the proxy chain.
_RELAY_DEBUG_FILE = "/tmp/jc-relay-debug"


def _relay_debug_on() -> bool:
    try:
        return os.path.exists(_RELAY_DEBUG_FILE)
    except Exception:
        return False


def relay_pump(a: Channel, b: Channel, labels=("a2b", "b2a")) -> None:
    """Copy bytes A->B and B->A until either side closes, then close both.

    Runs one thread per direction and blocks until both finish. Any error on a
    direction tears the whole relay down (a half-open SSH tunnel is useless).
    Never raises out. ``labels`` names the two directions for debug tracing.
    """
    import time as _time
    stop = threading.Event()
    dbg = _relay_debug_on()
    t0 = _time.monotonic()

    def _copy(src: Channel, dst: Channel, label: str) -> None:
        total = 0
        end_reason = "eof"
        try:
            while not stop.is_set():
                data = src.recv()
                if not data:          # b"" or None == peer closed
                    break
                total += len(data)
                if dbg:
                    log.warning("relay[%s] +%d B (total=%d) @%.3fs",
                                label, len(data), total, _time.monotonic() - t0)
                dst.send(data)
        except Exception as exc:  # noqa: BLE001 — any error ends the relay
            end_reason = f"err:{exc}"
            log.debug("tcp-relay copy ended: %s", exc)
        finally:
            if dbg:
                log.warning("relay[%s] ENDED (%s) total=%d @%.3fs",
                            label, end_reason, total, _time.monotonic() - t0)
            stop.set()
            # Nudge both ends so the other direction's blocking recv() returns.
            for ch in (src, dst):
                try:
                    ch.close()
                except Exception:
                    pass

    t1 = threading.Thread(target=_copy, args=(a, b, labels[0]), daemon=True,
                          name="tcp-relay-a2b")
    t2 = threading.Thread(target=_copy, args=(b, a, labels[1]), daemon=True,
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
                    if len(self._buf) > _MAX_MSG_BYTES:
                        log.warning("tcp-relay: oversize WS message (%d B) — closing",
                                    len(self._buf))
                        return None
                    if getattr(event, "message_finished", True):
                        out = bytes(self._buf)
                        self._buf.clear()
                        if out:
                            return out
                elif isinstance(event, Ping):
                    with self._send_lock:
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

    def send_keepalive(self) -> None:
        """Send a tiny WS TEXT frame as a relay-level keepalive. The proxy chain
        holds the LAST data frame of a quiescent WS stream until its idle reap
        (~2 min) — which stalls SSH's close/keepalive handshakes (the held frame
        IS the exit-status / channel-close / SSH-keepalive). A periodic TEXT
        frame is in-band DATA (unlike a WS control Ping, which the proxies don't
        treat as activity), so it both resets the idle timer AND flushes the
        previously-held frame. The peer (client _WsClientIO / server recv) drops
        TEXT frames, so this never corrupts the binary SSH stream."""
        from wsproto.events import TextMessage
        with self._send_lock:
            self._safe_send_raw(self._ws.send(TextMessage(data="k", message_finished=True)))

    def _safe_send_raw(self, payload: bytes) -> None:
        try:
            self._sock.sendall(payload)
        except OSError as exc:
            raise exc

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        # Send a real WebSocket Close frame BEFORE the raw socket teardown. The
        # SSH stream rides this WS through cloudflared + the nginx edge + the CF
        # edge — all WS-aware proxies. A bare shutdown() is a connection-level
        # half-close they do NOT forward to the downstream peer until their own
        # idle timeout (~2 min) fires, so every short-lived SSH/scp the sync
        # engine runs hung ~125 s at teardown and Mutagen's agent-copy timed out.
        # A Close frame is in-band data the proxies forward immediately (proven:
        # data frames stream in real time), so the peer EOFs at once.
        try:
            from wsproto.events import CloseConnection
            with self._send_lock:
                self._safe_send_raw(self._ws.send(CloseConnection(code=1000)))
        except Exception:  # noqa: BLE001 — best-effort; raw teardown still runs
            pass
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

    # Connect to the LOCAL sshd only. Enforce loopback — never let a (mis)set
    # JC_SYNC_SSH_HOST turn this authenticated relay into a pivot to an internal
    # host (confused-deputy SSRF). Refuse anything that doesn't resolve to
    # loopback.
    if not _is_loopback(_TARGET_HOST):
        log.error("tcp-relay: target %s is not loopback — refusing", _TARGET_HOST)
        try:
            WsSocketChannel(sock, ws).close()
        except Exception:
            pass
        return True
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

    global _relay_count
    with _relay_count_lock:
        if _relay_count >= _MAX_CONCURRENT_RELAYS:
            log.warning("tcp-relay: at capacity (%d) — refusing device=%s",
                        _MAX_CONCURRENT_RELAYS, device.get("id"))
            try:
                tcp.close()
                WsSocketChannel(sock, ws).close()
            except Exception:
                pass
            return True
        _relay_count += 1
    log.info("tcp-relay: device=%s -> %s:%s open (%d active)",
             device.get("id"), _TARGET_HOST, _target_port(), _relay_count)
    ws_chan = WsSocketChannel(sock, ws)
    # Relay-level keepalive: a tiny WS TEXT frame every _KEEPALIVE_INTERVAL keeps
    # the proxy chain from holding the last data frame (see send_keepalive). The
    # client sends its own toward us; this covers the server->client direction.
    ka_stop = threading.Event()

    def _keepalive():
        while not ka_stop.wait(_KEEPALIVE_INTERVAL):
            try:
                ws_chan.send_keepalive()
            except Exception:  # noqa: BLE001 — socket gone; pump will tear down
                return

    ka_thread = threading.Thread(target=_keepalive, daemon=True,
                                 name="tcp-relay-keepalive")
    ka_thread.start()
    try:
        relay_pump(ws_chan, SocketChannel(tcp),
                   labels=("client2sshd", "sshd2client"))
    finally:
        ka_stop.set()
        with _relay_count_lock:
            _relay_count -= 1
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
