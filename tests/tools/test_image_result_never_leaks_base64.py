"""A photo must never reach a text-only model as a base64 data URL.

Ollama Cloud (and any provider that can't take image parts in a tool result)
got the multimodal envelope stringified into the prompt, so the model politely
echoed `data:image/jpeg;base64,/9j/4AAQ...` into the chat instead of describing
the picture."""
import base64
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "webui"))

import api.device_bridge as device_bridge  # noqa: E402
import tools.device_skill_tools as device_skill_tools  # noqa: E402

_PNG_1PX = ("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk"
            "YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")


def _handler(monkeypatch, tmp_path, *, supports_media, described):
    monkeypatch.setattr(device_bridge, "all_device_skills", lambda: [
        {"device_id": "dev1", "device_name": "Phone", "name": "recent_photo",
         "description": "Latest photo.", "input_schema": {"type": "object", "properties": {}}},
    ])
    device_skill_tools.rebuild_device_tools()
    monkeypatch.setattr(device_bridge, "in_process_available", lambda: True)
    monkeypatch.setattr(device_bridge, "invoke_skill",
                        lambda d, s, a: {"base64": _PNG_1PX, "mime": "image/png"})
    monkeypatch.setattr(device_skill_tools, "_IMAGE_DIR", tmp_path)
    monkeypatch.setattr(device_skill_tools, "_model_sees_images", lambda: supports_media)
    monkeypatch.setattr(device_skill_tools, "_describe_image", lambda p, q: described)
    tools = {t["name"]: t for t in device_skill_tools.get_device_tools()}
    return tools["device_recent_photo"]["handler"]


def test_a_text_only_model_gets_words_not_a_data_url(monkeypatch, tmp_path):
    envelope = {"_multimodal": True,
                "content": [{"type": "text", "text": "Image loaded."},
                            {"type": "image_url",
                             "image_url": {"url": "data:image/png;base64," + _PNG_1PX}}],
                "text_summary": "Image attached natively."}
    handler = _handler(monkeypatch, tmp_path, supports_media=False, described=envelope)
    out = handler({})
    assert isinstance(out, str), "a text-only model must not receive the envelope"
    assert "data:image" not in out and "base64," not in out
    parsed = json.loads(out)
    assert parsed["image_path"].endswith(".png")


def test_a_vision_model_still_gets_the_pixels(monkeypatch, tmp_path):
    envelope = {"_multimodal": True,
                "content": [{"type": "image_url",
                             "image_url": {"url": "data:image/png;base64," + _PNG_1PX}}],
                "text_summary": "Image attached natively."}
    handler = _handler(monkeypatch, tmp_path, supports_media=True, described=envelope)
    out = handler({})
    assert isinstance(out, dict) and out["_multimodal"] is True


def test_a_data_url_in_a_text_description_is_stripped(monkeypatch, tmp_path):
    leaked = "Here it is: data:image/png;base64," + _PNG_1PX + " end."
    handler = _handler(monkeypatch, tmp_path, supports_media=False, described=leaked)
    out = handler({})
    assert "base64," not in out
    assert "[image]" in json.loads(out)["description"]


def test_the_bridges_nested_result_envelope_is_unwrapped(monkeypatch, tmp_path):
    """The device bridge returns {"ok": true, "result": {...the skill's dict}}.
    Looking for `base64` only at the top level meant the photo was never
    extracted: the model saw a truncated base64 blob and invented a picture."""
    monkeypatch.setattr(device_bridge, "all_device_skills", lambda: [
        {"device_id": "dev1", "device_name": "Phone", "name": "recent_photo",
         "description": "Latest photo.", "input_schema": {"type": "object", "properties": {}}},
    ])
    device_skill_tools.rebuild_device_tools()
    monkeypatch.setattr(device_bridge, "in_process_available", lambda: True)
    monkeypatch.setattr(device_bridge, "invoke_skill", lambda d, s, a: {
        "ok": True,
        "result": {"found": True, "bytes": 88387, "base64": _PNG_1PX,
                   "mime": "image/jpeg", "taken_at": "2026-09-06T22:14:00Z"},
    })
    monkeypatch.setattr(device_skill_tools, "_IMAGE_DIR", tmp_path)
    monkeypatch.setattr(device_skill_tools, "_model_sees_images", lambda: False)
    monkeypatch.setattr(device_skill_tools, "_describe_image",
                        lambda p, q: "A white mug on a wooden table.")
    tools = {t["name"]: t for t in device_skill_tools.get_device_tools()}
    out = json.loads(tools["device_recent_photo"]["handler"]({}))

    assert "base64" not in json.dumps(out), "the blob must never reach the model"
    inner = out.get("result", out)
    assert inner["description"] == "A white mug on a wooden table."
    assert inner["image_path"].endswith(".jpg")
    assert inner["taken_at"] == "2026-09-06T22:14:00Z"
