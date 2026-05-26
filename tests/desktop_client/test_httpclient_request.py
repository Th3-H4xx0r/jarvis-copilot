from __future__ import annotations
import importlib, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "desktop_client"))


def test_request_json_builds_get_without_body(monkeypatch):
    from jc_client import protocol
    importlib.reload(protocol)
    sent = {}

    class FakeSock:
        def sendall(self, b): sent["req"] = b
        def recv(self, n):
            if sent.get("done"): return b""
            sent["done"] = True
            return b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"entries\":[]}"
        def close(self): pass

    c = protocol.HttpClient("https://h:8787", cookie="hermes_session=abc", expected_fingerprint="x")
    monkeypatch.setattr(c, "_connect", lambda: (FakeSock(), "x"))
    resp = c.request_json("GET", "/api/code-memory?project=s1&kind=knowledge")
    assert resp.status == 200 and resp.json() == {"entries": []}
    head = sent["req"].decode("latin-1")
    assert head.startswith("GET /api/code-memory?project=s1&kind=knowledge HTTP/1.1")
    assert "Cookie: hermes_session=abc" in head
    assert "Content-Length" not in head  # no body on GET


def test_request_json_post_has_body_and_content_length(monkeypatch):
    from jc_client import protocol
    importlib.reload(protocol)
    sent = {}

    class FakeSock:
        def sendall(self, b): sent["req"] = b
        def recv(self, n):
            if sent.get("done"): return b""
            sent["done"] = True
            return b"HTTP/1.1 200 OK\r\n\r\n{\"ok\":true}"
        def close(self): pass

    c = protocol.HttpClient("https://h:8787", cookie="hermes_session=abc", expected_fingerprint="x")
    monkeypatch.setattr(c, "_connect", lambda: (FakeSock(), "x"))
    resp = c.request_json("POST", "/api/code-memory/write", {"slug": "s1"})
    assert resp.json() == {"ok": True}
    head = sent["req"].decode("latin-1")
    assert head.startswith("POST /api/code-memory/write HTTP/1.1")
    assert "Content-Type: application/json" in head and "Content-Length:" in head
    assert head.endswith('{"slug": "s1"}')
