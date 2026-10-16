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
    assert 'from their device "Jarvis Pod" (id pod1)' in text
    assert "by voice" in text
    assert 'device="pod1"' in text
    assert "never answer with only a link" in text


def test_chat_from_the_phone_targets_the_phone(monkeypatch):
    _paired(monkeypatch, PHONE, ["open_url", "directions"])
    text = turn_origin.directive(turn_origin.origin_for_handler(object()), "chat")
    assert "in chat" in text and '"Pranav\'s iPhone"' in text
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


def test_a_turn_from_the_mac_knows_it_can_see_the_screen(monkeypatch):
    """Push to talk on the Mac said it couldn't see the screen; the Mac offers ui_look."""
    mac = {"id": "mac1", "name": "Pranav's MacBook", "kind": "desktop"}
    _paired(monkeypatch, mac, ["ui_look", "ui_do", "open_url"])
    text = turn_origin.directive(turn_origin.origin_for_handler(object()), "voice")
    assert "you can see its screen" in text and "ui_look" in text
    _paired(monkeypatch, PHONE, ["open_url"])
    assert "ui_look" not in turn_origin.directive(turn_origin.origin_for_handler(object()), "voice")


def test_a_turn_from_jc_client_on_the_mac_counts_as_from_the_mac(monkeypatch):
    """Live: the Mac's jc-client is paired with kind "browser"; the gate took its push to talk
    for "not the Mac" and refused to look at the screen. What it offers decides."""
    jc = {"id": "mac1", "name": "Pranavs-MacBook-Pro.local", "kind": "browser"}
    _paired(monkeypatch, jc, ["ui_look", "ui_do"])
    turn_origin.note_turn("s-mac", turn_origin.origin_for_handler(object()))
    assert turn_origin.is_mac_session("s-mac")
    _paired(monkeypatch, {"id": "web1", "name": "Macbook Web", "kind": "browser"}, [])
    turn_origin.note_turn("s-web", turn_origin.origin_for_handler(object()))
    assert not turn_origin.is_mac_session("s-web")
    _paired(monkeypatch, {"id": "app1", "name": "Jarvis.app", "kind": "desktop"}, [])
    turn_origin.note_turn("s-app", turn_origin.origin_for_handler(object()))
    assert turn_origin.is_mac_session("s-app")
    assert not turn_origin.is_mac_session("unknown")


import pytest  # noqa: E402


@pytest.mark.parametrize("device", [
    {"id": "mac1", "name": "Pranavs-MacBook-Pro.local", "kind": "browser"},
    {"id": "pod1", "name": "Jarvis Pod", "kind": "browser"},
    {"id": "ph1", "name": "JarvisCopilot (iPhone)", "kind": "mobile-ios"},
])
def test_every_turn_names_the_device_as_it_is_registered(monkeypatch, device):
    """Pranav: "it should just send the device name that it's registered as with Jarvis so it
    will know and not have to guess anything." The name, verbatim, first."""
    _paired(monkeypatch, device, [])
    text = turn_origin.directive(turn_origin.origin_for_handler(object()), "voice")
    assert text.startswith(f'[Turn context: the user is talking to you by voice from their device "{device["name"]}" '
                           f'(id {device["id"]}).')
