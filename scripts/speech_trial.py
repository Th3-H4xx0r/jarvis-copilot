#!/usr/bin/env python3
"""Side by side: what Live stored, the local engine, and Soniox, on one window.

Run ON THE SERVER, where the recordings live (never copy them off it):

    cd /root/JarvisCopilot/webui && ../.venv/bin/python ../scripts/speech_trial.py \
        --session <live_session_id> --from-ms 19000 --to-ms 27000 [--translate en]
    cd /root/JarvisCopilot/webui && ../.venv/bin/python ../scripts/speech_trial.py --usage

Needs SONIOX_API_KEY saved (Settings → Speech on the phone or the web). Writes
nothing to the repo; the temporary WAV for the local engine is deleted.
"""
from __future__ import annotations

import argparse
import datetime as dt
import os
import sys
import tempfile
import time
import wave
from pathlib import Path

_WEBUI = Path(__file__).resolve().parent.parent / "webui"
sys.path.insert(0, str(_WEBUI))
sys.path.insert(0, str(_WEBUI.parent))

_CHUNK_MS = 100


class _Collect:
    def __init__(self):
        self.partials = 0

    def on_partial(self, *args):
        self.partials += 1

    def on_segment(self, segment):
        pass

    def on_translation(self, key, text):
        pass

    def on_error(self, message):
        print(f"  soniox error: {message}")


def _local(pcm: bytes, rate: int) -> tuple:
    from tools.transcription_tools import transcribe_audio
    fd, path = tempfile.mkstemp(suffix=".wav", prefix="speech-trial-")
    os.close(fd)
    try:
        with wave.open(path, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(rate)
            w.writeframes(pcm)
        started = time.monotonic()
        result = transcribe_audio(path)
        return result, time.monotonic() - started
    finally:
        Path(path).unlink(missing_ok=True)


def _soniox(pcm: bytes, rate: int, from_ms: int, translate_to: str) -> tuple:
    from jarvis_speech import registry
    engine = registry.get("soniox")
    ok, reason = engine.available()
    if not ok:
        return None, reason, 0.0, 0
    sink = _Collect()
    stream = engine.open_stream(sink, rate=rate, translate_to=translate_to, purpose="live")
    step = rate * 2 * _CHUNK_MS // 1000
    started = time.monotonic()
    for i, offset in enumerate(range(0, len(pcm), step)):
        stream.feed(pcm[offset:offset + step], ts_ms=from_ms + i * _CHUNK_MS)
    seconds = len(pcm) / (2.0 * rate)
    segments = stream.finish(timeout=seconds + 20)
    error = stream.error or ("cut off: Soniox closed before it finished, so later words are missing"
                             if stream.cut_off else "")
    return segments, error, time.monotonic() - started, sink.partials


def trial(session: str, from_ms: int, to_ms: int, translate_to: str) -> None:
    from api import live_store, live_ws
    audio = live_ws.pcm_for_range(session, from_ms, to_ms, "")
    if audio is None:
        print("no stored audio covers that window")
        return
    pcm, rate = audio
    print(f"window {from_ms}-{to_ms} ms of {session[:8]}: {len(pcm) / (2.0 * rate):.1f} s at {rate} Hz\n")

    print("LIVE STORED")
    for row in live_store.segment_range(session, from_ms, to_ms):
        extra = f"  → {row['translation']}" if row.get("translation") else ""
        print(f"  [{row.get('lang') or '?'}] {row['text']}{extra}")

    result, took = _local(pcm, rate)
    print(f"\nLOCAL ({took:.1f} s)")
    print(f"  {result.get('transcript') if result.get('success') else 'failed: ' + str(result.get('error'))}")

    segments, error, took, partials = _soniox(pcm, rate, from_ms, translate_to)
    print(f"\nSONIOX ({took:.1f} s, {partials} partial updates)")
    if segments is None:
        print(f"  unavailable: {error}")
        return
    if error:
        print(f"  error: {error}")
    for seg in segments:
        extra = f"  → {seg.translation}" if seg.translation else ""
        print(f"  [{seg.language or '?'}] spk {seg.speaker or '-'} {seg.start_ms}-{seg.end_ms}: {seg.text}{extra}")


def usage() -> None:
    """Speech per day over the last 30 days: what Soniox on Live would bill, roughly."""
    from api import live_store
    since = time.time() - 30 * 86400
    per_day = {}
    with live_store.connect() as conn:
        rows = conn.execute(
            "SELECT s.started_at AS started, g.ts_start_ms AS a, g.ts_end_ms AS b"
            " FROM live_segment g JOIN live_session s ON s.id = g.live_session_id"
            " WHERE s.started_at >= ?", (since,)).fetchall()
    for row in rows:
        day = dt.datetime.fromtimestamp(row["started"] + row["a"] / 1000.0, dt.timezone.utc).date()
        per_day[day] = per_day.get(day, 0.0) + max(0, row["b"] - row["a"]) / 1000.0
    if not per_day:
        print("no Live speech in the last 30 days")
        return
    for day in sorted(per_day):
        print(f"  {day}  {per_day[day] / 3600:.2f} h of speech")
    hours = sum(per_day.values()) / 3600
    days = max(1, len(per_day))
    # Streams stay open through short pauses and close after the quiet timeout,
    # so billed time is speech plus some slack; 1.5x brackets it.
    print(f"\n{hours:.1f} h of speech over {days} active days "
          f"≈ ${hours * 0.12:.2f}–${hours * 1.5 * 0.12:.2f} for those days on Soniox "
          f"(${hours / days * 30 * 0.12:.2f}–${hours / days * 30 * 1.5 * 0.12:.2f}/month at that pace)")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--session")
    parser.add_argument("--from-ms", type=int, default=0)
    parser.add_argument("--to-ms", type=int, default=0)
    parser.add_argument("--translate", default="", help="target language, e.g. en")
    parser.add_argument("--usage", action="store_true")
    args = parser.parse_args()
    if args.usage:
        usage()
    elif args.session and args.to_ms > args.from_ms:
        trial(args.session, args.from_ms, args.to_ms, args.translate)
    else:
        parser.error("--session with --from-ms < --to-ms, or --usage")


if __name__ == "__main__":
    main()
