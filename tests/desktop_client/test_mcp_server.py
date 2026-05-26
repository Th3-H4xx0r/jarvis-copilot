from __future__ import annotations
import importlib, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "desktop_client"))


def test_tool_impls_call_client(monkeypatch):
    from jc_client import mcp_server as m
    importlib.reload(m)
    calls = {}
    def fake_store(*a):
        calls["store"] = a
        return {"ok": True}
    monkeypatch.setattr(m.cmc, "current_slug", lambda root=None: "slugX")
    monkeypatch.setattr(m.cmc, "store", fake_store)
    monkeypatch.setattr(m.cmc, "recall", lambda *a, **k: [{"content": "c", "entry_type": "bug", "ts": "t"}])
    assert m._store_code_knowledge("bug", "boom", project=None)["ok"] is True
    assert calls["store"] == ("slugX", "knowledge", "bug", "boom")
    out = m._recall_code_knowledge(project="p", limit=3)
    assert "c" in out


def test_session_handoff_uses_sessions_kind(monkeypatch):
    from jc_client import mcp_server as m
    importlib.reload(m)
    calls = {}
    def fake_store(*a):
        calls["store"] = a
        return {"ok": True}
    monkeypatch.setattr(m.cmc, "current_slug", lambda root=None: "s")
    monkeypatch.setattr(m.cmc, "store", fake_store)
    m._store_session_handoff("did stuff", project=None)
    assert calls["store"] == ("s", "sessions", "claude", "did stuff")


def test_unpaired_returns_tool_error(monkeypatch):
    from jc_client import mcp_server as m, code_memory_client as cmc
    importlib.reload(m)
    def boom(*a, **k): raise cmc.NotPaired("nope")
    monkeypatch.setattr(m.cmc, "store", boom)
    monkeypatch.setattr(m.cmc, "current_slug", lambda root=None: "s")
    out = m._store_code_knowledge("bug", "x", project=None)
    assert "error" in out and "nope" in out["error"]
