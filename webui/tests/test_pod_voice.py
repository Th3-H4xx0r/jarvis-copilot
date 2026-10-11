"""The Jarvis Pod's own chat and model (api/pod_voice.py), chosen on the phone's Pod page."""
from __future__ import annotations

import json
import sys
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import api.pod_voice as pod_voice  # noqa: E402
from api import voice  # noqa: E402


def _store(monkeypatch, tmp_path, sessions=("chat-1",), harnesses=("fast-claude", "single")):
    monkeypatch.setattr(pod_voice, "PATH", tmp_path / "pod_voice.json")
    monkeypatch.setattr(pod_voice, "_session_exists", lambda sid: sid in sessions)
    monkeypatch.setattr(pod_voice, "_harness_exists", lambda hid: hid in harnesses)


def test_nothing_chosen_is_the_voice_defaults(monkeypatch, tmp_path):
    _store(monkeypatch, tmp_path)
    assert pod_voice.load("pod1") == {"session_id": "", "model": "", "provider": "", "harness_id": ""}


def test_a_choice_is_kept_per_pod(monkeypatch, tmp_path):
    _store(monkeypatch, tmp_path)
    pod_voice.save("pod1", {"session_id": "chat-1", "harness_id": "fast-claude", "bogus": 1})
    assert pod_voice.load("pod1") == {"session_id": "chat-1", "model": "", "provider": "", "harness_id": "fast-claude"}
    assert pod_voice.load("pod2")["session_id"] == ""
    # Clearing the harness is "Voice default"; the chat stays.
    pod_voice.save("pod1", {"harness_id": ""})
    assert pod_voice.load("pod1")["session_id"] == "chat-1" and pod_voice.load("pod1")["harness_id"] == ""
    assert json.loads((tmp_path / "pod_voice.json").read_text())["pod1"]["session_id"] == "chat-1"


def _begin(state, **extra):
    msg = {"type": "begin_turn", "sample_rate": 16000, "client": "jarvis_pod",
           "session_id": "voice-daily", "codec": "opus"}
    msg.update(extra)
    voice._handle_control_frame(msg, state, None, None)


def _state(device_id="pod1"):
    return {"lock": threading.Lock(), "pcm_buf": bytearray(), "interrupt": False,
            "clarify_pending": False, "sample_rate": 16000, "session_id": "",
            "origin": {"device_id": device_id, "name": "Pod", "kind": "pod"}}


def test_a_pod_turn_goes_to_its_chosen_chat_and_harness(monkeypatch, tmp_path):
    # The Pod picks a harness, not a model: a model saved by an older phone build
    # no longer applies (Single = the chat's own model).
    _store(monkeypatch, tmp_path)
    monkeypatch.setattr(voice, "_attach_escalation_sink", lambda *a: None)
    pod_voice.save("pod1", {"session_id": "chat-1", "harness_id": "fast-claude", "model": "gpt-5", "provider": "openai"})
    state = _state()
    _begin(state)
    assert (state["session_id"], state["harness_id"]) == ("chat-1", "fast-claude")
    assert "model" not in state and "model_provider" not in state


def test_a_deleted_harness_falls_back_to_the_voice_default(monkeypatch, tmp_path):
    _store(monkeypatch, tmp_path, harnesses=())
    monkeypatch.setattr(voice, "_attach_escalation_sink", lambda *a: None)
    pod_voice.save("pod1", {"harness_id": "gone"})
    state = _state()
    _begin(state)
    assert state["harness_id"] == ""


def test_a_deleted_chat_falls_back_to_the_voice_chat(monkeypatch, tmp_path):
    _store(monkeypatch, tmp_path, sessions=())
    monkeypatch.setattr(voice, "_attach_escalation_sink", lambda *a: None)
    pod_voice.save("pod1", {"session_id": "chat-gone"})
    state = _state()
    _begin(state)
    assert state["session_id"] == "voice-daily" and "model" not in state


def test_only_the_pod_gets_the_pods_choice(monkeypatch, tmp_path):
    _store(monkeypatch, tmp_path)
    monkeypatch.setattr(voice, "_attach_escalation_sink", lambda *a: None)
    pod_voice.save("phone1", {"session_id": "chat-1", "model": "gpt-5"})
    state = _state("phone1")
    _begin(state, client="")
    assert state["session_id"] == "voice-daily" and "model" not in state


def test_a_new_choice_applies_from_the_next_turn(monkeypatch, tmp_path):
    # The Pod sends begin_turn once per socket and keeps the socket for hours:
    # a choice made on the phone must not wait for a reconnect.
    _store(monkeypatch, tmp_path)
    monkeypatch.setattr(voice, "_attach_escalation_sink", lambda *a: None)
    state = _state()
    _begin(state)
    assert state["session_id"] == "voice-daily"
    pod_voice.save("pod1", {"session_id": "chat-1", "harness_id": "single"})
    voice._refresh_pod_choice(state, None, None)
    assert (state["session_id"], state["harness_id"]) == ("chat-1", "single")
    pod_voice.save("pod1", {"session_id": "", "harness_id": ""})
    voice._refresh_pod_choice(state, None, None)
    assert state["session_id"] == "voice-daily" and state["harness_id"] == "" and "model" not in state
