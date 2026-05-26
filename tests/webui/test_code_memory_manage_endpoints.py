from __future__ import annotations
import http.client, importlib, json, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "webui"))


class FakeHandler:
    def __init__(self):
        self.status=None; self.headers=http.client.HTTPMessage(); self._sent=[]; self.wbuf=[]
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
    monkeypatch.setattr(routes, "_code_mem_home", lambda: tmp_path)
    return routes


def _json(h): return json.loads(b"".join(h.wbuf).decode("utf-8"))


def test_projects_listing_has_counts(monkeypatch, tmp_path):
    routes = _routes(monkeypatch, tmp_path)
    from agent import code_memory as cm
    cm.register_project("s1", "s1", "/r", "", home=tmp_path)
    cm.write_entry("s1", "knowledge", "bug", "x", home=tmp_path)
    h = FakeHandler(); routes._handle_code_memory_projects(h)
    p = _json(h)["projects"]["s1"]
    assert p["knowledge_count"] == 1 and p["sessions_count"] == 0


def test_stats_endpoint(monkeypatch, tmp_path):
    routes = _routes(monkeypatch, tmp_path)
    from agent import code_memory as cm
    cm.write_entry("s1", "knowledge", "bug", "x", home=tmp_path)
    h = FakeHandler(); routes._handle_code_memory_stats(h)
    s = _json(h)
    assert s["knowledge"] == 1 and "by_type" in s


def test_delete_entry_endpoint(monkeypatch, tmp_path):
    routes = _routes(monkeypatch, tmp_path)
    from agent import code_memory as cm
    meta = cm.write_entry("s1", "knowledge", "bug", "x", home=tmp_path)
    h = FakeHandler()
    routes._handle_code_memory_delete_entry(h, {"slug": "s1", "kind": "knowledge", "ts": meta["ts"]})
    assert _json(h)["removed"] == 1
    assert cm.read_entries("s1", "knowledge", home=tmp_path) == []


def test_delete_project_endpoint(monkeypatch, tmp_path):
    routes = _routes(monkeypatch, tmp_path)
    from agent import code_memory as cm
    cm.register_project("s1", "s1", "/r", "", home=tmp_path)
    h = FakeHandler(); routes._handle_code_memory_delete(h, {"slug": "s1"})
    assert _json(h)["ok"] is True
    assert "s1" not in cm.list_projects(home=tmp_path)


def test_delete_entry_requires_fields(monkeypatch, tmp_path):
    routes = _routes(monkeypatch, tmp_path)
    h = FakeHandler(); routes._handle_code_memory_delete_entry(h, {"slug": "s1"})
    assert h.status == 400
