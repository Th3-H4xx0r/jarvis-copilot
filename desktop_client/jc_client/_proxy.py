"""Loopback pinned reverse proxy.

The WebView / TUI loads http://127.0.0.1:<port> (no TLS, no cert problem) and
this forwards every request — including WebSocket upgrades (raw byte relay) — to
the configured server over the client's pinned-TLS socket, injecting the session
cookie. The gateway uses a self-signed cert the client trusts by fingerprint
pinning at the socket layer, which a browser/WebView/Node WS client can't
validate; routing through this proxy sidesteps that.

Bound to 127.0.0.1 ONLY: it speaks for an authenticated session, so it must
never be reachable from off-host.

Shared by voice_popup (orb HUD) and tui_launcher (terminal UI).
"""
from __future__ import annotations

import logging
import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

logger = logging.getLogger(__name__)

_RECV = 65536

# Headers we must not blindly forward. Host and Cookie are dropped here and
# re-set by the proxy; Upgrade/Connection are re-emitted for WebSocket upgrades.
# Origin/Referer are dropped because the page's origin is the loopback proxy
# (http://127.0.0.1:<port>), which wouldn't match the server's Host — the
# webui's CSRF check rejects that cross-origin mismatch on POSTs. Stripping them
# makes the server treat this trusted loopback forwarder like a non-browser
# client (curl/agent) and allow the request (see routes._check_csrf).
_DROP_HEADERS = frozenset({
    "host", "cookie", "connection", "proxy-connection", "keep-alive",
    "transfer-encoding", "te", "trailer", "upgrade", "origin", "referer",
})


def _split_server_url(url: str):
    """(host, port, scheme, path_prefix) for the configured server URL.

    Mirrors protocol._split_url but without importing protocol at module load
    (that pulls wsproto). Strips the prefix's trailing slash so paths concat
    cleanly."""
    p = urlparse(url)
    if p.scheme not in ("http", "https"):
        raise ValueError(f"unsupported scheme: {p.scheme!r}")
    host = p.hostname or ""
    if not host:
        raise ValueError(f"missing host in URL: {url!r}")
    port = p.port or (443 if p.scheme == "https" else 80)
    return host, port, p.scheme, (p.path or "").rstrip("/")


def build_upstream_head(command, path, headers, cookie, host, port, is_ws):
    """Reconstruct the upstream request head: rewrite Host, inject the session
    Cookie, drop hop-by-hop headers, and force Connection: close (or re-add the
    WebSocket upgrade headers). Returns bytes (no body)."""
    lines = [f"{command} {path} HTTP/1.1"]
    for key in headers.keys():
        if key.lower() in _DROP_HEADERS:
            continue
        for value in headers.get_all(key, []):
            lines.append(f"{key}: {value}")
    lines.append(f"Host: {host}:{port}")
    # creds.cookie is stored as the full "hermes_session=<value>" string (that's
    # what HttpResponse.cookie returns and what the headless client sends
    # verbatim), so don't re-prefix it — that would produce an invalid
    # "hermes_session=hermes_session=…" and the webui would bounce us to /pair.
    cookie_header = cookie if cookie.lower().startswith("hermes_session=") else f"hermes_session={cookie}"
    lines.append(f"Cookie: {cookie_header}")
    if is_ws:
        lines.append("Connection: Upgrade")
        lines.append("Upgrade: websocket")
    else:
        lines.append("Connection: close")
    return ("\r\n".join(lines) + "\r\n\r\n").encode("iso-8859-1")


class _ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_a):  # quiet
        pass

    def _do(self):
        proxy = self.server.proxy  # type: ignore[attr-defined]
        self.close_connection = True
        is_ws = self.headers.get("Upgrade", "").lower() == "websocket"
        path = proxy.prefix + self.path

        body = b""
        clen = self.headers.get("Content-Length")
        if clen:
            try:
                body = self.rfile.read(int(clen))
            except Exception:
                body = b""

        try:
            up = proxy.connect_upstream()
        except Exception as exc:
            msg = f"jc-client proxy: upstream connect failed: {exc}".encode()
            try:
                self.send_response(502)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(msg)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(msg)
            except Exception:
                pass
            return

        try:
            up.sendall(build_upstream_head(
                self.command, path, self.headers, proxy.cookie, proxy.host, proxy.port, is_ws,
            ) + body)
            if is_ws:
                self._relay(up)
            else:
                self._shovel(up)
        except OSError:
            pass
        finally:
            try:
                up.close()
            except OSError:
                pass

    # All methods funnel through the same transparent proxy.
    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = do_OPTIONS = do_PATCH = _do

    def _shovel(self, up):
        """Relay the upstream response verbatim to the browser until EOF
        (upstream got Connection: close, so EOF == end of response)."""
        conn = self.connection
        while True:
            chunk = up.recv(_RECV)
            if not chunk:
                break
            conn.sendall(chunk)

    def _relay(self, up):
        """Bidirectional byte relay for a WebSocket: browser(plaintext ws) <->
        server(pinned wss). WS frames are opaque bytes, so a raw relay works."""
        client_read = self.rfile      # holds any bytes buffered past the headers
        client_sock = self.connection

        def pump_up_to_client():
            try:
                while True:
                    data = up.recv(_RECV)
                    if not data:
                        break
                    client_sock.sendall(data)
            except OSError:
                pass
            finally:
                try:
                    client_sock.shutdown(socket.SHUT_WR)
                except OSError:
                    pass

        t = threading.Thread(target=pump_up_to_client, daemon=True)
        t.start()
        try:
            while True:
                data = client_read.read1(_RECV)
                if not data:
                    break
                up.sendall(data)
        except OSError:
            pass
        finally:
            try:
                up.shutdown(socket.SHUT_WR)
            except OSError:
                pass
        t.join(timeout=1)


class PinnedProxy:
    """Localhost HTTP/WS reverse proxy → the pinned-TLS gateway."""

    def __init__(self, server_url: str, fingerprint: str, cookie: str):
        self.host, self.port, self.scheme, self.prefix = _split_server_url(server_url)
        self.fingerprint = fingerprint
        self.cookie = cookie
        self._httpd = None
        self._thread = None

    def connect_upstream(self):
        # Lazy import: protocol pulls wsproto, which we don't want at module load.
        from jc_client.protocol import _make_ssl_context, _verify_fingerprint
        sock = socket.create_connection((self.host, self.port), timeout=15)
        if self.scheme == "https":
            ctx = _make_ssl_context()
            sock = ctx.wrap_socket(sock, server_hostname=self.host)
            _verify_fingerprint(sock, self.fingerprint)
        sock.settimeout(None)  # long-lived (WS); rely on peer close
        return sock

    def start(self) -> int:
        """Start serving on an ephemeral 127.0.0.1 port; return the port."""
        self._httpd = ThreadingHTTPServer(("127.0.0.1", 0), _ProxyHandler)
        self._httpd.daemon_threads = True
        self._httpd.proxy = self  # type: ignore[attr-defined]
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)
        self._thread.start()
        return self._httpd.server_address[1]

    def wait(self):
        if self._thread:
            self._thread.join()

    def shutdown(self):
        if self._httpd:
            try:
                self._httpd.shutdown()
            except Exception:
                pass
