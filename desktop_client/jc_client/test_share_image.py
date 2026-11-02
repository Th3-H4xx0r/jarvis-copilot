"""Tests for the `share_image` skill: an image file on this computer (a
screenshot Jarvis saved with a shell command) sent up so it shows in the chat.

Run from the ``desktop_client`` directory:
    python3 -m pytest jc_client/test_share_image.py -q
"""
from __future__ import annotations

import base64
import io

from PIL import Image

from jc_client.skills import _REGISTRY
from jc_client.skills import common


def _png(path, w=400, h=300):
    Image.new("RGB", (w, h), (20, 40, 60)).save(path, format="PNG")


def test_share_image_reads_png(tmp_path):
    p = tmp_path / "shot.png"
    _png(p)
    out = common.share_image(str(p))
    assert out["format"] == "png" and (out["width"], out["height"]) == (400, 300)
    with Image.open(io.BytesIO(base64.b64decode(out["img_b64"]))) as im:
        assert im.size == (400, 300)


def test_share_image_refuses_text_missing_and_huge(tmp_path, monkeypatch):
    t = tmp_path / "notes.txt"
    t.write_text("hello")
    assert "error" in common.share_image(str(t))
    assert "error" in common.share_image(str(tmp_path / "nope.png"))
    p = tmp_path / "big.png"
    _png(p)
    monkeypatch.setattr(common, "_SHARE_IMAGE_MAX_BYTES", 10)
    assert "error" in common.share_image(str(p))


def test_share_image_is_a_registered_skill():
    assert "share_image" in _REGISTRY
