"""Uploads and voice notes: the local path must stay exactly today's call."""
import sys
import types
from unittest.mock import patch

import jarvis_speech


def test_local_calls_transcribe_audio_with_path_only(monkeypatch):
    monkeypatch.setattr(jarvis_speech, "engine_for", lambda surface: None)
    with patch("tools.transcription_tools.transcribe_audio",
               return_value={"success": True, "transcript": "hi"}) as m:
        assert jarvis_speech.transcribe_file("/tmp/does-not-exist.ogg")["transcript"] == "hi"
    m.assert_called_once_with("/tmp/does-not-exist.ogg")


def test_local_honours_a_swapped_module(monkeypatch):
    fake = types.ModuleType("tools.transcription_tools")
    fake.transcribe_audio = lambda path: {"success": True, "transcript": "swapped"}
    monkeypatch.setitem(sys.modules, "tools.transcription_tools", fake)
    monkeypatch.setattr(jarvis_speech, "engine_for", lambda surface: None)
    assert jarvis_speech.transcribe_file("x.webm")["transcript"] == "swapped"


def test_engine_result_is_used(monkeypatch):
    class Cloud:
        name = "cloud"

        def transcribe_file(self, path):
            return {"success": True, "transcript": "cloud words", "provider": "cloud"}
    monkeypatch.setattr(jarvis_speech, "engine_for", lambda surface: Cloud())
    with patch("tools.transcription_tools.transcribe_audio") as m:
        assert jarvis_speech.transcribe_file("a.ogg")["transcript"] == "cloud words"
    m.assert_not_called()


def test_engine_failure_falls_back_to_local(monkeypatch):
    class Boom:
        name = "boom"

        def transcribe_file(self, path):
            raise RuntimeError("down")
    monkeypatch.setattr(jarvis_speech, "engine_for", lambda surface: Boom())
    with patch("tools.transcription_tools.transcribe_audio",
               return_value={"success": True, "transcript": "local"}):
        assert jarvis_speech.transcribe_file("a.ogg")["transcript"] == "local"


def test_engine_unsuccessful_result_falls_back_to_local(monkeypatch):
    class Refuses:
        name = "refuses"

        def transcribe_file(self, path):
            return {"success": False, "transcript": "", "error": "unsupported format"}
    monkeypatch.setattr(jarvis_speech, "engine_for", lambda surface: Refuses())
    with patch("tools.transcription_tools.transcribe_audio",
               return_value={"success": True, "transcript": "local"}):
        assert jarvis_speech.transcribe_file("a.m4a")["transcript"] == "local"
