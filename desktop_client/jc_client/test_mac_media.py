"""The usage descriptions the tray process injects before touching mic or speech.

macOS kills a process that asks for a TCC-gated capability without the matching
usage string in its bundle. The tray is a Python interpreter, so the strings
have to be put into its in-memory Info.plist at runtime.
"""
from __future__ import annotations

import sys
import types

from jc_client import _mac_media


def _fake_foundation(monkeypatch, info):
    class _Bundle:
        def infoDictionary(self):
            return info

    class _NSBundle:
        @staticmethod
        def mainBundle():
            return _Bundle()

    monkeypatch.setitem(sys.modules, "Foundation", types.SimpleNamespace(NSBundle=_NSBundle))


def test_both_the_mic_and_speech_descriptions_are_injected(monkeypatch):
    info = {}
    _fake_foundation(monkeypatch, info)
    _mac_media._inject_usage_description()
    assert info.get("NSMicrophoneUsageDescription")
    # On-device transcription on macOS < 26 falls back to SFSpeechRecognizer,
    # whose authorization request aborts the process without this key.
    assert info.get("NSSpeechRecognitionUsageDescription")


def test_existing_descriptions_are_left_alone(monkeypatch):
    info = {"NSMicrophoneUsageDescription": "ours",
            "NSSpeechRecognitionUsageDescription": "also ours"}
    _fake_foundation(monkeypatch, info)
    _mac_media._inject_usage_description()
    assert info["NSMicrophoneUsageDescription"] == "ours"
    assert info["NSSpeechRecognitionUsageDescription"] == "also ours"
