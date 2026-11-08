"""Turns an HTTP request already read by BaseHTTPRequestHandler into a server WebSocket, and
reads it (`serve`)."""
import logging

logger = logging.getLogger(__name__)


def reply(handler, status: int, body: bytes) -> None:
    """A small JSON refusal on a request that won't be upgraded; the client may already be gone."""
    try:
        handler.send_response(status)
        handler.send_header("Content-Type", "application/json")
        handler.end_headers()
        handler.wfile.write(body)
    except Exception:
        pass


def _raw_request(handler) -> bytes:
    """The handler has consumed the request line and headers by the time do_GET runs; wsproto's
    server state machine needs them back to answer the upgrade."""
    lines = [f"{handler.command} {handler.path} HTTP/1.1"]
    for k, v in handler.headers.items():
        lines.append(f"{k}: {v}")
    lines += ["", ""]
    return "\r\n".join(lines).encode("latin-1")


def accept(handler):
    """Accepts the upgrade: ``(conn, sock)``, or None once the request has been answered (wsproto
    missing → 503) or the client sent no valid upgrade.

    The socket goes to no read timeout: the connection is long-lived and one thread owns it, so a
    timeout would only cycle it out from under a blocking recv."""
    try:
        from wsproto import ConnectionType, WSConnection
        from wsproto.events import AcceptConnection, Request
    except Exception:
        reply(handler, 503, b'{"error":"wsproto not installed"}')
        return None
    sock = handler.connection
    try:
        sock.settimeout(None)
    except Exception:
        pass
    conn = WSConnection(ConnectionType.SERVER)
    try:
        conn.receive_data(_raw_request(handler))
    except Exception:
        return None
    for event in conn.events():
        if isinstance(event, Request):
            try:
                sock.sendall(conn.send(AcceptConnection()))
            except Exception:
                return None
            return conn, sock
    return None


def serve(conn, sock, *, on_text, on_bytes, lock, alive=None, max_message=None, chunk=8192):
    """Reads ``sock`` until the peer goes, closes, or ``alive()`` turns false: answers pings and
    the close handshake under ``lock`` (wsproto connections aren't thread-safe and other threads
    send too), and hands on each whole message. wsproto splits one message across reads and
    fragments, and only the last piece is ``message_finished``; one over ``max_message`` bytes is
    dropped. A handler's exception reaches the caller."""
    from wsproto.events import BytesMessage, CloseConnection, Ping, Pong, TextMessage

    parts = {TextMessage: [], BytesMessage: []}
    sizes = {TextMessage: 0, BytesMessage: 0}

    def answer(frame) -> bool:
        with lock:
            try:
                sock.sendall(conn.send(frame))
                return True
            except Exception:
                return False

    while alive is None or alive():
        try:
            data = sock.recv(chunk)
        except OSError:
            return
        if not data:
            return
        conn.receive_data(data)
        for event in conn.events():
            kind = type(event)
            if kind in parts:
                parts[kind].append(event.data or (b"" if kind is BytesMessage else ""))
                sizes[kind] += len(event.data or "")
                if not getattr(event, "message_finished", True):
                    continue
                pieces, size = parts[kind], sizes[kind]
                parts[kind], sizes[kind] = [], 0
                if max_message is not None and size > max_message:
                    logger.warning("WS message of %d bytes dropped (limit %d)", size, max_message)
                    continue
                whole = (b"" if kind is BytesMessage else "").join(pieces)
                (on_bytes if kind is BytesMessage else on_text)(whole)
            elif kind is Ping:
                if not answer(Pong(event.payload)):
                    return
            elif kind is CloseConnection:
                answer(event.response())
                return
