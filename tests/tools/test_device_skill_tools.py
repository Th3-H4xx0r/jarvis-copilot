"""Tests for tools/device_skill_tools.py (plan tasks 3.1/3.2/3.4).

Native `device_<skill>` tools are built at runtime from whatever
api.device_bridge.all_device_skills() reports, rebuilt via rebuild_device_tools()
(called by device_bridge's on_registry_change callback in production, and
directly here to avoid needing a real WS connection).
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "webui"))

import api.device_bridge as device_bridge  # noqa: E402
import tools.device_skill_tools as device_skill_tools  # noqa: E402
from tools.registry import registry  # noqa: E402


def _reset(monkeypatch, skills):
    """Point all_device_skills() at a fixed fake catalogue and rebuild."""
    monkeypatch.setattr(device_bridge, "all_device_skills", lambda: skills)
    device_skill_tools.rebuild_device_tools()


def test_single_device_builds_one_tool(monkeypatch):
    _reset(monkeypatch, [
        {"device_id": "dev1", "device_name": "Pranav's Phone", "name": "open_app",
         "description": "Open an app by name.", "input_schema": {
             "type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"],
         }},
    ])
    tools = device_skill_tools.get_device_tools()
    names = {t["name"] for t in tools}
    assert names == {"device_open_app"}
    tool = tools[0]
    assert tool["toolset"] == "devices"
    assert "Pranav's Phone" in tool["schema"]["description"]
    assert "device" not in tool["schema"]["parameters"].get("properties", {})
    assert registry.get_tool_names_for_toolset("devices") == ["device_open_app"]


def test_dedupe_adds_optional_device_arg(monkeypatch):
    _reset(monkeypatch, [
        {"device_id": "dev1", "device_name": "Phone", "name": "open_app",
         "description": "Open an app.", "input_schema": {"type": "object", "properties": {}}},
        {"device_id": "dev2", "device_name": "Mac", "name": "open_app",
         "description": "Open an app.", "input_schema": {"type": "object", "properties": {}}},
    ])
    tools = device_skill_tools.get_device_tools()
    assert len(tools) == 1
    schema = tools[0]["schema"]
    assert "device" in schema["parameters"]["properties"]
    assert "Phone" in schema["description"] and "Mac" in schema["description"]


def test_rebuild_drops_stale_tools_on_disconnect(monkeypatch):
    _reset(monkeypatch, [
        {"device_id": "dev1", "device_name": "Phone", "name": "flashlight",
         "description": "Toggle flashlight.", "input_schema": {}},
    ])
    assert "device_flashlight" in {t["name"] for t in device_skill_tools.get_device_tools()}
    assert registry.get_tool_names_for_toolset("devices") == ["device_flashlight"]

    _reset(monkeypatch, [])  # device disconnected
    assert device_skill_tools.get_device_tools() == []
    assert registry.get_tool_names_for_toolset("devices") == []


def test_handler_resolves_named_device_and_invokes_in_process(monkeypatch):
    _reset(monkeypatch, [
        {"device_id": "dev1", "device_name": "Phone", "name": "open_app",
         "description": "Open an app.", "input_schema": {"type": "object", "properties": {}}},
        {"device_id": "dev2", "device_name": "Mac", "name": "open_app",
         "description": "Open an app.", "input_schema": {"type": "object", "properties": {}}},
    ])
    monkeypatch.setattr(device_bridge, "in_process_available", lambda: True)
    calls = []

    def _fake_invoke(device_id, skill, args, timeout=30.0):
        calls.append((device_id, skill, args))
        return {"ok": True, "result": "done"}

    monkeypatch.setattr(device_bridge, "invoke_skill", _fake_invoke)

    tools = {t["name"]: t for t in device_skill_tools.get_device_tools()}
    handler = tools["device_open_app"]["handler"]
    out = json.loads(handler(args={"device": "mac", "name": "Safari"}))

    assert out == {"ok": True, "result": "done"}
    assert calls == [("dev2", "open_app", {"name": "Safari"})]


def test_handler_falls_back_to_http_when_not_in_process(monkeypatch):
    _reset(monkeypatch, [
        {"device_id": "dev1", "device_name": "Phone", "name": "vibrate",
         "description": "Vibrate the phone.", "input_schema": {}},
    ])
    monkeypatch.setattr(device_bridge, "in_process_available", lambda: False)

    import tools.chrome_device_tool as chrome_device_tool
    calls = []

    def _fake_http_invoke(device_id, skill, args):
        calls.append((device_id, skill, args))
        return {"ok": True, "result": "buzzed"}

    monkeypatch.setattr(chrome_device_tool, "invoke_skill_safe", _fake_http_invoke)

    tools = {t["name"]: t for t in device_skill_tools.get_device_tools()}
    out = json.loads(tools["device_vibrate"]["handler"](args={}))

    assert out == {"ok": True, "result": "buzzed"}
    assert calls == [("dev1", "vibrate", {})]


def test_unknown_device_arg_errors_without_raising(monkeypatch):
    _reset(monkeypatch, [
        {"device_id": "dev1", "device_name": "Phone", "name": "open_app",
         "description": "Open an app.", "input_schema": {}},
        {"device_id": "dev2", "device_name": "Mac", "name": "open_app",
         "description": "Open an app.", "input_schema": {}},
    ])
    tools = {t["name"]: t for t in device_skill_tools.get_device_tools()}
    out = json.loads(tools["device_open_app"]["handler"](args={"device": "watch"}))
    assert out["ok"] is False
    assert "watch" in out["error"]


def test_invoke_exception_becomes_error_result_not_exception(monkeypatch):
    _reset(monkeypatch, [
        {"device_id": "dev1", "device_name": "Phone", "name": "open_app",
         "description": "Open an app.", "input_schema": {}},
    ])
    monkeypatch.setattr(device_bridge, "in_process_available", lambda: True)

    def _raise(*_a, **_k):
        raise RuntimeError("device bridge exploded")

    monkeypatch.setattr(device_bridge, "invoke_skill", _raise)

    tools = {t["name"]: t for t in device_skill_tools.get_device_tools()}
    out = json.loads(tools["device_open_app"]["handler"](args={}))
    assert out["ok"] is False
    assert "device bridge exploded" in out["error"]


def test_result_trimmed_over_1kb_for_non_reader_skill(monkeypatch):
    _reset(monkeypatch, [
        {"device_id": "dev1", "device_name": "Phone", "name": "send_sms",
         "description": "Send an SMS.", "input_schema": {}},
    ])
    monkeypatch.setattr(device_bridge, "in_process_available", lambda: True)
    big = "x" * 5000
    monkeypatch.setattr(device_bridge, "invoke_skill", lambda *a, **k: {"ok": True, "result": big})

    tools = {t["name"]: t for t in device_skill_tools.get_device_tools()}
    out = json.loads(tools["device_send_sms"]["handler"](args={}))
    assert len(out["result"]) < 5000
    assert "truncated" in out["result"]


def test_registry_change_notification_rebuilds_tools(monkeypatch):
    """device_bridge._notify_registry_change() (fired on register/disconnect
    in production) drives the same rebuild path exercised elsewhere via a
    direct rebuild_device_tools() call."""
    monkeypatch.setattr(device_bridge, "all_device_skills", lambda: [])
    device_skill_tools.rebuild_device_tools()
    assert device_skill_tools.get_device_tools() == []

    monkeypatch.setattr(device_bridge, "all_device_skills", lambda: [
        {"device_id": "dev1", "device_name": "Phone", "name": "vibrate",
         "description": "Vibrate.", "input_schema": {}},
    ])
    assert device_skill_tools.rebuild_device_tools in device_bridge._REGISTRY_CHANGE_CALLBACKS
    device_bridge._notify_registry_change()
    assert {t["name"] for t in device_skill_tools.get_device_tools()} == {"device_vibrate"}


def test_reader_skill_keeps_full_result(monkeypatch):
    _reset(monkeypatch, [
        {"device_id": "dev1", "device_name": "Mac", "name": "chrome_snapshot",
         "description": "Snapshot the page.", "input_schema": {}},
    ])
    monkeypatch.setattr(device_bridge, "in_process_available", lambda: True)
    big = "y" * 5000
    monkeypatch.setattr(device_bridge, "invoke_skill", lambda *a, **k: {"ok": True, "result": big})

    tools = {t["name"]: t for t in device_skill_tools.get_device_tools()}
    out = json.loads(tools["device_chrome_snapshot"]["handler"](args={}))
    assert out["result"] == big


# ── image results: save to disk + describe through the vision tool ──────────

_PNG_1PX = ("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk"
            "YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")


def _image_skill(monkeypatch, tmp_path, result, described="A cat on a sofa."):
    _reset(monkeypatch, [
        {"device_id": "dev1", "device_name": "Phone", "name": "recent_photo",
         "description": "Latest photo.", "input_schema": {"type": "object", "properties": {}}},
    ])
    monkeypatch.setattr(device_bridge, "in_process_available", lambda: True)
    monkeypatch.setattr(device_bridge, "invoke_skill", lambda d, s, a: dict(result))
    monkeypatch.setattr(device_skill_tools, "_IMAGE_DIR", tmp_path)
    calls = []

    def fake_describe(path, prompt):
        calls.append((path, prompt))
        return described

    monkeypatch.setattr(device_skill_tools, "_describe_image", fake_describe)
    # Assume a vision-capable main model unless a test says otherwise.
    monkeypatch.setattr(device_skill_tools, "_model_sees_images", lambda: True)
    tools = {t["name"]: t for t in device_skill_tools.get_device_tools()}
    return tools["device_recent_photo"]["handler"], calls


def test_image_result_is_saved_and_described(monkeypatch, tmp_path):
    handler, calls = _image_skill(monkeypatch, tmp_path,
                                  {"base64": _PNG_1PX, "mime": "image/png", "bytes": 70, "date": "2026-09-06"})
    out = json.loads(handler({"question": "what is in it?"}))
    assert "base64" not in out, "the model reads text — a base64 blob is useless and blows the budget"
    assert out["image_path"].endswith(".png") and Path(out["image_path"]).exists()
    assert out["description"] == "A cat on a sofa."
    assert out["date"] == "2026-09-06"
    assert calls and calls[0][1] == "what is in it?"


def test_image_result_without_a_question_gets_a_default_description(monkeypatch, tmp_path):
    handler, calls = _image_skill(monkeypatch, tmp_path, {"base64": _PNG_1PX, "mime": "image/jpeg"})
    out = json.loads(handler({}))
    assert out["image_path"].endswith(".jpg")
    assert calls[0][1]  # some default prompt was used
    assert out["description"] == "A cat on a sofa."


def test_vision_failure_still_returns_the_saved_image(monkeypatch, tmp_path):
    handler, _ = _image_skill(monkeypatch, tmp_path, {"base64": _PNG_1PX, "mime": "image/png"})

    def boom(path, prompt):
        raise RuntimeError("no vision model")

    monkeypatch.setattr(device_skill_tools, "_describe_image", boom)
    out = json.loads(handler({}))
    assert Path(out["image_path"]).exists()
    assert "description" not in out
    assert "no vision model" in out["vision_error"]


def test_non_image_results_are_untouched(monkeypatch, tmp_path):
    handler, calls = _image_skill(monkeypatch, tmp_path, {"cancelled": True})
    out = json.loads(handler({}))
    assert out == {"cancelled": True}
    assert not calls


def test_a_multimodal_vision_envelope_is_passed_through_with_metadata(monkeypatch, tmp_path):
    """When the main model can see images in tool results, the pixels go to it
    directly (same path as an attached photo) instead of a text description."""
    envelope = {"_multimodal": True,
                "content": [{"type": "image_url", "image_url": {"url": "data:image/png;base64,xx"}}],
                "text_summary": "Image attached natively."}
    handler, _ = _image_skill(monkeypatch, tmp_path,
                              {"base64": _PNG_1PX, "mime": "image/png", "taken_at": "2026-09-06T21:41:00Z"},
                              described=envelope)
    out = handler({})
    assert isinstance(out, dict), "a multimodal result must NOT be JSON-encoded"
    assert out["_multimodal"] is True
    assert out["content"][0]["type"] == "text" and "taken_at" in out["content"][0]["text"]
    assert out["content"][1]["type"] == "image_url"
    assert out["meta"]["image_path"].endswith(".png")
