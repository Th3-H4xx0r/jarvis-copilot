"""Tests for the `speak_local` Mac skill (plan 4.4-mac).

Lets the server trigger an instant local TTS ack ("On it"/"Done") on the
Mac. Must never block the invoking thread for the duration of the
utterance — it's fire-and-forget.

Run from the ``desktop_client`` directory:
    python3 -m pytest jc_client/test_skill_speak_local.py -q
"""
from __future__ import annotations

import pytest

from jc_client.skills import _REGISTRY
from jc_client.skills import mac


def test_registered_in_skill_catalogue_with_schema():
    assert "speak_local" in _REGISTRY
    entry = _REGISTRY["speak_local"]
    assert entry["input_schema"]["type"] == "object"
    assert "text" in entry["input_schema"]["properties"]
    assert entry["input_schema"]["required"] == ["text"]


def test_empty_text_raises():
    with pytest.raises(ValueError):
        mac.speak_local("")
    with pytest.raises(ValueError):
        mac.speak_local("   ")


def test_falls_back_to_say_when_no_pyobjc(monkeypatch):
    monkeypatch.setattr(mac, "_speak_via_nsspeech", lambda text, voice: False)
    calls = []

    class _FakePopen:
        def __init__(self, cmd, **kwargs):
            calls.append(cmd)

    monkeypatch.setattr(mac.subprocess, "Popen", _FakePopen)

    result = mac.speak_local("On it")
    assert result == {"ok": True, "engine": "say"}
    assert calls == [["say", "On it"]]


def test_voice_argument_passed_to_say(monkeypatch):
    monkeypatch.setattr(mac, "_speak_via_nsspeech", lambda text, voice: False)
    calls = []
    monkeypatch.setattr(
        mac.subprocess, "Popen",
        lambda cmd, **kwargs: calls.append(cmd),
    )

    mac.speak_local("Done", voice="Samantha")
    assert calls == [["say", "-v", "Samantha", "Done"]]


def test_uses_nsspeech_when_available_and_skips_subprocess(monkeypatch):
    monkeypatch.setattr(mac, "_speak_via_nsspeech", lambda text, voice: True)

    def _boom(*a, **kw):
        raise AssertionError("should not spawn `say` when nsspeech succeeded")

    monkeypatch.setattr(mac.subprocess, "Popen", _boom)

    result = mac.speak_local("On it")
    assert result == {"ok": True, "engine": "nsspeech"}


def test_text_is_truncated_to_max_chars(monkeypatch):
    seen = {}

    def _fake_nsspeech(text, voice):
        seen["text"] = text
        return True

    monkeypatch.setattr(mac, "_speak_via_nsspeech", _fake_nsspeech)
    mac.speak_local("x" * 1000)
    assert len(seen["text"]) == mac._SPEAK_LOCAL_MAX_CHARS


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
