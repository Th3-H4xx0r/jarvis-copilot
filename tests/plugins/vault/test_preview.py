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
