"""Tests for api/turn_origin.py: the sender device told to the agent, and used as
the default target for device tools."""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import api.auth as auth  # noqa: E402
import api.device_bridge as device_bridge  # noqa: E402
import api.pairing as pairing  # noqa: E402
from api import turn_origin  # noqa: E402

POD = {"id": "pod1", "name": "Jarvis Pod", "kind": "browser"}
PHONE = {"id": "phone1", "name": "Pranav's iPhone", "kind": "mobile-ios"}


def _paired(monkeypatch, device, skills):
    monkeypatch.setattr(auth, "parse_cookie", lambda h: "tok.sig")
    monkeypatch.setattr(auth, "verify_session", lambda c: True)
    monkeypatch.setattr(pairing, "find_device_by_session", lambda c: device)
    monkeypatch.setattr(device_bridge, "skills_for_device", lambda did: [{"name": n} for n in skills])


def test_voice_from_the_pod_names_it_and_asks_for_the_screen(monkeypatch):
    _paired(monkeypatch, POD, ["pod_show", "pod_status"])
    origin = turn_origin.origin_for_handler(object())
    text = turn_origin.directive(origin, "voice")
    assert '"Jarvis Pod" (id pod1' in text
    assert "by voice" in text
    assert 'device="pod1"' in text
    assert "never answer with only a link" in text


def test_chat_from_the_phone_targets_the_phone(monkeypatch):
    _paired(monkeypatch, PHONE, ["open_url", "directions"])
    text = turn_origin.directive(turn_origin.origin_for_handler(object()), "chat")
    assert "in chat" in text and "the iPhone app" in text
    assert 'device="phone1"' in text
    assert "screen" not in text  # no show tool


def test_device_without_tools_keeps_results_in_the_reply(monkeypatch):
    _paired(monkeypatch, {"id": "web1", "name": "Chrome", "kind": "browser"}, [])
    text = turn_origin.directive(turn_origin.origin_for_handler(object()), "chat")
    assert "no device tools" in text


def test_unpaired_or_expired_request_gets_no_context(monkeypatch):
    _paired(monkeypatch, None, [])
    assert turn_origin.origin_for_handler(object()) is None
    assert turn_origin.directive(None, "voice") == ""
    monkeypatch.setattr(auth, "verify_session", lambda c: False)
    monkeypatch.setattr(pairing, "find_device_by_session", lambda c: PHONE)
    assert turn_origin.origin_for_handler(object()) is None


def test_device_tool_defaults_to_the_device_the_user_is_on(monkeypatch):
    import tools.device_skill_tools as device_skill_tools

    catalogue = [
        {"device_id": "mac1", "device_name": "Mac", "name": "open_url",
         "description": "Open a URL.", "input_schema": {"type": "object", "properties": {}}},
        {"device_id": "phone1", "device_name": "iPhone", "name": "open_url",
         "description": "Open a URL.", "input_schema": {"type": "object", "properties": {}}},
    ]
    monkeypatch.setattr(device_bridge, "all_device_skills", lambda: catalogue)
    monkeypatch.setattr(device_bridge, "in_process_available", lambda: True)
    calls = []
    monkeypatch.setattr(device_bridge, "invoke_skill",
                        lambda did, skill, args, timeout=30.0: calls.append(did) or {"ok": True})
    device_skill_tools.rebuild_device_tools()
    handler = {t["name"]: t for t in device_skill_tools.get_device_tools()}["device_open_url"]["handler"]

    turn_origin.note_turn("sess-phone", {"device_id": "phone1", "name": "iPhone", "kind": "mobile-ios"})
    try:
        json.loads(handler(args={"url": "maps://?q=taco+bell"}, task_id="sess-phone"))
        json.loads(handler(args={"url": "https://x"}, task_id="sess-other"))  # unknown session: first match
        json.loads(handler(args={"url": "https://x", "device": "mac"}, task_id="sess-phone"))  # named wins
    finally:
        turn_origin.note_turn("sess-phone", None)
    assert calls == ["phone1", "mac1", "mac1"]
