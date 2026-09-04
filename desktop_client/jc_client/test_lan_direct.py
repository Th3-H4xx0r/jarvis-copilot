"""Tests for the LAN-direct connection preference (plan 5.3).

Clients race a fast pinned health probe against an optional ``lan_url``
before falling back to the tunnel ``server_url``. Covers:

- ``protocol.probe_lan`` against a real loopback TCP server (plain HTTP, no
  TLS, so no cert fixtures needed) for the happy path, a refused connection,
  and a timeout.
- ``service._pick_server_url``, which decides which url a reconnect uses.
- ``_proxy.PinnedProxy._pick_upstream``, which applies the same preference
  to the loopback proxy's upstream, with its probe-result cache.

Run from the ``desktop_client`` directory:
    python3 -m pytest jc_client/test_lan_direct.py -q
"""
from __future__ import annotations

import socket
import threading
import time

import pytest

from jc_client import credentials, service
from jc_client._proxy import PinnedProxy
from jc_client.protocol import probe_lan


def _serve_once(sock: socket.socket, response: bytes | None, delay: float = 0.0):
    """Accept one connection, optionally stall, then send `response` (or
    nothing) and close. Runs in a background thread."""
    def _run():
        try:
            sock.settimeout(5.0)
            conn, _ = sock.accept()
        except OSError:
            return
        try:
            if delay:
                time.sleep(delay)
            if response is not None:
                conn.recv(4096)
                conn.sendall(response)
        except OSError:
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass
    t = threading.Thread(target=_run, daemon=True)
    t.start()
    return t


def _free_port() -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


@pytest.fixture
def health_server():
    """A loopback server that answers 200 to /health, plain HTTP (no
    TLS) so probe_lan's fingerprint check is skipped via expected_fp="")."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", 0))
    sock.listen(1)
    port = sock.getsockname()[1]
    resp = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
    _serve_once(sock, resp)
    yield f"http://127.0.0.1:{port}"
    sock.close()


def _serve_path_aware(sock: socket.socket, ok_path: str = "/health"):
    """Accept one connection, parse the request line, and answer 200 only
    for ``ok_path`` — 404 for anything else (mirrors the real webui, which
    serves the bare ``/health`` route but not ``/api/health``, see
    webui/api/routes.py's ``handle_get`` dispatch). Runs in a background
    thread."""
    def _run():
        try:
            sock.settimeout(5.0)
            conn, _ = sock.accept()
        except OSError:
            return
        try:
            conn.settimeout(5.0)
            raw = conn.recv(4096)
            request_line = raw.split(b"\r\n", 1)[0].decode("ascii", "replace")
            # "GET /health HTTP/1.1" -> "/health"
            path = request_line.split(" ")[1] if " " in request_line else ""
            if path == ok_path:
                conn.sendall(
                    b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
            else:
                conn.sendall(
                    b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        except OSError:
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass
    t = threading.Thread(target=_run, daemon=True)
    t.start()
    return t


@pytest.fixture
def health_only_server():
    """A loopback server that ONLY answers 200 to ``/health`` and 404s
    everything else (including ``/api/health``) — a stand-in for the real
    webui, which registers just the bare ``/health`` route
    (webui/api/routes.py, dispatched from webui/server.py's ``do_GET``)."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", 0))
    sock.listen(1)
    port = sock.getsockname()[1]
    _serve_path_aware(sock, ok_path="/health")
    yield f"http://127.0.0.1:{port}"
    sock.close()


class TestProbeLan:
    def test_empty_url_is_false(self):
        assert probe_lan("") is False

    def test_malformed_url_is_false(self):
        assert probe_lan("not-a-url") is False

    def test_reachable_health_endpoint_is_true(self, health_server):
        assert probe_lan(health_server, timeout=1.0) is True

    def test_probes_bare_health_not_api_health(self, health_only_server):
        """Regression for the CRITICAL finding: probe_lan used to request
        ``GET {prefix}/api/health``, but the server only serves the bare
        ``/health`` (webui/api/routes.py's dispatch, called from
        webui/server.py) — so LAN-direct could never activate. Against a
        fake server that answers 200 on ``/health`` and 404s
        ``/api/health``, probe_lan must report reachable."""
        assert probe_lan(health_only_server, timeout=1.0) is True

    def test_connection_refused_is_false(self):
        port = _free_port()  # nothing listening
        assert probe_lan(f"http://127.0.0.1:{port}", timeout=0.3) is False

    def test_slow_server_times_out_false(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("127.0.0.1", 0))
        sock.listen(1)
        port = sock.getsockname()[1]
        resp = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
        _serve_once(sock, resp, delay=1.0)  # slower than our budget
        try:
            started = time.monotonic()
            result = probe_lan(f"http://127.0.0.1:{port}", timeout=0.15)
            elapsed = time.monotonic() - started
            assert result is False
            assert elapsed < 1.0
        finally:
            sock.close()


class TestPickServerUrl:
    def test_no_lan_url_uses_tunnel(self):
        creds = credentials.Credentials(server_url="https://tunnel.example:8787")
        assert service._pick_server_url(creds) == "https://tunnel.example:8787"

    def test_reachable_lan_wins(self, health_server, monkeypatch):
        monkeypatch.setattr(service, "_LAN_PROBE_TIMEOUT", 1.0)
        creds = credentials.Credentials(
            server_url="https://tunnel.example:8787", lan_url=health_server)
        assert service._pick_server_url(creds) == health_server

    def test_unreachable_lan_falls_back_to_tunnel(self):
        port = _free_port()
        creds = credentials.Credentials(
            server_url="https://tunnel.example:8787",
            lan_url=f"http://127.0.0.1:{port}",
        )
        assert service._pick_server_url(creds) == "https://tunnel.example:8787"


class TestCredentialsLanUrl:
    def test_defaults_empty(self):
        assert credentials.Credentials().lan_url == ""

    def test_round_trips_through_load_save(self, tmp_path, monkeypatch):
        cfg = tmp_path / "config.yaml"
        monkeypatch.setattr(credentials, "_CONFIG_FILE", cfg)
        monkeypatch.setattr(credentials, "_try_keyring_get", lambda: None)
        monkeypatch.setattr(credentials, "_try_keyring_set", lambda v: False)
        monkeypatch.setattr(credentials, "_try_keyring_get_user", lambda u: None)
        monkeypatch.setattr(credentials, "_try_keyring_set_user", lambda u, v: False)

        creds = credentials.Credentials(
            server_url="https://tunnel.example:8787",
            lan_url="https://192.168.1.20:8787",
            cert_fingerprint="deadbeef",
        )
        credentials.save(creds)
        loaded = credentials.load()
        assert loaded.lan_url == "https://192.168.1.20:8787"


class TestPinnedProxyLanPreference:
    def test_no_lan_url_uses_server(self):
        proxy = PinnedProxy("https://tunnel.example:8787", "fp", "cookie")
        assert proxy._pick_upstream() == ("tunnel.example", 8787, "https")

    def test_bad_lan_url_ignored(self, caplog):
        proxy = PinnedProxy(
            "https://tunnel.example:8787", "fp", "cookie", lan_url="not-a-url")
        assert proxy.lan_url == ""
        assert proxy._pick_upstream() == ("tunnel.example", 8787, "https")

    def test_reachable_lan_preferred_and_cached(self, health_server, monkeypatch):
        import jc_client._proxy as proxy_mod
        monkeypatch.setattr(proxy_mod, "_LAN_PROBE_CACHE_TTL", 60.0)
        proxy = PinnedProxy(
            "https://tunnel.example:8787", "", "cookie", lan_url=health_server)
        host, port, scheme = proxy._pick_upstream()
        assert (host, port, scheme) == ("127.0.0.1", int(health_server.rsplit(":", 1)[1]), "http")
        # Cached: a second call must not re-probe (the fixture's server only
        # accepts one connection) — it should still report LAN-ok.
        assert proxy._pick_upstream() == (host, port, scheme)

    def test_unreachable_lan_falls_back_and_reprobes_after_ttl(self, monkeypatch):
        import jc_client._proxy as proxy_mod
        monkeypatch.setattr(proxy_mod, "_LAN_PROBE_CACHE_TTL", 0.0)
        port = _free_port()
        proxy = PinnedProxy(
            "https://tunnel.example:8787", "fp", "cookie",
            lan_url=f"http://127.0.0.1:{port}")
        assert proxy._pick_upstream() == ("tunnel.example", 8787, "https")


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
