from __future__ import annotations
import http.client
import importlib, json, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "webui"))


class FakeHandler:
    def __init__(self):
        self.status=None
        self.headers=http.client.HTTPMessage()  # request headers (empty → no gzip)
        self._sent=[]                            # collected response headers
        self.wbuf=[]
    def send_response(self,c): self.status=c
    def send_header(self,k,v): self._sent.append((k,v))
    def end_headers(self): pass
    @property
    def wfile(self):
        h=self
        class W:
            def write(self,b): h.wbuf.append(b)
        return W()


def _routes(monkeypatch, tmp_path):
    from api import routes
    importlib.reload(routes)
    # The handlers resolve the code-memory home via routes._code_mem_home(); patch it.
    monkeypatch.setattr(routes, "_code_mem_home", lambda: tmp_path)
    return routes


def _json(h):
    return json.loads(b"".join(h.wbuf).decode("utf-8"))


def test_register_then_read_roundtrip(monkeypatch, tmp_path):
    routes = _routes(monkeypatch, tmp_path)
    h = FakeHandler()
    routes._handle_code_memory_register(h, {"slug": "s1", "name": "b", "root": "/r", "remote": "https://x/a/b.git"})
    assert _json(h)["ok"] is True
    h2 = FakeHandler()
    routes._handle_code_memory_write(h2, {"slug": "s1", "kind": "knowledge", "entry_type": "bug", "content": "boom"})
    assert _json(h2)["ok"] is True
    from urllib.parse import urlparse
    h3 = FakeHandler()
    routes._handle_code_memory_read(h3, urlparse("/api/code-memory?project=s1&kind=knowledge"))
    rows = _json(h3)["entries"]
    assert rows[0]["content"] == "boom"


def test_write_requires_fields(monkeypatch, tmp_path):
    routes = _routes(monkeypatch, tmp_path)
    h = FakeHandler()
    routes._handle_code_memory_write(h, {"slug": "s1"})
    assert h.status == 400


def test_projects_lists_registered(monkeypatch, tmp_path):
    routes = _routes(monkeypatch, tmp_path)
    h = FakeHandler()
    routes._handle_code_memory_register(h, {"slug": "s2", "name": "n", "root": "/r"})
    h2 = FakeHandler()
    routes._handle_code_memory_projects(h2)
    assert "s2" in _json(h2)["projects"]


def _write(routes, slug, etype, content, kind="knowledge"):
    h = FakeHandler()
    routes._handle_code_memory_write(h, {"slug": slug, "kind": kind, "entry_type": etype, "content": content})
    return _json(h)


def test_search_returns_compact_rows_then_entries_returns_bodies(monkeypatch, tmp_path):
    from urllib.parse import urlparse
    routes = _routes(monkeypatch, tmp_path)
    _write(routes, "s1", "bug", "null deref in foo()")
    _write(routes, "s1", "fix", "guard foo() with None check")
    _write(routes, "s1", "decision", "unrelated architecture note")
    # search ranks the foo() entries; rows are compact (no bodies)
    hs = FakeHandler()
    routes._handle_code_memory_search(hs, urlparse("/api/code-memory/search?project=s1&kind=knowledge&q=foo"))
    rows = _json(hs)["entries"]
    assert {r["entry_type"] for r in rows} == {"bug", "fix"}
    assert all("content" not in r and "body" not in r for r in rows)
    # fetch full bodies by id
    ids = ",".join(r["id"] for r in rows)
    he = FakeHandler()
    routes._handle_code_memory_entries(he, urlparse("/api/code-memory/entries?ids=" + ids))
    bodies = _json(he)["entries"]
    assert any("null deref" in b["content"] for b in bodies)


def test_search_requires_project(monkeypatch, tmp_path):
    from urllib.parse import urlparse
    routes = _routes(monkeypatch, tmp_path)
    h = FakeHandler()
    routes._handle_code_memory_search(h, urlparse("/api/code-memory/search?kind=knowledge"))
    assert h.status == 400


def test_digest_endpoint(monkeypatch, tmp_path):
    from urllib.parse import urlparse
    routes = _routes(monkeypatch, tmp_path)
    _write(routes, "s1", "gotcha", "watch out for the silent filter")
    _write(routes, "s1", "claude", "did X; open Y", kind="sessions")
    h = FakeHandler()
    routes._handle_code_memory_digest(h, urlparse("/api/code-memory/digest?project=s1"))
    d = _json(h)["digest"]
    assert "1 knowledge" in d and "1 handoffs" in d


def test_projects_counts_match_writes(monkeypatch, tmp_path):
    routes = _routes(monkeypatch, tmp_path)
    _write(routes, "s3", "bug", "a")
    _write(routes, "s3", "fix", "b")
    h = FakeHandler()
    routes._handle_code_memory_projects(h)
    meta = _json(h)["projects"]["s3"]
    assert meta["knowledge_count"] == 2 and meta["sessions_count"] == 0


def test_read_returns_ids_then_update_and_delete_by_id(monkeypatch, tmp_path):
    from urllib.parse import urlparse
    routes = _routes(monkeypatch, tmp_path)
    _write(routes, "s4", "bug", "original")
    hr = FakeHandler()
    routes._handle_code_memory_read(hr, urlparse("/api/code-memory?project=s4&kind=knowledge"))
    row = _json(hr)["entries"][0]
    assert row["id"].startswith("s4::knowledge::")
    # edit in place
    hu = FakeHandler()
    routes._handle_code_memory_update(hu, {"id": row["id"], "content": "edited", "entry_type": "fix"})
    assert _json(hu)["ok"] is True
    hr2 = FakeHandler()
    routes._handle_code_memory_read(hr2, urlparse("/api/code-memory?project=s4&kind=knowledge"))
    edited = _json(hr2)["entries"][0]
    assert edited["content"] == "edited" and edited["entry_type"] == "fix"
    # delete by id
    hd = FakeHandler()
    routes._handle_code_memory_delete_entry(hd, {"id": edited["id"]})
    assert _json(hd)["ok"] is True
    hr3 = FakeHandler()
    routes._handle_code_memory_read(hr3, urlparse("/api/code-memory?project=s4&kind=knowledge"))
    assert _json(hr3)["entries"] == []


def test_update_requires_id_and_content(monkeypatch, tmp_path):
    routes = _routes(monkeypatch, tmp_path)
    h = FakeHandler()
    routes._handle_code_memory_update(h, {"id": "x"})
    assert h.status == 400
