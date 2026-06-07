"""Desktop SSH ``ProxyCommand``: bridge stdin/stdout to the server TCP relay.

Mutagen's ``ssh`` runs ``jc-client tcp-relay`` as its ProxyCommand. This opens a
binary WebSocket to ``<server>/api/devices/tcp-relay`` (reusing the stored
pairing creds: cookie, TLS cert-fingerprint pin, CF-Access headers) and bridges
the SSH byte stream over it: process stdin -> WS binary frames, WS binary frames
-> process stdout. The server end pipes that to ``127.0.0.1:22``. It is a dumb
pipe; SSH provides auth + crypto end-to-end inside the already-TLS tunnel.

The byte-bridge core (:func:`bridge`) is transport-agnostic (works over a tiny
duplex interface) so it is unit-tested without a real socket.
"""
from __future__ import annotations

import os
import socket
import sys
import threading
import time
from typing import Optional

_RELAY_PATH = "/api/devices/tcp-relay"
_CHUNK = 65536
# Relay-level keepalive cadence (must match the server's). A tiny WS TEXT frame
# this often keeps the proxy chain from holding the LAST data frame of a
# quiescent SSH stream until its idle reap (~2 min) — which otherwise stalls
# SSH's close + keepalive handshakes. TEXT frames are dropped by both relay ends
# so they never corrupt the binary SSH stream. See server tcp_relay.py.
_KEEPALIVE_INTERVAL = 3.0


# ── byte bridge core (testable) ───────────────────────────────────────────────

class ByteIO:
    """Duplex byte endpoint: ``read()`` returns bytes (b"" on EOF); ``write``;
    ``close``."""
    def read(self) -> bytes:  # pragma: no cover - interface
        raise NotImplementedError

    def write(self, data: bytes) -> None:  # pragma: no cover - interface
        raise NotImplementedError

    def close(self) -> None:  # pragma: no cover - interface
        raise NotImplementedError


def bridge(local: ByteIO, remote: ByteIO) -> None:
    """Copy local<->remote until EITHER direction EOFs, then return.

    Returns as soon as the FIRST direction ends — we do NOT join both. The
    stdin reader can be parked in a blocking ``os.read(0)`` that ``close()``
    does not interrupt on POSIX, so joining it would hang forever. The copy
    threads are daemons: when this returns, ``run()`` closes the socket and the
    ProxyCommand process exits, reaping the parked thread.
    """
    done = threading.Event()

    def _copy(src: ByteIO, dst: ByteIO) -> None:
        try:
            while not done.is_set():
                data = src.read()
                if not data:
                    break
                dst.write(data)
        except Exception:
            pass
        finally:
            done.set()
            for io in (src, dst):
                try:
                    io.close()
                except Exception:
                    pass

    threading.Thread(target=_copy, args=(local, remote), daemon=True).start()
    threading.Thread(target=_copy, args=(remote, local), daemon=True).start()
    done.wait()


class _StdIO(ByteIO):
    """The ProxyCommand process's stdin (read) / stdout (write)."""
    def __init__(self, fd_in: int = 0, fd_out: int = 1):
        self._in, self._out = fd_in, fd_out
        self._closed = False

    def read(self) -> bytes:
        try:
            return os.read(self._in, _CHUNK)
        except OSError:
            return b""

    def write(self, data: bytes) -> None:
        os.write(self._out, data)

    def close(self) -> None:
        self._closed = True
        try:
            os.close(self._in)
        except OSError:
            pass


class _WsClientIO(ByteIO):
    """Client wsproto WebSocket (over a raw socket) as a binary ByteIO."""
    def __init__(self, sock, ws):
        from wsproto.events import BytesMessage, Ping, Pong, CloseConnection
        self._sock = sock
        self._ws = ws
        self._lock = threading.Lock()
        self._buf = bytearray()
        self._closed = False
        self._BytesMessage = BytesMessage
        self._Ping, self._Pong, self._Close = Ping, Pong, CloseConnection

    def read(self) -> bytes:
        while not self._closed:
            try:
                data = self._sock.recv(_CHUNK)
            except OSError:
                return b""
            if not data:
                return b""
            self._ws.receive_data(data)
            for ev in self._ws.events():
                if isinstance(ev, self._BytesMessage):
                    self._buf += ev.data or b""
                    if getattr(ev, "message_finished", True):
                        out = bytes(self._buf)
                        self._buf.clear()
                        if out:
                            return out
                elif isinstance(ev, self._Ping):
                    with self._lock:
                        self._sock.sendall(self._ws.send(self._Pong(payload=ev.payload)))
                elif isinstance(ev, self._Close):
                    return b""
        return b""

    def write(self, data: bytes) -> None:
        from wsproto.events import Message
        with self._lock:
            self._sock.sendall(self._ws.send(Message(data=data, message_finished=True)))

    def send_keepalive(self) -> None:
        """Send a tiny WS TEXT keepalive (client->server direction). Keeps the
        proxy chain from holding our last data frame; the server drops TEXT
        frames so the SSH stream is untouched. See server tcp_relay.py."""
        from wsproto.events import TextMessage
        with self._lock:
            self._sock.sendall(
                self._ws.send(TextMessage(data="k", message_finished=True)))

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        # Mirror the server: emit a real WebSocket Close frame before the raw
        # teardown so the WS-aware proxy chain propagates EOF to the peer at
        # once. A bare shutdown() leaves a half-open WS the edge holds until its
        # idle timeout, which hung SSH/scp teardown ~125 s (see tcp_relay.py).
        try:
            with self._lock:
                self._sock.sendall(self._ws.send(self._Close(code=1000)))
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


# ── connect + run ─────────────────────────────────────────────────────────────

def _connect_relay():
    """TLS-connect + WS-handshake to the relay endpoint; return (sock, ws)."""
    from wsproto import ConnectionType, WSConnection
    from wsproto.events import AcceptConnection, RejectConnection, Request
    from jc_client import credentials
    from jc_client.protocol import (
        _make_ssl_context, _split_url, _verify_fingerprint,
    )

    creds = credentials.load()
    if not creds.paired:
        raise RuntimeError("jc-client is not paired (no server creds)")
    host, port, scheme, prefix = _split_url(creds.server_url)
    sock = socket.create_connection((host, port), timeout=15)
    if scheme == "https":
        ctx = _make_ssl_context()
        sock = ctx.wrap_socket(sock, server_hostname=host)
        _verify_fingerprint(sock, creds.cert_fingerprint)
    sock.settimeout(None)

    ws = WSConnection(ConnectionType.CLIENT)
    extra = [("Origin", f"{scheme}://{host}"), ("User-Agent", "jc-client/relay")]
    if creds.cookie:
        extra.append(("Cookie", creds.cookie))
    if creds.cf_client_id and creds.cf_client_secret:
        extra.append(("CF-Access-Client-Id", creds.cf_client_id))
        extra.append(("CF-Access-Client-Secret", creds.cf_client_secret))
    sock.sendall(ws.send(Request(host=f"{host}:{port}", target=prefix + _RELAY_PATH,
                                 extra_headers=extra)))
    deadline = time.time() + 15
    while time.time() < deadline:
        chunk = sock.recv(_CHUNK)
        if not chunk:
            raise RuntimeError("server closed during relay handshake")
        ws.receive_data(chunk)
        for ev in ws.events():
            if isinstance(ev, AcceptConnection):
                return sock, ws
            if isinstance(ev, RejectConnection):
                raise RuntimeError(f"relay handshake rejected: HTTP {ev.status_code}")
    raise RuntimeError("relay handshake timed out")


def run(_argv: Optional[list] = None) -> int:
    """Entry point for ``jc-client tcp-relay`` (SSH ProxyCommand)."""
    try:
        sock, ws = _connect_relay()
    except Exception as exc:  # noqa: BLE001
        sys.stderr.write(f"jc-client tcp-relay: {exc}\n")
        return 1
    ws_io = _WsClientIO(sock, ws)
    # Keep the proxy chain from holding our last frame: emit a TEXT keepalive
    # every _KEEPALIVE_INTERVAL until the bridge ends.
    ka_stop = threading.Event()

    def _keepalive():
        while not ka_stop.wait(_KEEPALIVE_INTERVAL):
            try:
                ws_io.send_keepalive()
            except Exception:  # noqa: BLE001 — socket gone; bridge will end
                return

    threading.Thread(target=_keepalive, daemon=True, name="relay-keepalive").start()
    try:
        bridge(_StdIO(), ws_io)
    finally:
        ka_stop.set()
        try:
            sock.close()
        except OSError:
            pass
    return 0
