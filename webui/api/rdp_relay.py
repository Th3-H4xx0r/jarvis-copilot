"""The iPhone's Remote Desktop transport (plan 2026-11-15-remote-desktop, Task 3).

``wss://<host>/api/rdp/relay/<session_id>`` carries binary frames byte-for-byte to TCP on the PC's
Tailscale address, port 3389. RDP's own TLS (and NLA) run end to end between the phone's FreeRDP
and Windows: the server never parses or decrypts anything.

Rules: only a session with ``client == "ios"`` in state ``approved`` opens it, and only once (it
becomes ``connected``); the target is the session's PC on 3389 — the client can't choose — and must
be a Tailscale address (100.64.0.0/10); the relay registers with the session so Disconnect, the idle
sweep and switching the integration off close it at once.

Like the coding-sync relay (api/tcp_relay.py) the server sends a tiny TEXT frame ("k") every few
seconds: the proxy chain holds the last frame of a quiet WebSocket until its idle reap, which would
stall RDP. Clients ignore text frames; the RDP stream is binary only.
"""
from __future__ import annotations

import ipaddress
import logging
import re
import socket
import threading
import time
from typing import Callable, Optional

from api.tcp_relay import Channel, SocketChannel, WsSocketChannel, relay_pump

log = logging.getLogger(__name__)

RDP_PORT = 3389
TAILSCALE = ipaddress.ip_network("100.64.0.0/10")
CONNECT_TIMEOUT = 10.0
KEEPALIVE_S = 3.0
_PATH = re.compile(r"^/api/rdp/relay/([A-Za-z0-9_-]{8,64})$")


def session_id_of(path: str) -> Optional[str]:
    m = _PATH.match(path or "")
    return m.group(1) if m else None


def _tailscale(host: str) -> bool:
    try:
        return ipaddress.ip_address(host) in TAILSCALE
    except ValueError:
        return False


def admit(sid: str, store) -> tuple:
    """``(session, "")`` once an approved iPhone session takes its one connection, else ``(None, why)``."""
    sess = store.get(sid)
    if sess is None:
        return None, "No such Remote Desktop session"
    if sess.client != "ios":
        return None, "This session isn't for the iPhone"
    if sess.state != "approved":
        return None, {"approving": "Waiting for Face ID", "connected": "This session is already connected"}.get(
            sess.state, "This session has ended")
    if not _tailscale(sess.host):
        log.warning("rdp relay %s refused: target %s is not a Tailscale address", sid, sess.host)
        store.end(sid, "bad target")
        return None, "The PC's address isn't a Tailscale address"
    got = store.mark_connected(sid)
    if got is None:
        return None, "This session is already connected"
    return got, ""


class _Touching(Channel):
    """Marks the session active when bytes flow (at most once a second), so the idle sweep spares it."""

    def __init__(self, inner: Channel, touch: Callable[[], None]):
        self._inner = inner
        self._touch = touch
        self._last = 0.0

    def recv(self):
        data = self._inner.recv()
        if data:
            now = time.monotonic()
            if now - self._last > 1.0:
                self._last = now
                try:
                    self._touch()
                except Exception:  # noqa: BLE001
                    pass
        return data

    def send(self, data: bytes) -> None:
        self._inner.send(data)

    def close(self) -> None:
        self._inner.close()


def run(sess, client: Channel, store, connect: Callable = socket.create_connection) -> None:
    """Pump the admitted session's bytes to its PC until either side closes, then end the session."""
    sid = sess.id
    try:
        tcp = connect((sess.host, RDP_PORT), timeout=CONNECT_TIMEOUT)
        tcp.settimeout(None)
    except OSError as exc:
        log.warning("rdp relay %s: can't reach the PC (%s)", sid, exc)
        client.close()
        store.end(sid, "pc unreachable")
        return
    pc = SocketChannel(tcp)

    def close_both():
        for ch in (client, pc):
            try:
                ch.close()
            except Exception:  # noqa: BLE001
                pass

    if not store.attach(sid, close_both):     # ended or switched off in the meantime
        close_both()
        return
    log.info("rdp relay %s open to the PC", sid)
    try:
        relay_pump(_Touching(client, lambda: store.touch(sid)), _Touching(pc, lambda: store.touch(sid)),
                   labels=("phone2pc", "pc2phone"))
    finally:
        store.end(sid, "disconnected")
        log.info("rdp relay %s closed", sid)


def handle_websocket(handler, parsed) -> bool:
    """server.do_GET's WebSocket dispatch: claims /api/rdp/relay/<id> (True), else False."""
    sid = session_id_of(parsed.path)
    if sid is None:
        return False
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
        import json
        ws_upgrade.reply(handler, 403, json.dumps({"error": why}).encode())
        return True
    upgraded = ws_upgrade.accept(handler)
    if upgraded is None:
        store.end(sid, "upgrade failed")
        return True
    ws, sock = upgraded
    client = WsSocketChannel(sock, ws)
    stop = threading.Event()

    def keepalive():
        while not stop.wait(KEEPALIVE_S):
            try:
                client.send_keepalive()
            except Exception:  # noqa: BLE001 — gone; the pump tears down
                return

    threading.Thread(target=keepalive, daemon=True, name="rdp-relay-keepalive").start()
    try:
        run(sess, client, store)
    finally:
        stop.set()
    return True
