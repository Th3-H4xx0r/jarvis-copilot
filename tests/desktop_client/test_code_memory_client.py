from __future__ import annotations
import importlib, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "desktop_client"))


class _Resp:
    def __init__(self, status=200, data=None): self.status=status; self._d=data or {}
    def json(self): return self._d


def _client(monkeypatch):
    from jc_client import code_memory_client as c
    importlib.reload(c)
    calls = []

    class FakeHttp:
        def __init__(self, *a, **k): pass
        def request_json(self, method, path, body=None):
            calls.append((method, path, body))
            if path.startswith("/api/code-memory?"): return _Resp(200, {"entries": [{"content": "x"}]})
            return _Resp(200, {"ok": True})

    monkeypatch.setattr(c, "HttpClient", FakeHttp)
    class Creds:
        server_url="https://h:8787"; cookie="hermes_session=a"; cert_fingerprint="fp"
        @property
        def paired(self): return True
    monkeypatch.setattr(c.credentials, "load", lambda: Creds())
    return c, calls


def test_slug_from_remote():
    from jc_client import code_memory_client as c
    importlib.reload(c)
    assert c.slug_for("/x", "https://github.com/a/b.git") == "github.com_a_b"

def test_slug_from_ssh_remote():
    from jc_client import code_memory_client as c
    importlib.reload(c)
    assert c.slug_for("/x", "git@github.com:a/b.git") == "github.com_a_b"

def test_slug_dir_fallback_spaces_to_hyphen():
    from jc_client import code_memory_client as c
    importlib.reload(c)
    assert c.slug_for("/Users/me/My Project", None) == "my-project"

def test_store_posts_write(monkeypatch):
    c, calls = _client(monkeypatch)
    c.store("s1", "knowledge", "bug", "boom")
    assert ("POST", "/api/code-memory/write", {"slug": "s1", "kind": "knowledge",
            "entry_type": "bug", "content": "boom"}) in calls

def test_recall_gets_entries(monkeypatch):
    c, calls = _client(monkeypatch)
    rows = c.recall("s1", "knowledge", limit=5)
    assert rows == [{"content": "x"}]
    assert calls[0][0] == "GET" and "/api/code-memory?project=s1&kind=knowledge&limit=5" == calls[0][1]

def test_unpaired_raises(monkeypatch):
    from jc_client import code_memory_client as c
    importlib.reload(c)
    class Creds:
        server_url=""; cookie=""; cert_fingerprint=""
        @property
        def paired(self): return False
    monkeypatch.setattr(c.credentials, "load", lambda: Creds())
    import pytest
    with pytest.raises(c.NotPaired):
        c.store("s", "knowledge", "bug", "x")
