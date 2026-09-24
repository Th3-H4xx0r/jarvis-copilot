"""The Pod stops listening when the AI marks its reply finished ([end]).

Measured against the Pod's real voice path on gemma4:31b, a tool call for this
added a whole second model call (~1.2 s before the first words); a tag at the
end of the reply costs nothing. The server strips it from what is spoken and
saved, then calls the Pod's own pod_stop_listening tool.
"""
from __future__ import annotations

import json
import sys
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from api import voice  # noqa: E402


def test_the_tag_comes_off_what_is_said():
    assert voice._split_end_tag("Very good, sir. [end]") == ("Very good, sir.", True)
    assert voice._split_end_tag("Tokyo, sir.[END]") == ("Tokyo, sir.", True)
    assert voice._split_end_tag("Sent, sir. [ end ].") == ("Sent, sir.", True)
    assert voice._split_end_tag("[end]") == ("", True)
    assert voice._split_end_tag("How may I help, sir?") == ("How may I help, sir?", False)


def _pod_state(**extra):
    state = {"lock": threading.Lock(), "pcm_buf": bytearray(), "interrupt": False, "client": "jarvis_pod",
             "origin": {"device_id": "pod1", "name": "Pod", "kind": ""}}
    state.update(extra)
    return state


def _stream(monkeypatch, state, texts):
    sent, stops = [], []
    monkeypatch.setattr(voice, "_ws_send_text", lambda c, s, t: sent.append(json.loads(t)) or True)
    monkeypatch.setattr(voice, "_synth_audio", lambda text: None)
    monkeypatch.setattr(voice, "_send_audio", lambda *a: True)
    monkeypatch.setattr(voice, "_start_ack_generation", lambda text: {"skip": True})
    monkeypatch.setattr(voice, "_invoke_pod_stop", lambda device_id: stops.append(device_id))
    gen = iter([{"kind": "text", "text": t} for t in texts])
    voice._stream_segments(None, None, state, gen)
    voice._maybe_stop_pod_listening(state, wait=True)
    said = [f["text"] for f in sent if f.get("type") == "assistant_text"]
    return said, stops


def test_a_finished_reply_stops_the_pod_and_is_not_spoken(monkeypatch):
    said, stops = _stream(monkeypatch, _pod_state(), ["It is half past nine, sir. [end]"])
    assert said == ["It is half past nine, sir."] and stops == ["pod1"]


def test_a_bare_tag_stops_without_an_apology(monkeypatch):
    said, stops = _stream(monkeypatch, _pod_state(), ["[end]"])
    assert said == [] and stops == ["pod1"]


def test_a_reply_that_asks_something_keeps_listening(monkeypatch):
    # "Set a timer." → "How many minutes, sir? [end]": a question needs an answer.
    said, stops = _stream(monkeypatch, _pod_state(), ["How many minutes, sir? [end]"])
    assert said == ["How many minutes, sir?"] and stops == []


def test_no_tag_keeps_listening(monkeypatch):
    said, stops = _stream(monkeypatch, _pod_state(), ["At your service, sir."])
    assert stops == []


def test_only_the_pod_is_stopped(monkeypatch):
    said, stops = _stream(monkeypatch, _pod_state(client=""), ["Very good, sir. [end]"])
    assert said == ["Very good, sir."] and stops == []


def test_the_pod_is_told_how_to_decide():
    rule = voice._CLIENT_DIRECTIVES["jarvis_pod"]
    for phrase in ("[end]", "that's all for now", "no follow-up", "hello"):
        assert phrase.lower() in rule.lower(), phrase


def test_the_saved_chat_has_no_tag():
    messages = [{"role": "user", "content": "That's all."},
                {"role": "assistant", "content": "Very good, sir. [end]"},
                {"role": "assistant", "content": [{"type": "text", "text": "x"}]}]
    voice.strip_end_tags(messages)
    assert messages[1]["content"] == "Very good, sir." and messages[0]["content"] == "That's all."
