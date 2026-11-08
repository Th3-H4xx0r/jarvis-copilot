"""Turns an HTTP request already read by BaseHTTPRequestHandler into a server WebSocket."""


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
