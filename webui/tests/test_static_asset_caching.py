"""Static assets are compressed and cacheable instead of re-sent on every load."""
import gzip
import importlib
from urllib.parse import quote, urlparse

import api.routes as routes


class _Handler:
    def __init__(self, headers=None):
        self.status = None
        self.sent = []
        self.body = bytearray()
        self.wfile = self
        self.headers = headers or {}

    def send_response(self, status):
        self.status = status

    def send_header(self, name, value):
        self.sent.append((name, value))

    def end_headers(self):
        pass

    def write(self, data):
        self.body.extend(data)

    def header(self, name):
        return next((v for k, v in self.sent if k.lower() == name.lower()), None)


STATIC_ROOT = routes.Path(routes.__file__).resolve().parent.parent / "static"


def _set_version(monkeypatch, version):
    # Looked up at call time: other tests reload api.updates, and routes reads
    # whichever copy is in sys.modules.
    monkeypatch.setattr(importlib.import_module("api.updates"), "WEBUI_VERSION", version)


def _get(url, headers=None):
    handler = _Handler(headers)
    assert routes._serve_static(handler, urlparse(url)) is True
    return handler


def test_text_assets_are_gzipped_when_the_client_accepts_it():
    raw = (STATIC_ROOT / "messages.js").read_bytes()

    plain = _get("http://x/static/messages.js")
    zipped = _get("http://x/static/messages.js", {"Accept-Encoding": "gzip, br"})

    assert plain.header("Content-Encoding") is None
    assert bytes(plain.body) == raw
    assert zipped.header("Content-Encoding") == "gzip"
    assert zipped.header("Vary") == "Accept-Encoding"
    assert gzip.decompress(bytes(zipped.body)) == raw
    assert int(zipped.header("Content-Length")) == len(zipped.body) < len(raw) // 2


def test_current_version_urls_are_immutable_and_others_revalidate(monkeypatch):
    _set_version(monkeypatch, "abc1234")

    current = _get("http://x/static/ui.js?v=" + quote("abc1234", safe=""))
    old = _get("http://x/static/ui.js?v=old999")
    bare = _get("http://x/static/ui.js")

    assert current.header("Cache-Control") == "public, max-age=31536000, immutable"
    assert old.header("Cache-Control") == "no-cache"
    assert bare.header("Cache-Control") == "no-cache"


def test_dirty_tree_never_marks_assets_immutable(monkeypatch):
    _set_version(monkeypatch, "abc1234-dirty.1791")

    handler = _get("http://x/static/ui.js?v=abc1234-dirty.1791")

    assert handler.header("Cache-Control") == "no-cache"


def test_matching_etag_gets_an_empty_304():
    first = _get("http://x/static/style.css")
    etag = first.header("ETag")

    again = _get("http://x/static/style.css", {"If-None-Match": etag})

    assert etag and etag.startswith('W/"')
    assert again.status == 304
    assert bytes(again.body) == b""
    assert again.header("ETag") == etag


def test_fonts_get_a_font_type_not_text_plain():
    fonts = sorted(STATIC_ROOT.rglob("*.ttf"))
    if not fonts:
        return
    rel = fonts[0].relative_to(STATIC_ROOT).as_posix()

    handler = _get(f"http://x/static/{rel}")

    assert handler.header("Content-Type") == "font/ttf"


def test_traversal_is_still_refused():
    handler = _Handler()
    routes._serve_static(handler, urlparse("http://x/static/../api/routes.py"))

    assert handler.status == 404
