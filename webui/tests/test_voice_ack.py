"""The spoken "on it" before a reply is for long jobs only.

A quick device action ("sterilise my water bottle") got an acknowledgement
("Starting the sterilization process for your bottle, sir.") and then the real
answer, which said the same thing again. The fast-lane model decides whether a
request will take a while; a quick one is simply done and answered once.
"""
from __future__ import annotations

import json
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from api import voice  # noqa: E402


def _state():
    return {"lock": threading.Lock(), "pcm_buf": bytearray(), "interrupt": False, "client": ""}


def _speak(monkeypatch, job, replies):
    """Run one voice turn whose reply segments arrive as `replies`
    [(delay_s, text), …], with the ack generator's job `job`."""
    sent = []
    monkeypatch.setattr(voice, "_ws_send_text", lambda c, s, t: sent.append(json.loads(t)) or True)
    monkeypatch.setattr(voice, "_synth_audio", lambda text: None)
    monkeypatch.setattr(voice, "_send_audio", lambda *a: True)
    monkeypatch.setattr(voice, "_start_ack_generation", lambda text: job)
    monkeypatch.setattr(voice, "_ACK_DELAY_MS", 40)
    monkeypatch.setattr(voice, "_ACK_GENERATE_WAIT_MS", 40)
    monkeypatch.setattr(voice, "_ACK_FALLBACK_MS", 400)

    def gen():
        for delay, text in replies:
            time.sleep(delay)
            yield {"kind": "text", "text": text}

    voice._stream_segments(None, None, _state(), gen())
    time.sleep(0.5)  # any late timer has had its chance
    return [(f["text"], bool(f.get("ack"))) for f in sent if f.get("type") == "assistant_text"]


def _decided(result=None, skip=False):
    done = threading.Event()
    done.set()
    return {"done": done, "result": result, "skip": skip}


def _undecided():
    return {"done": threading.Event(), "result": None}


def test_a_quick_task_is_answered_once(monkeypatch):
    said = _speak(monkeypatch, _decided(skip=True),
                  [(0.2, "I have started the sterilisation cycle, sir.")])
    assert said == [("I have started the sterilisation cycle, sir.", False)]


def test_a_long_task_is_acknowledged_first(monkeypatch):
    said = _speak(monkeypatch, _decided(result=("Looking into flights to Denver, sir.", None)),
                  [(0.3, "The cheapest is on Friday.")])
    assert said == [("Looking into flights to Denver, sir.", True), ("The cheapest is on Friday.", False)]


def test_an_undecided_ack_is_not_forced_onto_a_quick_answer(monkeypatch):
    # The fast lane was slow: before, a canned "On it, sir." played at ~1.3 s
    # no matter what, on top of an answer that came a moment later.
    said = _speak(monkeypatch, _undecided(), [(0.2, "Done, sir.")])
    assert said == [("Done, sir.", False)]


def test_a_turn_still_silent_at_the_fallback_gets_a_canned_ack(monkeypatch):
    said = _speak(monkeypatch, _undecided(), [(0.7, "Here is the summary.")])
    assert said[0][1] is True and said[0][0] in voice._ACK_PHRASES
    assert said[-1] == ("Here is the summary.", False)


def test_the_model_decides_quick_device_actions_skip():
    rule = voice._ACK_SYSTEM_PROMPT.lower()
    assert "skip" in rule
    for quick in ("single device action", "timer", "quick"):
        assert quick in rule, quick


def test_ack_generation_calls_the_lane_models_own_url_with_thinking_off(monkeypatch):
    """A Celeris fast lane: each model has its own URL, and Magnus thinks by
    default — an ack (32 tokens) must reach the right URL with thinking off."""
    import io
    import urllib.request as ur
    import api.oauth as oauth
    seen = {}
    monkeypatch.setattr(voice, "get_voice_lane_config",
                        lambda: {"fast_lane": {"provider": "celeris", "model": "celeris-1-magnus"}})
    monkeypatch.setattr(oauth, "resolve_runtime_provider_with_anthropic_env_lock",
                        lambda fn, requested=None: {"base_url": "https://inference.celeris.ai/celeris-1/v1",
                                                    "api_key": "ck_test"})

    class _Resp(io.BytesIO):
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    def fake_urlopen(req, timeout=None):
        seen["url"], seen["body"] = req.full_url, json.loads(req.data)
        return _Resp(json.dumps({"choices": [{"message": {"content": "On it."}}]}).encode())

    monkeypatch.setattr(ur, "urlopen", fake_urlopen)
    monkeypatch.setattr(voice, "_synth_audio_uncached", lambda phrase: b"")
    job = voice._start_ack_generation("research the history of rome for me")
    assert job["done"].wait(3)
    assert seen["url"] == "https://inference.celeris.ai/celeris-1-magnus/v1/chat/completions"
    assert seen["body"]["model"] == "celeris-1-magnus"
    assert seen["body"]["chat_template_kwargs"] == {"enable_thinking": False}
