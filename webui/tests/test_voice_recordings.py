"""Tests for api/voice_recordings.py: the Jarvis Pod's saved voice turns."""
from __future__ import annotations

import sys
import wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import api.voice_recordings as rec  # noqa: E402

PCM = b"\x01\x00" * 16000  # one second of 16 kHz mono


def _dir(monkeypatch, tmp_path):
    monkeypatch.setattr(rec, "RECORDINGS_DIR", tmp_path / "voice_recordings")


def test_save_writes_a_playable_wav_and_lists_newest_first(monkeypatch, tmp_path):
    _dir(monkeypatch, tmp_path)
    first = rec.save("pod1", PCM, 16000, "turn on the lights", now=1_757_900_000.0)
    second = rec.save("pod1", PCM[:8000], 16000, "", now=1_757_900_010.0)
    assert first["duration_ms"] == 1000 and second["duration_ms"] == 250
    assert [r["id"] for r in rec.list_recordings("pod1")] == [second["id"], first["id"]]
    with wave.open(str(rec.audio_path("pod1", first["id"])), "rb") as w:
        assert (w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()) == (1, 2, 16000, 16000)


def test_old_and_excess_recordings_are_pruned(monkeypatch, tmp_path):
    _dir(monkeypatch, tmp_path)
    monkeypatch.setattr(rec, "MAX_PER_DEVICE", 2)
    old = rec.save("pod1", PCM, 16000, "old", now=1_000_000_000.0)
    for i in range(3):
        rec.save("pod1", PCM, 16000, f"new {i}", now=1_757_900_000.0 + i)
    kept = rec.list_recordings("pod1")
    assert [r["transcript"] for r in kept] == ["new 2", "new 1"]
    assert rec.audio_path("pod1", old["id"]) is None
    assert len(list((tmp_path / "voice_recordings" / "pod1").glob("*.wav"))) == 2


def test_delete_and_bad_ids(monkeypatch, tmp_path):
    _dir(monkeypatch, tmp_path)
    r = rec.save("pod1", PCM, 16000, "hi", now=1_757_900_000.0)
    assert rec.save("../etc", PCM, 16000, "x") is None
    assert rec.save("pod1", b"\x00" * 10, 16000, "too short") is None
    assert rec.audio_path("pod1", "../index") is None
    assert rec.delete("pod1", r["id"]) is True
    assert rec.delete("pod1", r["id"]) is False
    assert rec.list_recordings("pod1") == []


def test_only_pod_turns_are_recorded(monkeypatch):
    import api.voice as voice

    saved = []
    monkeypatch.setattr(rec, "save_async", lambda *a, **kw: saved.append((a, kw)))
    origin = {"device_id": "pod1", "name": "Jarvis Pod", "kind": "browser"}
    voice._record_pod_turn({"client": "jarvis_pod", "origin": origin, "noise_cancel": True}, PCM, 16000, "hello")
    voice._record_pod_turn({"client": "", "origin": origin}, PCM, 16000, "phone turn")
    voice._record_pod_turn({"client": "jarvis_pod", "origin": None}, PCM, 16000, "unpaired")
    assert saved == [(("pod1", PCM, 16000, "hello"), {"noise_cancel": True})]


def test_noise_cancelled_recording_is_saved_cleaned(monkeypatch, tmp_path):
    import threading

    import api.voice_denoise as denoise

    _dir(monkeypatch, tmp_path)
    monkeypatch.setattr(denoise, "clean", lambda device_id, pcm, sr=16000: b"\x02\x00" * (len(pcm) // 2))
    started = []
    real_thread = threading.Thread

    class _Now(real_thread):
        def start(self):
            started.append(self)
            self.run()

    monkeypatch.setattr(threading, "Thread", _Now)
    rec.save_async("pod1", PCM, 16000, "hi", noise_cancel=True)
    rec.save_async("pod1", PCM, 16000, "raw")
    by_text = {r["transcript"]: r for r in rec.list_recordings("pod1")}
    assert by_text["hi"]["cleaned"] is True and by_text["raw"]["cleaned"] is False
    with wave.open(str(rec.audio_path("pod1", by_text["hi"]["id"])), "rb") as w:
        assert w.readframes(1) == b"\x02\x00"


def test_denoise_is_a_noop_without_the_package(monkeypatch):
    import api.voice_denoise as denoise

    monkeypatch.setattr(denoise, "available", lambda: False)
    assert denoise.clean("pod1", PCM) is None
