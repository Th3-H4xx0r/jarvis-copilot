"""Link preview parsing (pure: no network)."""
import pytest

from plugins.vault.preview import parse_duration, parse_page, youtube_id


@pytest.mark.parametrize("raw,seconds", [("PT3M34S", 214), ("PT1H2M3S", 3723), ("95", 95), ("1:02:03", 3723),
                                         ("", None), ("soon", None)])
def test_durations(raw, seconds):
    assert parse_duration(raw) == seconds


def test_open_graph_video_page():
    html = """<html><head><title>fallback</title>
      <meta property="og:title" content="A trip">
      <meta property="og:type" content="video.other">
      <meta property="og:image" content="/img/cover.jpg">
      <meta property="og:site_name" content="Clips">
      <meta itemprop="duration" content="PT2M5S">
      <link rel="icon" href="data:image/png;base64,AAAA"><link rel="icon" href="/fav.png">
    </head></html>"""
    p = parse_page(html, "https://www.clips.example/v/1")
    assert p["title"] == "A trip" and p["kind"] == "video" and p["duration_s"] == 125
    assert p["_image"] == "https://www.clips.example/img/cover.jpg" and p["_icon"] == "https://www.clips.example/fav.png"
    assert p["domain"] == "clips.example" and p["site_name"] == "Clips"


def test_json_ld_video_object():
    html = """<script type="application/ld+json">{"@graph": [{"@type": "VideoObject", "name": "Talk",
      "duration": "PT10M", "thumbnailUrl": ["https://cdn.example/t.jpg"], "author": {"name": "Ann"}}]}</script>"""
    p = parse_page(html, "https://example.com/talk")
    assert (p["title"], p["duration_s"], p["author"], p["_image"]) == ("Talk", 600, "Ann", "https://cdn.example/t.jpg")


def test_article_and_plain_page():
    assert parse_page('<meta property="og:type" content="article">', "https://a.example")["kind"] == "article"
    assert parse_page("<title> Hi  there </title>", "https://a.example")["title"] == "Hi there"


@pytest.mark.parametrize("url,vid", [("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "dQw4w9WgXcQ"),
                                     ("https://youtu.be/dQw4w9WgXcQ?t=3", "dQw4w9WgXcQ"),
                                     ("https://m.youtube.com/shorts/abcdefghijk", "abcdefghijk"),
                                     ("https://example.com/watch?v=x", None)])
def test_youtube_ids(url, vid):
    assert youtube_id(url) == vid


# ── the smarter engine: walls, fallbacks, more image sources ─────────────

import io

import httpx

from plugins.vault import preview as preview_mod
from plugins.vault.preview import is_wall_title, title_from_url


@pytest.mark.parametrize("title", ["Please update your browser to use xHamster | xHamster", "Just a moment...",
                                   "Attention Required! | Cloudflare", "Access Denied", "403 Forbidden",
                                   "Are you a robot?"])
def test_wall_titles(title):
    assert is_wall_title(title)


@pytest.mark.parametrize("title", ["Rick Astley - Never Gonna Give You Up", "How browsers work", "Japan 2026"])
def test_real_titles_are_not_walls(title):
    assert not is_wall_title(title)


@pytest.mark.parametrize("url,title", [
    ("https://site.example/videos/falling-in-love-hindi-audio-part-02-xhBi610", "Falling In Love Hindi Audio Part 02"),
    ("https://blog.example/2026/11/my_trip_to_japan.html", "My Trip To Japan"),
    ("https://site.example/watch/8231231", ""),
    ("https://site.example/", ""),
])
def test_title_from_url(url, title):
    assert title_from_url(url) == title


def test_more_image_sources_and_oembed_discovery():
    html = """<link rel="alternate" type="application/json+oembed" href="/oembed?id=1">
      <img src="/logo.png"><img src="/ad.gif"><img src="/frame.jpg" width="640" height="360">
      <video poster="/poster.jpg"></video>
      <script type="application/ld+json">{"@type": "Article", "image": {"url": "https://cdn.example/a.jpg"}}</script>"""
    p = parse_page(html, "https://example.com/v/1")
    assert p["_oembed"] == "https://example.com/oembed?id=1"
    assert p["_images"] == ["https://cdn.example/a.jpg", "https://example.com/poster.jpg",
                            "https://example.com/frame.jpg"]


def _jpeg(size=(400, 300)):
    from PIL import Image

    buf = io.BytesIO()
    Image.new("RGB", size, (200, 30, 30)).save(buf, "JPEG")
    return buf.getvalue()


@pytest.fixture
def fake_web(monkeypatch):
    """A site that walls off browsers but serves its share card to the Facebook crawler."""
    seen = []
    image = _jpeg()

    def handler(request: httpx.Request):
        ua = request.headers.get("user-agent", "")
        seen.append((request.url.path, ua))
        if request.url.path == "/thumb.jpg":
            return httpx.Response(200, content=image, headers={"content-type": "image/jpeg"})
        if request.url.path.startswith("/videos/"):
            if "facebookexternalhit" in ua:
                return httpx.Response(200, headers={"content-type": "text/html"}, text="""
                    <meta property="og:title" content="The real title">
                    <meta property="og:image" content="https://tube.example/thumb.jpg">
                    <meta property="og:video:duration" content="95">""")
            return httpx.Response(200, headers={"content-type": "text/html"},
                                  text="<title>Please update your browser to use Tube</title>")
        if request.url.path.startswith("/walled/"):
            return httpx.Response(200, headers={"content-type": "text/html"}, text="<title>Just a moment...</title>")
        return httpx.Response(404)

    real_client = httpx.Client

    def client(**kw):
        kw["transport"] = httpx.MockTransport(handler)
        return real_client(**kw)

    monkeypatch.setattr(httpx, "Client", client)
    monkeypatch.setattr("tools.url_safety.is_safe_url", lambda url: True)
    monkeypatch.setattr("tools.url_safety.response_peer_is_public", lambda resp: True)
    return seen


def test_a_browser_wall_falls_back_to_the_crawler_card(fake_web):
    got = preview_mod.fetch("https://tube.example/videos/some-clip-ab12cd", want_favicon=False)
    assert got["preview"]["title"] == "The real title"
    assert got["preview"]["kind"] == "video" and got["preview"]["duration_s"] == 95
    assert got["image"] and got["image"][:2] == b"\xff\xd8"


def test_a_wall_title_is_never_kept(fake_web):
    got = preview_mod.fetch("https://tube.example/walled/cooking-pasta-at-home-x9Y8z7", want_favicon=False)
    assert got["preview"]["title"] == "Cooking Pasta At Home"
    assert got["image"] is None
    # Each client was tried before giving up on the page.
    agents = [ua for path, ua in fake_web if path.startswith("/walled/")]
    assert len(agents) == len(preview_mod._PERSONAS)


def test_a_site_name_title_gives_way_to_the_link(fake_web):
    got = preview_mod.fetch("https://tube.example/plain/late-night-drive-mix", want_favicon=False)
    assert got is None or got["preview"]["title"] in ("Late Night Drive Mix", "")
    assert preview_mod._weak_title({"title": "PornhubPornhub", "site_name": "pornhub.com", "domain": "pornhub.com"})
    assert preview_mod._weak_title({"title": "Instagram", "site_name": "Instagram", "domain": "instagram.com"})
    assert not preview_mod._weak_title({"title": "A day in Kyoto", "site_name": "Vimeo", "domain": "vimeo.com"})
