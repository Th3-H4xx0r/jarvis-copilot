"""Per-chat media store: what gets saved, how it is named, and the backstop
that pulls stray image refs in a finished reply into the chat's folder."""
from __future__ import annotations

import io
import json
import re
import time

import pytest
from PIL import Image

from agent import chat_media as cm


def _img(w, h, fmt="PNG", color=(200, 30, 30)):
    buf = io.BytesIO()
    Image.new("RGB", (w, h), color).save(buf, format=fmt)
    return buf.getvalue()


def test_root_session_strips_worker_suffix():
    assert cm.root_session("abc~background-1") == "abc"
    assert cm.root_session("abc") == "abc"
    assert cm.media_dir("abc~x").name == "abc"


def test_save_names_file_with_size():
    saved = cm.save_image_bytes(_img(800, 600), "s1", name_hint="Rokid!", caption="Rokid Glasses")
    assert re.match(r"^rokid-[0-9a-f]{6}_800x600\.png$", saved.path.name), saved.path.name
    assert (saved.width, saved.height) == (800, 600)
    assert saved.path.parent == cm.media_dir("s1")
    rows = [json.loads(l) for l in (cm.media_dir("s1") / "index.jsonl").read_text().splitlines()]
    assert len(rows) == 1 and rows[0]["caption"] == "Rokid Glasses" and rows[0]["file"] == saved.path.name


def test_save_rejects_svg_tiny_and_non_image():
    for data in (b'<svg xmlns="http://www.w3.org/2000/svg"></svg>', _img(100, 100), b"hello"):
        with pytest.raises(cm.ImageRejected):
            cm.save_image_bytes(data, "s1")
    folder = cm.media_dir("s1")
    assert not folder.exists() or not [p for p in folder.iterdir() if p.suffix != ".jsonl"]


def test_save_rejects_oversize():
    with pytest.raises(cm.ImageRejected):
        cm.save_image_bytes(b"\x89PNG" + b"0" * (15 * 1024 * 1024 + 1), "s1")


def test_save_downscales_huge():
    saved = cm.save_image_bytes(_img(4000, 1000, "JPEG"), "s1")
    assert saved.path.name.endswith("_2560x640.jpg")
    with Image.open(saved.path) as im:
        assert im.size == (2560, 640)


def test_save_converts_bmp_to_jpeg():
    saved = cm.save_image_bytes(_img(400, 300, "BMP"), "s1")
    assert saved.path.suffix == ".jpg" and saved.mime == "image/jpeg"


def _fetcher(calls):
    def fetch(url, timeout=8.0):
        calls.append(url)
        return _img(640, 480)
    return fetch


def test_localize_rewrites_url_and_md_image():
    calls = []
    text = "A\n- Rokid: MEDIA:https://x/a.jpg\n![Even](https://x/b.png)"
    out = cm.localize_text(text, "s", fetch=_fetcher(calls))
    assert "https://x/" not in out
    root = str(cm.media_dir("s"))
    assert out.count(root) == 2
    assert "- Rokid: MEDIA:" + root in out
    assert "![Even](" + root in out
    assert sorted(calls) == ["https://x/a.jpg", "https://x/b.png"]


def test_localize_is_idempotent():
    calls = []
    first = cm.localize_text("MEDIA:https://x/a.jpg and again MEDIA:https://x/a.jpg", "s", fetch=_fetcher(calls))
    assert calls == ["https://x/a.jpg"]
    calls.clear()
    second = cm.localize_text(first, "s", fetch=_fetcher(calls))
    assert calls == [] and second == first


def test_localize_skips_code_fences():
    calls = []
    text = "Example:\n```\nMEDIA:https://x/a.jpg\n```\n"
    assert cm.localize_text(text, "s", fetch=_fetcher(calls)) == text
    assert calls == []


def test_localize_copies_loose_path_and_leaves_failures(tmp_path):
    loose = tmp_path / "shot.png"
    loose.write_bytes(_img(500, 400))

    def fetch(url, timeout=8.0):
        raise cm.ImageRejected("blocked")

    text = f"Here MEDIA:{loose}\nand ![x](https://bad/y.jpg)"
    out = cm.localize_text(text, "s", fetch=fetch)
    assert str(loose) not in out and str(cm.media_dir("s")) in out
    assert "![x](https://bad/y.jpg)" in out


def test_localize_without_refs_returns_same_object():
    text = "no images here"
    assert cm.localize_text(text, "s") is text


def test_images_since_filters_by_worker_and_time():
    t0 = time.time()
    cm.save_image_bytes(_img(300, 300), "abc", worker_session="abc~bg", caption="one")
    cm.save_image_bytes(_img(300, 300), "abc", worker_session="abc~other", caption="two")
    rows = cm.images_since("abc", "abc~bg", t0 - 1)
    assert [r["caption"] for r in rows] == ["one"]
    assert cm.images_since("abc", "abc~bg", time.time() + 5) == []
    assert rows[0]["path"].startswith(str(cm.media_dir("abc")))


def test_delete_media_removes_folder():
    cm.save_image_bytes(_img(300, 300), "gone")
    cm.delete_media("gone")
    assert not cm.media_dir("gone").exists()
