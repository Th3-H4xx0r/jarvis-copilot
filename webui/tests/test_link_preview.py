"""Link previews for the web chat (api/link_preview.py)."""
import functools

import httpx

from api import link_preview as lp


def _mock_client(monkeypatch, handler):
    real = httpx.Client
    monkeypatch.setattr(lp.httpx, "Client",
                        functools.partial(real, transport=httpx.MockTransport(handler)))


def test_parse_prefers_open_graph_and_resolves_relative_image():
    html = """<html><head><title>Fallback</title>
      <meta property="og:title" content="Mario &amp; Luigi Costume">
      <meta property="og:image" content="/img/mario.jpg">
      <meta name="description" content="Two-pack costume">
    </head></html>"""
    p = lp.parse_preview(html, "https://www.example.com/p/1")
    assert p["title"] == "Mario & Luigi Costume"
    assert p["image"] == "https://www.example.com/img/mario.jpg"
    assert p["description"] == "Two-pack costume"
    assert p["site"] == "example.com"


def test_parse_falls_back_to_title_tag_and_drops_non_http_image():
    html = "<title>\n  Plain   page </title><meta property='og:image' content='javascript:alert(1)'>"
    p = lp.parse_preview(html, "https://example.org/")
    assert p["title"] == "Plain page"
    assert p["image"] == ""


def test_unsafe_url_is_never_fetched(monkeypatch):
    calls = []
    _mock_client(monkeypatch, lambda req: calls.append(req) or httpx.Response(200))
    monkeypatch.setattr(lp, "is_safe_url", lambda url: False)
    assert lp.fetch_preview("http://127.0.0.1/admin") is None
    assert calls == []


def test_redirect_into_private_network_is_refused(monkeypatch):
    calls = []

    def handler(req):
        calls.append(str(req.url))
        return httpx.Response(302, headers={"location": "http://10.0.0.5/secret"})

    _mock_client(monkeypatch, handler)
    monkeypatch.setattr(lp, "is_safe_url", lambda url: "10.0.0.5" not in url)
    assert lp.fetch_preview("https://short.example/abc") is None
    assert calls == ["https://short.example/abc"]


def test_fetch_follows_safe_redirect_and_keeps_original_url(monkeypatch):
    def handler(req):
        if req.url.host == "short.example":
            return httpx.Response(301, headers={"location": "https://shop.example/item"})
        return httpx.Response(200, headers={"content-type": "text/html; charset=utf-8"},
                              text='<meta property="og:title" content="Item">'
                                   '<meta property="og:image" content="pic.png">')

    _mock_client(monkeypatch, handler)
    monkeypatch.setattr(lp, "is_safe_url", lambda url: True)
    p = lp.fetch_preview("https://short.example/x")
    assert p["url"] == "https://short.example/x"
    assert p["title"] == "Item"
    assert p["image"] == "https://shop.example/pic.png"
    assert p["site"] == "shop.example"
