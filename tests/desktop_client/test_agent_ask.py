"""Task 7b: `ask` / `run_skill` — one-shot agent turn via session + /api/btw + SSE."""
from __future__ import annotations

import importlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "desktop_client"))


class _Resp:
    def __init__(self, status=200, data=None):
        self.status = status
        self._d = data or {}
    def json(self):
        return self._d


class _PairedCreds:
    server_url = "https://hermes:8787"
    cookie = "hermes_session=a"
    cert_fingerprint = "fp"
    @property
    def paired(self):
        return True


# ── protocol.HttpClient.get_sse_event ──────────────────────────────────────

def test_get_sse_event_returns_matching_event(monkeypatch):
    from jc_client import protocol
    importlib.reload(protocol)
    sse = (b"HTTP/1.0 200 OK\r\nContent-Type: text/event-stream\r\n\r\n"
           b"event: token\ndata: {\"t\": \"hi\"}\n\n"
           b"event: done\ndata: {\"answer\": \"42\"}\n\n")

    class FakeSock:
        def __init__(self): self.sent = []; self._chunks = [sse, b""]
        def settimeout(self, t): pass
        def sendall(self, b): self.sent.append(b)
        def recv(self, n): return self._chunks.pop(0) if self._chunks else b""
        def close(self): pass

    c = protocol.HttpClient("https://h:8787", cookie="hermes_session=a", expected_fingerprint="x")
    fs = FakeSock()
    monkeypatch.setattr(c, "_connect", lambda: (fs, "x"))
    data = c.get_sse_event("/api/chat/stream?stream_id=abc", "done")
    assert data == {"answer": "42"}
    head = fs.sent[0].decode("latin-1")
    assert head.startswith("GET /api/chat/stream?stream_id=abc HTTP/1.1")
    assert "Cookie: hermes_session=a" in head


def test_get_sse_event_eof_without_match_returns_none(monkeypatch):
    from jc_client import protocol
    importlib.reload(protocol)
    sse = b"HTTP/1.0 200 OK\r\n\r\nevent: token\ndata: {}\n\n"

    class FakeSock:
        def __init__(self): self._chunks = [sse, b""]
        def settimeout(self, t): pass
        def sendall(self, b): pass
        def recv(self, n): return self._chunks.pop(0) if self._chunks else b""
        def close(self): pass

    c = protocol.HttpClient("https://h:8787", cookie="", expected_fingerprint="x")
    monkeypatch.setattr(c, "_connect", lambda: (FakeSock(), "x"))
    assert c.get_sse_event("/x", "done") is None


# ── code_memory_client.ask_agent ───────────────────────────────────────────

def _client(monkeypatch, answer="the answer"):
    from jc_client import code_memory_client as c
    importlib.reload(c)
    calls = []

    class FakeHttp:
        def __init__(self, *a, **k): pass
        def request_json(self, method, path, body=None):
            calls.append((method, path, body))
            if path == "/api/session/new":
                return _Resp(200, {"session": {"session_id": "SID"}})
            if path == "/api/btw":
                return _Resp(200, {"stream_id": "STR"})
            return _Resp(200, {})
        def get_sse_event(self, path, event_name, timeout=180.0):
            calls.append(("SSE", path, event_name))
            return {"answer": answer}

    monkeypatch.setattr(c, "HttpClient", FakeHttp)
    monkeypatch.setattr(c.credentials, "load", lambda: _PairedCreds())
    return c, calls


def test_ask_agent_session_btw_sse_roundtrip(monkeypatch):
    c, calls = _client(monkeypatch)
    out = c.ask_agent("what is 6x7?")
    assert out == "the answer"
    assert ("POST", "/api/session/new", {}) in calls
    assert ("POST", "/api/btw", {"session_id": "SID", "question": "what is 6x7?"}) in calls
    assert ("SSE", "/api/chat/stream?stream_id=STR", "done") in calls


def test_ask_agent_skill_prefixes_prompt(monkeypatch):
    c, calls = _client(monkeypatch)
    c.ask_agent("the input", skill="research")
    btw = next(b for (m, p, b) in calls if p == "/api/btw")
    assert btw["question"].startswith("Use the research skill")
    assert "the input" in btw["question"]


def test_ask_agent_unpaired_raises(monkeypatch):
    from jc_client import code_memory_client as c
    importlib.reload(c)
    class Creds:
        server_url = ""; cookie = ""; cert_fingerprint = ""
        @property
        def paired(self): return False
    monkeypatch.setattr(c.credentials, "load", lambda: Creds())
    import pytest
    with pytest.raises(c.NotPaired):
        c.ask_agent("q")


# ── mcp_server ask / run_skill tools ───────────────────────────────────────

def test_mcp_ask_and_run_skill(monkeypatch):
    from jc_client import mcp_server as m
    importlib.reload(m)
    monkeypatch.setattr(m.cmc, "ask_agent", lambda q, skill=None: f"A:{skill}:{q}")
    assert m._ask("hi") == "A:None:hi"
    assert m._run_skill("research", "topic") == "A:research:topic"


def test_mcp_ask_unpaired_tool_error(monkeypatch):
    from jc_client import mcp_server as m, code_memory_client as cmc
    importlib.reload(m)
    def boom(*a, **k): raise cmc.NotPaired("nope")
    monkeypatch.setattr(m.cmc, "ask_agent", boom)
    assert "nope" in m._ask("hi")
