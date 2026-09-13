"""The proxy resumes TLS sessions upstream instead of a full handshake each time.

Every request through the loopback proxy dials the gateway afresh. It used to
build a brand-new SSLContext for each one, so no session could ever be resumed.
Pinning must hold on a resumed session exactly as on a full one.
"""
from __future__ import annotations

import types

from jc_client import _proxy


class _FakeTLS:
    def __init__(self, session):
        self.given_session = session
        self.session = object()          # the ticket this connection earned
        self.closed = False

    def setsockopt(self, *a): pass
    def settimeout(self, *a): pass
    def close(self): self.closed = True


class _FakeCtx:
    def __init__(self):
        self.wraps = []

    def wrap_socket(self, sock, server_hostname=None, session=None):
        tls = _FakeTLS(session)
        self.wraps.append((server_hostname, session))
        return tls


def _proxy_with_fakes(monkeypatch):
    ctxs = []

    def make_ctx():
        ctx = _FakeCtx()
        ctxs.append(ctx)
        return ctx

    import jc_client.protocol as protocol
    monkeypatch.setattr(protocol, "_make_ssl_context", make_ctx)
    monkeypatch.setattr(protocol, "_verify_fingerprint", lambda sock, fp: None)
    monkeypatch.setattr(_proxy.socket, "create_connection",
                        lambda addr, timeout=None: types.SimpleNamespace(
                            setsockopt=lambda *a: None, settimeout=lambda *a: None))
    proxy = _proxy.PinnedProxy("https://gw.example.com", "ab:cd", "hermes_session=x")
    return proxy, ctxs


def test_one_context_is_shared_across_upstream_connections(monkeypatch):
    proxy, ctxs = _proxy_with_fakes(monkeypatch)
    proxy.connect_upstream()
    proxy.connect_upstream()
    assert len(ctxs) == 1, "a context per connection makes resumption impossible"


def test_the_next_connection_resumes_the_last_session(monkeypatch):
    proxy, ctxs = _proxy_with_fakes(monkeypatch)
    first = proxy.connect_upstream()
    assert ctxs[0].wraps[0][1] is None, "nothing to resume yet"
    proxy.remember_tls_session(first)
    proxy.connect_upstream()
    assert ctxs[0].wraps[1][1] is first.session


def test_pinning_still_runs_on_a_resumed_connection(monkeypatch):
    proxy, _ = _proxy_with_fakes(monkeypatch)
    checked = []
    import jc_client.protocol as protocol
    monkeypatch.setattr(protocol, "_verify_fingerprint", lambda sock, fp: checked.append(fp))
    proxy.remember_tls_session(proxy.connect_upstream())
    proxy.connect_upstream()
    assert checked == ["ab:cd", "ab:cd"]


def test_a_session_is_never_offered_to_a_different_host(monkeypatch):
    proxy, ctxs = _proxy_with_fakes(monkeypatch)
    proxy.remember_tls_session(proxy.connect_upstream())
    monkeypatch.setattr(proxy, "_pick_upstream", lambda: ("lan.local", 8443, "https"))
    proxy.connect_upstream()
    assert ctxs[0].wraps[-1] == ("lan.local", None)
