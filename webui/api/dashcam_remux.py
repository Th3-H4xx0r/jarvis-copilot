"""Lossless MPEG-TS -> MP4 remux of dashcam clips with ffmpeg (stream copy, nothing re-encoded).

The Affver A4 records MPEG transport streams, which AVPlayer, most browsers and Drive's previewer
can't play. Rewrapping the same H.264/H.265 frames and AAC audio into an MP4 takes a second or two
for a 100 MB clip::

    ffprobe -v error -show_entries stream=codec_type,codec_name -of json in.ts
    ffmpeg -nostdin -v error -y -i in.ts -map 0:v -map 0:a? -c copy [-bsf:a aac_adtstoasc]
           -movflags +faststart [-tag:v hvc1] -f mp4 out

- ``-map 0:v -map 0:a?`` drops the camera's private data streams (the Viidure GPS packets; the phone
  sends GPS separately). ``+faststart`` puts the index first so a player starts before the end.
- ``hvc1`` (only for HEVC) is the sample entry Apple's players need for H.265 in MP4.
- ``aac_adtstoasc`` only when the audio is AAC: on any other codec the filter refuses to start.

ffmpeg/ffprobe are looked up on PATH; without them nothing is remuxed (warned once) and the caller
keeps the ``.ts``. Every failure is returned, never raised, and leaves no output behind.
"""
from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
import threading
from pathlib import Path

logger = logging.getLogger(__name__)

PROBE_TIMEOUT_S = 30
REMUX_TIMEOUT_S = 300          # ~1-2 s for a 100 MB clip; generous for a slow disk
_ERR_MAX = 300
NOT_INSTALLED = "ffmpeg is not installed"

_warned_missing = False
_warn_lock = threading.Lock()


def tools() -> tuple[str, str] | None:
    """(ffmpeg, ffprobe) from PATH, or None - logged once per process - when either is missing."""
    global _warned_missing
    ffmpeg, ffprobe = shutil.which("ffmpeg"), shutil.which("ffprobe")
    if ffmpeg and ffprobe:
        return ffmpeg, ffprobe
    with _warn_lock:
        if not _warned_missing:
            _warned_missing = True
            logger.warning("dashcam: ffmpeg/ffprobe not found on PATH; .ts clips are kept as MPEG-TS "
                           "(install ffmpeg to remux them to MP4)")
    return None


def is_ts(name) -> bool:
    return str(name or "").lower().endswith(".ts")


def mp4_name(name: str) -> str:
    """``2026-10-02_13_19_31_f.ts`` -> ``2026-10-02_13_19_31_f.mp4`` (other names unchanged)."""
    return name[:-3] + ".mp4" if is_ts(name) else name


def _tail(text) -> str:
    text = (text or "").strip() if isinstance(text, str) else ""
    return text[-_ERR_MAX:] or "no output"


def probe(ffprobe: str, src: Path) -> tuple[dict[str, list[str]] | None, str | None]:
    """``({"video": [codec, ...], "audio": [...]}, None)`` or ``(None, why)``."""
    try:
        out = subprocess.run([ffprobe, "-v", "error", "-show_entries", "stream=codec_type,codec_name",
                              "-of", "json", str(src)], stdin=subprocess.DEVNULL, capture_output=True,
                             text=True, timeout=PROBE_TIMEOUT_S)
    except subprocess.TimeoutExpired:
        return None, f"ffprobe timed out after {PROBE_TIMEOUT_S} s"
    except OSError as exc:
        return None, f"ffprobe could not run: {exc}"
    if out.returncode != 0:
        return None, f"ffprobe failed: {_tail(out.stderr)}"
    try:
        streams = json.loads(out.stdout or "{}").get("streams") or []
    except (ValueError, AttributeError):
        return None, "ffprobe answered with something that is not JSON"
    codecs: dict[str, list[str]] = {"video": [], "audio": []}
    for s in streams if isinstance(streams, list) else []:
        if isinstance(s, dict) and s.get("codec_type") in codecs:
            codecs[s["codec_type"]].append(str(s.get("codec_name") or ""))
    if not codecs["video"]:
        return None, "no video stream"
    return codecs, None


def remux(src: Path, dst: Path) -> str | None:
    """Rewraps ``src`` into an MP4 at ``dst`` (overwritten). None on success, else why it failed -
    ffmpeg missing, a corrupt or truncated clip - with ``dst`` removed."""
    found = tools()
    if found is None:
        return NOT_INSTALLED
    ffmpeg, ffprobe = found
    src, dst = Path(src), Path(dst)
    codecs, why = probe(ffprobe, src)
    if codecs is None:
        return why
    cmd = [ffmpeg, "-nostdin", "-v", "error", "-y", "-i", str(src), "-map", "0:v", "-map", "0:a?", "-c", "copy"]
    if codecs["audio"] and all(c == "aac" for c in codecs["audio"]):
        cmd += ["-bsf:a", "aac_adtstoasc"]
    cmd += ["-movflags", "+faststart"]
    if codecs["video"][0] == "hevc":
        cmd += ["-tag:v", "hvc1"]
    cmd += ["-f", "mp4", str(dst)]
    try:
        out = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                             timeout=REMUX_TIMEOUT_S)
        if out.returncode != 0:
            why = f"ffmpeg failed: {_tail(out.stderr)}"
        elif not dst.is_file() or dst.stat().st_size == 0:
            why = "ffmpeg wrote nothing"
    except subprocess.TimeoutExpired:
        why = f"ffmpeg timed out after {REMUX_TIMEOUT_S} s"
    except OSError as exc:
        why = f"ffmpeg could not run: {exc}"
    if why is not None:
        try:
            os.unlink(dst)
        except OSError:
            pass
    return why
