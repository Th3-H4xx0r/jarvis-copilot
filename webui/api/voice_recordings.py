"""Saved voice turns from the Jarvis Pod.

Every turn the pod streams (the decoded 16 kHz mono PCM the server transcribes)
is kept as a WAV next to its transcript, per device, so the phone's pod page can
list and play them. Kept 30 days, at most 2000 per device.

    STATE_DIR/voice_recordings/<device_id>/<id>.wav
    STATE_DIR/voice_recordings/<device_id>/index.json
        {"recordings": [{"id": "1757900000123", "ts": 1757900000.123,
                         "duration_ms": 2400, "transcript": "..."}]}   newest first
"""
from __future__ import annotations

import json
import re
import sys
import threading
import time
import urllib.parse
import wave
from pathlib import Path
from typing import Optional

from api.config import STATE_DIR

RECORDINGS_DIR = STATE_DIR / "voice_recordings"
MAX_AGE_SECONDS = 30 * 24 * 3600
# What the speech engine heard, beside the (noise-suppressed) copy the phone plays:
# recognition can only be judged on this. Kept a week.
RAW_MAX_AGE_SECONDS = 7 * 24 * 3600
MAX_PER_DEVICE = 2000
_MIN_PCM_BYTES = 1000

_LOCK = threading.Lock()
_DEVICE_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
_REC_ID = re.compile(r"^[0-9]{10,20}$")


def _device_dir(device_id: str) -> Optional[Path]:
    if not _DEVICE_ID.match(device_id or ""):
        return None
    return RECORDINGS_DIR / device_id


def _read_index(d: Path) -> list[dict]:
    try:
        data = json.loads((d / "index.json").read_text())
        recs = data.get("recordings") if isinstance(data, dict) else None
        return [r for r in recs if isinstance(r, dict)] if isinstance(recs, list) else []
    except Exception:
        return []


def _write_index(d: Path, recs: list[dict]) -> None:
    tmp = d / "index.json.tmp"
    tmp.write_text(json.dumps({"recordings": recs}, ensure_ascii=False))
    tmp.replace(d / "index.json")


def audio_levels(pcm: bytes, sample_rate: int) -> dict:
    """Speech level, noise floor and their gap (dBFS, 20 ms frames): how far and how
    noisy a turn was, for judging recognition against distance."""
    import array
    import math
    samples = array.array("h", pcm[: len(pcm) - len(pcm) % 2])
    if sys.byteorder != "little":
        samples.byteswap()
    frame = max(1, sample_rate // 50)
    dbs = []
    for i in range(0, len(samples) - frame + 1, frame):
        chunk = samples[i:i + frame]
        rms = math.sqrt(sum(v * v for v in chunk) / frame) / 32768.0
        dbs.append(20 * math.log10(rms + 1e-9))
    if not dbs:
        return {"speech_db": -120.0, "floor_db": -120.0, "snr_db": 0.0}
    dbs.sort()
    floor, speech = dbs[int(len(dbs) * 0.1)], dbs[min(len(dbs) - 1, int(len(dbs) * 0.95))]
    return {"speech_db": round(speech, 1), "floor_db": round(floor, 1), "snr_db": round(speech - floor, 1)}


def _write_wav(path: Path, pcm: bytes, sample_rate: int) -> None:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sample_rate)
        w.writeframes(pcm)


def save(device_id: str, pcm: bytes, sample_rate: int, transcript: str, now: Optional[float] = None,
         cleaned: bool = False, raw: Optional[bytes] = None) -> Optional[dict]:
    """Store one turn; returns its index entry, or None when there's nothing to keep.
    ``raw`` is the audio the speech engine got, kept a week beside ``pcm``."""
    d = _device_dir(device_id)
    if d is None or len(pcm) < _MIN_PCM_BYTES or sample_rate <= 0:
        return None
    now = time.time() if now is None else now
    pcm = pcm[: len(pcm) - (len(pcm) % 2)]
    with _LOCK:
        d.mkdir(parents=True, exist_ok=True)
        recs = _read_index(d)
        rec_id = str(int(now * 1000))
        while any(r.get("id") == rec_id for r in recs):
            rec_id = str(int(rec_id) + 1)
        _write_wav(d / f"{rec_id}.wav", pcm, sample_rate)
        entry = {
            "id": rec_id,
            "ts": round(now, 3),
            "duration_ms": int(len(pcm) / 2 / sample_rate * 1000),
            "transcript": (transcript or "").strip()[:2000],
            "cleaned": cleaned,
        }
        if raw is not None and cleaned and len(raw) >= _MIN_PCM_BYTES:
            raw = raw[: len(raw) - (len(raw) % 2)]
            _write_wav(d / f"{rec_id}.raw.wav", raw, sample_rate)
            entry["raw"] = True
        # Uncleaned, the recording itself is what the engine heard.
        entry["levels"] = audio_levels(raw if entry.get("raw") else pcm, sample_rate)
        recs.insert(0, entry)
        keep = [r for r in recs if now - float(r.get("ts") or 0) <= MAX_AGE_SECONDS][:MAX_PER_DEVICE]
        kept_ids = {r.get("id") for r in keep}
        for r in recs:
            if r.get("id") not in kept_ids and _REC_ID.match(str(r.get("id") or "")):
                (d / f"{r['id']}.wav").unlink(missing_ok=True)
                (d / f"{r['id']}.raw.wav").unlink(missing_ok=True)
        for r in keep:
            if r.get("raw") and now - float(r.get("ts") or 0) > RAW_MAX_AGE_SECONDS:
                (d / f"{r['id']}.raw.wav").unlink(missing_ok=True)
                r["raw"] = False
        _write_index(d, keep)
    return entry


def save_async(device_id: str, pcm: bytes, sample_rate: int, transcript: str,
               noise_cancel: bool = False) -> None:
    """Fire-and-forget: a turn never waits on the disk (or on noise suppression)."""
    def _run():
        audio, cleaned = pcm, False
        if noise_cancel:
            from api import voice_denoise
            out = voice_denoise.clean(device_id, pcm, sample_rate)
            if out:
                audio, cleaned = out, True
        save(device_id, audio, sample_rate, transcript, cleaned=cleaned, raw=pcm)

    threading.Thread(target=_run, name="voice-recording", daemon=True).start()


def list_recordings(device_id: str) -> list[dict]:
    d = _device_dir(device_id)
    if d is None:
        return []
    with _LOCK:
        return _read_index(d)


def audio_path(device_id: str, rec_id: str) -> Optional[Path]:
    d = _device_dir(device_id)
    if d is None or not _REC_ID.match(rec_id or ""):
        return None
    p = d / f"{rec_id}.wav"
    return p if p.is_file() else None


def delete(device_id: str, rec_id: str) -> bool:
    d = _device_dir(device_id)
    if d is None or not _REC_ID.match(rec_id or ""):
        return False
    with _LOCK:
        recs = _read_index(d)
        left = [r for r in recs if r.get("id") != rec_id]
        if len(left) == len(recs):
            return False
        (d / f"{rec_id}.wav").unlink(missing_ok=True)
        (d / f"{rec_id}.raw.wav").unlink(missing_ok=True)
        _write_index(d, left)
    return True


def raw_path(device_id: str, rec_id: str) -> Optional[Path]:
    """What the speech engine heard for this turn, while it is still kept."""
    d = _device_dir(device_id)
    if d is None or not _REC_ID.match(rec_id or ""):
        return None
    p = d / f"{rec_id}.raw.wav"
    return p if p.exists() else None


# ── HTTP ─────────────────────────────────────────────────────────────────────

def handle_get(handler, parsed) -> bool:
    """GET /api/devices/pod/recordings?device_id=  and  .../recordings/audio?device_id=&id="""
    from api.helpers import j

    qs = urllib.parse.parse_qs(parsed.query)
    device_id = (qs.get("device_id") or [""])[0]
    if parsed.path.endswith("/audio"):
        p = audio_path(device_id, (qs.get("id") or [""])[0])
        if p is None:
            j(handler, {"error": "recording not found"}, status=404)
            return True
        body = p.read_bytes()
        handler.send_response(200)
        handler.send_header("Content-Type", "audio/wav")
        handler.send_header("Content-Length", str(len(body)))
        handler.send_header("Cache-Control", "private, max-age=86400")
        handler.end_headers()
        handler.wfile.write(body)
        return True
    if _device_dir(device_id) is None:
        j(handler, {"error": "device_id is required"}, status=400)
        return True
    j(handler, {"recordings": list_recordings(device_id)})
    return True


def handle_delete(handler, body: dict) -> bool:
    """POST /api/devices/pod/recordings/delete  {device_id, id}"""
    from api.helpers import j

    ok = delete(str(body.get("device_id") or ""), str(body.get("id") or ""))
    j(handler, {"ok": ok}, status=200 if ok else 404)
    return True
