"""Replays of browser sessions: a CDP screencast → an MP4 the chat card plays.

For cloud and server-Chrome sessions a recorder attaches its *own* CDP client,
runs ``Page.startScreencast`` (JPEG) on every page, acks each frame and keeps it
with its timestamp in a temp dir. When the session ends the frames become an MP4
(ffmpeg concat demuxer, each frame shown for as long as it was on screen, long
idle stretches capped) at ``get_hermes_home()/browser/replays/<id>.mp4``.

One recorder per browser session id. A session that moves (server Chrome → cloud)
re-attaches to the new browser and keeps filling the same timeline.

Never breaks the task: no ffmpeg, a provider that refuses a second CDP client, or a
socket that drops all end in ``replay_status = failed`` with a reason, nothing more.
"""
from __future__ import annotations

import base64
import json
import logging
import shutil
import subprocess
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

from tools import browser_sessions

logger = logging.getLogger(__name__)

JPEG_QUALITY = 60
MAX_WIDTH = 1280
MAX_HEIGHT = 1280
MIN_FRAME_GAP_S = 0.1          # ~10 fps is plenty for a replay
MAX_FRAMES = 6000              # ~10 min of constant motion
MAX_FRAME_HOLD_S = 3.0         # idle stretches play back short
LAST_FRAME_HOLD_S = 1.5
OUTPUT_FPS = 10
ENCODE_TIMEOUT_S = 300

_recorders: Dict[str, "SessionRecorder"] = {}
_lock = threading.Lock()


def _default_connect(url: str):
    from websockets.sync.client import connect
    return connect(url, max_size=None, open_timeout=10, close_timeout=2)


def jpeg_size(data: bytes) -> Optional[Tuple[int, int]]:
    """(width, height) of a JPEG from its SOF marker, or None."""
    i = 2
    n = len(data)
    if n < 4 or data[0] != 0xFF or data[1] != 0xD8:
        return None
    while i + 9 < n:
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            i += 2
            continue
        length = int.from_bytes(data[i + 2:i + 4], "big")
        if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
            height = int.from_bytes(data[i + 5:i + 7], "big")
            width = int.from_bytes(data[i + 7:i + 9], "big")
            return (width, height) if width and height else None
        i += 2 + length
    return None


class _CdpSource:
    """One CDP connection streaming screencast frames into a recorder."""

    def __init__(self, recorder: "SessionRecorder", cdp_url: str, connect: Callable[[str], Any]):
        self.recorder = recorder
        self.cdp_url = cdp_url
        self._connect = connect
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, name=f"browser-rec-{recorder.session_id}", daemon=True)
        self._next_id = 0
        self._pending: Dict[int, str] = {}   # request id → what it was for
        self._attached: set = set()

    def start(self) -> None:
        self._thread.start()

    def stop(self, wait: float = 3.0) -> None:
        self._stop.set()
        if self._thread.is_alive() and threading.current_thread() is not self._thread:
            self._thread.join(timeout=wait)

    def _send(self, ws, method: str, params: Optional[Dict[str, Any]] = None,
              session_id: Optional[str] = None, purpose: str = "") -> int:
        self._next_id += 1
        msg: Dict[str, Any] = {"id": self._next_id, "method": method, "params": params or {}}
        if session_id:
            msg["sessionId"] = session_id
        if purpose:
            self._pending[self._next_id] = purpose
        ws.send(json.dumps(msg))
        return self._next_id

    def _attach(self, ws, target: Dict[str, Any]) -> None:
        tid = target.get("targetId")
        if not tid or target.get("type") != "page" or tid in self._attached:
            return
        self._attached.add(tid)
        self._send(ws, "Target.attachToTarget", {"targetId": tid, "flatten": True}, purpose="attach")

    def _start_screencast(self, ws, cdp_session: str) -> None:
        self._send(ws, "Page.enable", session_id=cdp_session)
        self._send(ws, "Page.startScreencast", {
            "format": "jpeg", "quality": JPEG_QUALITY,
            "maxWidth": MAX_WIDTH, "maxHeight": MAX_HEIGHT, "everyNthFrame": 1,
        }, session_id=cdp_session, purpose="screencast")

    def handle(self, ws, msg: Dict[str, Any]) -> None:
        """React to one CDP message (exposed for tests)."""
        if "id" in msg:
            purpose = self._pending.pop(msg["id"], "")
            if "error" in msg:
                if purpose in ("attach", "screencast", "targets"):
                    self.recorder.note_error(f"CDP {purpose} refused: {msg['error'].get('message', msg['error'])}")
                return
            result = msg.get("result") or {}
            if purpose == "targets":
                for target in result.get("targetInfos") or []:
                    self._attach(ws, target)
            elif purpose == "attach" and result.get("sessionId"):
                self._start_screencast(ws, result["sessionId"])
            return
        method = msg.get("method")
        params = msg.get("params") or {}
        if method == "Page.screencastFrame":
            self._send(ws, "Page.screencastFrameAck", {"sessionId": params.get("sessionId")},
                       session_id=msg.get("sessionId"))
            data = params.get("data")
            if data:
                ts = (params.get("metadata") or {}).get("timestamp") or time.time()
                try:
                    self.recorder.add_frame(base64.b64decode(data), float(ts))
                except Exception:
                    logger.debug("bad screencast frame", exc_info=True)
        elif method == "Target.targetCreated":
            self._attach(ws, params.get("targetInfo") or {})
        elif method == "Target.attachedToTarget":
            info = params.get("targetInfo") or {}
            sid = params.get("sessionId")
            if sid and info.get("type") == "page" and info.get("targetId") not in self._attached:
                self._attached.add(info.get("targetId"))
                self._start_screencast(ws, sid)

    def _run(self) -> None:
        try:
            ws = self._connect(self.cdp_url)
        except Exception as exc:
            self.recorder.note_error(f"could not attach a recorder to the browser ({exc})")
            return
        try:
            self._send(ws, "Target.setDiscoverTargets", {"discover": True})
            self._send(ws, "Target.getTargets", purpose="targets")
            while not self._stop.is_set():
                try:
                    raw = ws.recv(timeout=0.5)
                except TimeoutError:
                    continue
                try:
                    msg = json.loads(raw)
                except (TypeError, ValueError):
                    continue
                if isinstance(msg, dict):
                    self.handle(ws, msg)
        except Exception as exc:
            if not self._stop.is_set():
                self.recorder.note_error(f"the recorder's browser connection dropped ({exc})")
        finally:
            try:
                ws.close()
            except Exception:
                pass


class SessionRecorder:
    """Frames of one browser session, and its MP4 when it ends."""

    def __init__(self, session_id: str, connect: Callable[[str], Any] = _default_connect):
        self.session_id = session_id
        self._connect = connect
        self.frames_dir = Path(tempfile.mkdtemp(prefix=f"jc-replay-{session_id}-"))
        self.frames: List[Tuple[Path, float]] = []
        self.errors: List[str] = []
        self._source: Optional[_CdpSource] = None
        self._lock = threading.Lock()
        self._last_ts = 0.0
        self.finished = False

    # -- frames ---------------------------------------------------------------

    def add_frame(self, jpeg: bytes, ts: float) -> None:
        with self._lock:
            if self.finished or len(self.frames) >= MAX_FRAMES:
                return
            if self.frames and ts - self._last_ts < MIN_FRAME_GAP_S:
                return
            path = self.frames_dir / f"f{len(self.frames):05d}.jpg"
            path.write_bytes(jpeg)
            first = not self.frames
            self.frames.append((path, ts))
            self._last_ts = ts
        if first:
            browser_sessions.update(self.session_id, replay_status="recording", replay_error=None)

    def note_error(self, text: str) -> None:
        logger.info("browser replay %s: %s", self.session_id, text)
        with self._lock:
            self.errors.append(text)
            no_frames = not self.frames
        if no_frames:
            browser_sessions.update(self.session_id, replay_status="failed", replay_error=text[:300])

    # -- sources --------------------------------------------------------------

    def attach(self, cdp_url: str) -> None:
        if not cdp_url or self.finished:
            return
        if self._source is not None and self._source.cdp_url == cdp_url:
            return
        self.detach()
        self._source = _CdpSource(self, cdp_url, self._connect)
        self._source.start()

    def detach(self) -> None:
        source, self._source = self._source, None
        if source is not None:
            source.stop()

    # -- the MP4 --------------------------------------------------------------

    def finish(self, *, background: bool = True) -> None:
        """Stop recording and encode; ``background`` encodes on a thread."""
        with self._lock:
            if self.finished:
                return
            self.finished = True
        self.detach()
        if background:
            threading.Thread(target=self._encode_safely, name=f"browser-enc-{self.session_id}",
                             daemon=True).start()
        else:
            self._encode_safely()

    def _encode_safely(self) -> None:
        try:
            self.encode()
        except Exception as exc:
            logger.warning("browser replay %s: encoding failed", self.session_id, exc_info=True)
            browser_sessions.update(self.session_id, replay_status="failed", replay_error=f"encoding failed ({exc})"[:300])
        finally:
            shutil.rmtree(self.frames_dir, ignore_errors=True)

    def holds(self) -> List[float]:
        """How long each frame stays on screen in the replay."""
        out = []
        for i, (_path, ts) in enumerate(self.frames):
            hold = self.frames[i + 1][1] - ts if i + 1 < len(self.frames) else LAST_FRAME_HOLD_S
            out.append(min(max(hold, 1.0 / OUTPUT_FPS), MAX_FRAME_HOLD_S))
        return out

    def concat_list(self) -> str:
        """The ffconcat script: each frame for as long as it was on screen."""
        lines = ["ffconcat version 1.0"]
        for (path, _ts), hold in zip(self.frames, self.holds()):
            lines.append(f"file '{path.name}'")
            lines.append(f"duration {hold:.3f}")
        if self.frames:
            # ffmpeg drops the final entry's duration: a closing repeat carries the
            # last frame, and the encode is cut at the real total (``-t``).
            lines.append(f"file '{self.frames[-1][0].name}'")
            lines.append(f"duration {1.0 / OUTPUT_FPS:.3f}")
        return "\n".join(lines) + "\n"

    def encode(self) -> Optional[Path]:
        if not self.frames:
            reason = self.errors[0] if self.errors else "nothing was on screen to record"
            browser_sessions.update(self.session_id, replay_status="failed", replay_error=reason[:300])
            return None
        ffmpeg = shutil.which("ffmpeg")
        if not ffmpeg:
            browser_sessions.update(self.session_id, replay_status="failed",
                                    replay_error="ffmpeg is not installed on the server")
            return None
        browser_sessions.update(self.session_id, replay_status="encoding", replay_error=None)
        size = jpeg_size(self.frames[0][0].read_bytes()) or (MAX_WIDTH, 800)
        width = min(size[0], MAX_WIDTH) // 2 * 2
        height = max(2, int(size[1] * width / max(size[0], 1)) // 2 * 2)
        list_path = self.frames_dir / "frames.ffconcat"
        list_path.write_text(self.concat_list(), encoding="utf-8")
        out = browser_sessions.replay_path(self.session_id)
        tmp = out.with_suffix(".part.mp4")
        vf = (f"scale={width}:{height}:force_original_aspect_ratio=decrease,"
              f"pad={width}:{height}:(ow-iw)/2:(oh-ih)/2,fps={OUTPUT_FPS},format=yuv420p")
        cmd = [ffmpeg, "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", str(list_path),
               "-vf", vf, "-c:v", "libx264", "-preset", "veryfast", "-crf", "28",
               "-t", f"{sum(self.holds()):.3f}", "-movflags", "+faststart", str(tmp)]
        proc = subprocess.run(cmd, cwd=str(self.frames_dir), capture_output=True, text=True,
                              timeout=ENCODE_TIMEOUT_S)
        if proc.returncode != 0 or not tmp.exists() or tmp.stat().st_size == 0:
            tmp.unlink(missing_ok=True)
            err = (proc.stderr or "").strip().splitlines()[-1:] or ["no output"]
            browser_sessions.update(self.session_id, replay_status="failed",
                                    replay_error=f"ffmpeg failed: {err[0]}"[:300])
            return None
        tmp.replace(out)
        browser_sessions.update(self.session_id, replay_status="ready", replay_error=None)
        browser_sessions.prune_replays()
        return out


# ---------------------------------------------------------------------------
# Per-session registry (this process)
# ---------------------------------------------------------------------------

def attach(session_id: str, cdp_url: str) -> None:
    """Record ``session_id`` from ``cdp_url`` (re-attaching if it moved). Never raises."""
    try:
        with _lock:
            rec = _recorders.get(session_id)
            if rec is None or rec.finished:
                rec = SessionRecorder(session_id)
                _recorders[session_id] = rec
        rec.attach(cdp_url)
    except Exception as exc:
        logger.debug("browser recorder attach for %s failed: %s", session_id, exc)


def is_recording(session_id: str) -> bool:
    with _lock:
        rec = _recorders.get(session_id)
    return bool(rec and not rec.finished and rec._source is not None)


def detach(session_id: str) -> None:
    with _lock:
        rec = _recorders.get(session_id)
    if rec is not None:
        rec.detach()


def finish(session_id: str, *, background: bool = True) -> None:
    """The session ended: stop and encode its replay. Never raises."""
    with _lock:
        rec = _recorders.pop(session_id, None)
    if rec is None:
        return
    try:
        rec.finish(background=background)
    except Exception as exc:
        logger.debug("browser recorder finish for %s failed: %s", session_id, exc)
