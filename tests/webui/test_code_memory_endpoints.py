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
