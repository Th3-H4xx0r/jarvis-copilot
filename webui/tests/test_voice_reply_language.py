"""A reply in a script the configured voice can't speak is spoken by an Edge voice for it.

The Pod's (and phone's) voice is a Fish Audio clone of an English voice: it read a
Telugu reply as noise. Latin-script languages (Spanish, French…) stay on it — its
model is multilingual — so only other scripts move.
"""
from __future__ import annotations

import base64
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from api import voice  # noqa: E402


def test_each_script_gets_a_voice_that_speaks_it():
    assert voice._script_voice("ఏం చేస్తున్నావు?") == "te-IN-MohanNeural"
    assert voice._script_voice("आप कैसे हैं?") == "hi-IN-MadhurNeural"
    assert voice._script_voice("こんにちは、世界") == "ja-JP-KeitaNeural"  # kana: Japanese, not Chinese
    assert voice._script_voice("你好，世界") == "zh-CN-YunxiNeural"


def test_latin_text_keeps_the_configured_voice():
    assert voice._script_voice("Muy bien, señor. ¿En qué puedo ayudarle?") == ""
    assert voice._script_voice("Very good, sir.") == ""
    # A word or two of another script inside English is still English.
    assert voice._script_voice("In Telugu, hello is నమస్కారం, sir, if you would like to try it.") == ""


def test_a_telugu_reply_is_spoken_by_the_telugu_voice(monkeypatch):
    spoken = []
    monkeypatch.setattr(voice, "_synth_edge_voice", lambda text, v: spoken.append(v) or b"MP3")
    monkeypatch.setattr(voice, "_synthesize_fish_audio",
                        lambda *a, **k: (_ for _ in ()).throw(AssertionError("fish must not speak Telugu")))
    monkeypatch.setattr(voice, "_read_hermes_config", lambda: {"tts": {"provider": "fish-audio"}})
    out = voice._tts_to_base64("నేను బాగున్నాను, సార్.")
    assert spoken == ["te-IN-MohanNeural"] and base64.b64decode(out) == b"MP3"


def test_if_that_voice_fails_the_configured_one_still_speaks(monkeypatch):
    monkeypatch.setattr(voice, "_synth_edge_voice", lambda text, v: b"")
    monkeypatch.setattr(voice, "_synthesize_fish_audio", lambda *a, **k: b"FISH")
    monkeypatch.setattr(voice, "_read_hermes_config", lambda: {"tts": {"provider": "fish-audio"}})
    assert base64.b64decode(voice._tts_to_base64("నేను బాగున్నాను, సార్.")) == b"FISH"
