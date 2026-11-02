"""chat_image: one checked, saved image the reply can show beside its text."""
from __future__ import annotations

import io
import json

import pytest
from PIL import Image

from agent import chat_media as cm
from tools import chat_image_tool as ci


def _img(w=800, h=600, fmt="PNG"):
    buf = io.BytesIO()
    Image.new("RGB", (w, h), (10, 120, 200)).save(buf, format=fmt)
    return buf.getvalue()


@pytest.fixture
def chat(monkeypatch):
    env = {"HERMES_SESSION_ID": "chat1~background-1", "HERMES_SESSION_PLATFORM": "webui"}
    monkeypatch.setattr(ci, "get_session_env", lambda name, default="": env.get(name, default))
    monkeypatch.setattr(ci, "fetch_image", lambda url, timeout=8.0: _img())
    return env


def _run(**args):
    return json.loads(ci.chat_image_tool(args))


def test_web_image_saved_checked_and_show_with_markdown(chat, monkeypatch):
    monkeypatch.setattr(ci, "_check_image", lambda path, expect: "matches")
    out = _run(source="https://x/rokid.jpg", caption="Rokid", expect="Rokid Glasses product photo")
    assert out["ok"] is True and out["check"] == "matches"
    assert out["show_with"].startswith("![Rokid](" + str(cm.media_dir("chat1")))
    assert (out["width"], out["height"]) == (800, 600)
    rows = cm.images_since("chat1", "chat1~background-1", 0)
    assert len(rows) == 1 and rows[0]["caption"] == "Rokid"


def test_mismatch_returns_not_ok_with_reason_and_deletes_file(chat, monkeypatch):
    monkeypatch.setattr(ci, "_check_image", lambda path, expect: "mismatch: it is a company logo")
    out = _run(source="https://x/logo.png", caption="Rokid", expect="Rokid Glasses")
    assert out["ok"] is False and "logo" in out["error"]
    assert not [p for p in cm.media_dir("chat1").glob("*") if p.suffix != ".jsonl"]


def test_check_failure_still_shows_unchecked(chat, monkeypatch):
    monkeypatch.setattr(ci, "_check_image", lambda path, expect: "unchecked: no vision model")
    out = _run(source="https://x/a.jpg", caption="A", expect="a cat")
    assert out["ok"] is True and out["check"].startswith("unchecked")
    assert "not verified" in out["note"]


def test_check_image_maps_llm_errors_to_unchecked(monkeypatch, tmp_path):
    p = tmp_path / "a.png"
    p.write_bytes(_img())

    def boom(*a, **k):
        raise RuntimeError("no provider")

    monkeypatch.setattr("agent.auxiliary_client.call_llm", boom)
    assert ci._check_image(p, "a cat").startswith("unchecked:")


def test_check_image_reads_match_and_no(monkeypatch, tmp_path):
    p = tmp_path / "a.png"
    p.write_bytes(_img())

    class R:
        def __init__(self, text):
            self.choices = [type("C", (), {"message": type("M", (), {"content": text})()})()]

    monkeypatch.setattr("agent.auxiliary_client.call_llm", lambda *a, **k: R("MATCH"))
    assert ci._check_image(p, "a cat") == "matches"
    monkeypatch.setattr("agent.auxiliary_client.call_llm", lambda *a, **k: R("NO: it is a banner ad"))
    assert ci._check_image(p, "a cat") == "mismatch: it is a banner ad"


def test_server_path_source_copied_and_no_check_without_expect(chat, monkeypatch, tmp_path):
    called = []
    monkeypatch.setattr(ci, "_check_image", lambda path, expect: called.append(1) or "matches")
    src = tmp_path / "chart.png"
    src.write_bytes(_img(600, 400))
    out = _run(source=str(src), caption="Chart")
    assert out["ok"] is True and called == [] and out["check"] == ""
    assert str(cm.media_dir("chat1")) in out["show_with"]


def test_non_webui_platform_uses_media_token(chat, monkeypatch):
    chat["HERMES_SESSION_PLATFORM"] = "telegram"
    monkeypatch.setattr(ci, "_check_image", lambda path, expect: "matches")
    out = _run(source="https://x/a.jpg", expect="a")
    assert out["show_with"].startswith("MEDIA:" + str(cm.media_dir("chat1")))


def test_rejected_image_reports_reason(chat, monkeypatch):
    monkeypatch.setattr(ci, "fetch_image", lambda url, timeout=8.0: _img(40, 40))
    out = _run(source="https://x/pixel.png")
    assert out["ok"] is False and "too small" in out["error"]


def test_no_session_is_an_error(monkeypatch):
    monkeypatch.setattr(ci, "get_session_env", lambda name, default="": "")
    out = _run(source="https://x/a.jpg")
    assert out["ok"] is False


def test_tool_registered_in_core_toolset():
    import toolsets
    assert "chat_image" in toolsets._HERMES_CORE_TOOLS
    assert "chat_image" in toolsets.TOOLSETS
