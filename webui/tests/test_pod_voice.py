"""The Jarvis Pod's own chat and model (api/pod_voice.py), chosen on the phone's Pod page."""
from __future__ import annotations

import json
import sys
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import api.pod_voice as pod_voice  # noqa: E402
from api import voice  # noqa: E402


def _store(monkeypatch, tmp_path, sessions=("chat-1",)):
    monkeypatch.setattr(pod_voice, "PATH", tmp_path / "pod_voice.json")
    monkeypatch.setattr(pod_voice, "_session_exists", lambda sid: sid in sessions)


def test_nothing_chosen_is_the_voice_defaults(monkeypatch, tmp_path):
    _store(monkeypatch, tmp_path)
    assert pod_voice.load("pod1") == {"session_id": "", "model": "", "provider": ""}


def test_a_choice_is_kept_per_pod(monkeypatch, tmp_path):
    _store(monkeypatch, tmp_path)
    pod_voice.save("pod1", {"session_id": "chat-1", "model": "gpt-5", "provider": "openai", "bogus": 1})
    assert pod_voice.load("pod1") == {"session_id": "chat-1", "model": "gpt-5", "provider": "openai"}
    assert pod_voice.load("pod2")["session_id"] == ""
    # Clearing the model is "Auto"; the chat stays.
    pod_voice.save("pod1", {"model": "", "provider": ""})
    assert pod_voice.load("pod1") == {"session_id": "chat-1", "model": "", "provider": ""}
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


def test_a_pod_turn_goes_to_its_chosen_chat_and_model(monkeypatch, tmp_path):
    _store(monkeypatch, tmp_path)
    monkeypatch.setattr(voice, "_attach_escalation_sink", lambda *a: None)
    pod_voice.save("pod1", {"session_id": "chat-1", "model": "gpt-5", "provider": "openai"})
    state = _state()
    _begin(state)
    assert (state["session_id"], state["model"], state["model_provider"]) == ("chat-1", "gpt-5", "openai")


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
    pod_voice.save("pod1", {"session_id": "chat-1", "model": "gpt-5", "provider": "openai"})
    voice._refresh_pod_choice(state, None, None)
    assert (state["session_id"], state["model"], state["model_provider"]) == ("chat-1", "gpt-5", "openai")
    pod_voice.save("pod1", {"session_id": "", "model": "", "provider": ""})
    voice._refresh_pod_choice(state, None, None)
    assert state["session_id"] == "voice-daily" and "model" not in state and "model_provider" not in state
