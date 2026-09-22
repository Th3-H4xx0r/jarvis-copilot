"""Live Jarvis protocol — the device-facing spine (design §2, §4, §8).

One endpoint family, ``/api/live/*``, on the existing threaded stdlib server with
``wsproto``, one thread per socket, bounded per-connection buffers — the same
shape as ``/api/voice/s2s/ws``. Not a new server stack.

Three ideas carry the whole file:

* **Lane assignment is the extensibility seam.** A device gets ``lane:"edge"``
  only when it does STT on-device *and* declares the embedding-model id the
  server is using. Everything else gets ``lane:"server"`` and just streams
  audio, so a future device joins by declaring less and no server code changes.
  A mismatched ``embed_model`` costs a device its lane on purpose: comparing
  vectors from two checkpoints is meaningless rather than imprecise, so the
  failure has to be loud and early instead of silently corrupting identity.

* **``seq`` lives in the payload, never in the frame id.** iOS's ``SSEParser``
  drops ``id:`` lines, so a cursor in the envelope is useless to the client that
  needs it most. Resume is ``after_seq`` over the same number.

* **Capture is the floor** (§8). A watcher that raises, a paired chat that fails
  to create, a full disk, a locked database — none of them may stop the
  transcript or close the socket holding the client's backlog. Everything
  optional here is wrapped, and the wrapping is the feature.

**One time base.** Every ``ts_start_ms`` / ``ts_end_ms`` / ``ts_ms`` on the wire
and in the store is **milliseconds since ``live_session.started_at``**. A client
may send an absolute epoch timestamp and the server normalises it; it may send
nothing and the server stamps it. This is not a style preference: per-voice audio
deletion places a voice by overlapping segment time against chunk time, so a
transcript in session offsets against audio in epoch milliseconds matched
nothing, and "delete every recording this voice is in" answered 200 with
``chunks_deleted: 0`` while the audio sat on disk. One base, normalised on the
way in, is what makes that promise true.

``LiveConnection`` holds the protocol state and knows nothing about sockets: it
takes a ``send`` callable. That is what makes the handshake and all four
ingestion shapes testable without a socket, and it is why the wsproto pump below
is thin enough to read in one screen.
"""
from __future__ import annotations

import base64
import binascii
import json
import logging
import atexit
import queue
import re
import struct
import threading
import time
import uuid
from collections import OrderedDict
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple
from urllib.parse import parse_qs

from api import live_config, live_store
from api.helpers import bad, j
from api.session_events import SessionEventBus

logger = logging.getLogger(__name__)

LIVE_WS_PATH = "/api/live/ws"

# A second bus instance, keyed by live_session_id. Same machinery as the chat
# mirror's SESSION_EVENTS (no offline buffer, bounded queues, resync on drop) —
# a separate instance only so a live session id can never collide with a chat
# session id in one keyspace.
LIVE_EVENTS = SessionEventBus()

LANE_EDGE = "edge"
LANE_SERVER = "server"

# ``[4B big-endian seq][8B big-endian ts_ms][payload]``. A fixed header keeps
# audio timing correct across reordering and gaps without a second channel.
_AUDIO_HEADER = struct.Struct(">IQ")
AUDIO_HEADER_BYTES = _AUDIO_HEADER.size

# Sized like voice.py's _WS_BUFFER_LIMIT_BYTES: enough that normal operation
# never touches it, small enough that a wedged disk cannot grow server memory
# without limit. Reached only when flushing to disk keeps failing.
_WS_AUDIO_BUFFER_LIMIT_BYTES = 4 * 1024 * 1024
# Write amplification control, not a memory bound: one file write per ~64 KB of
# audio rather than one per 20 ms packet.
_AUDIO_FLUSH_BYTES = 64 * 1024
# ~5-minute chunks (design §3): deletes stay granular and a crash costs one chunk.
_AUDIO_CHUNK_SECONDS = 300

_SSE_HEARTBEAT_INTERVAL_SECONDS = 5
_FANOUT_POLL_SECONDS = 1.0
_TRANSCRIPT_LIMIT_MAX = 1000

# Long-lived SSE and WS connections end this way whenever a tab sleeps or a
# phone changes network. Not errors.
_CLIENT_DISCONNECT_ERRORS = (
    BrokenPipeError, ConnectionResetError, ConnectionAbortedError,
    TimeoutError, OSError,
)

# The paired chat's marker. `Session` has no `kind` field and swallows unknown
# kwargs, so a made-up attribute would be dropped on the first reload;
# `source_tag` is a real, persisted field and is how api/voice.py marks its own
# dedicated chat.
LIVE_SOURCE_TAG = "live"

# A per-day delete names a LOCAL calendar day, matching how the storage panel
# groups rows. A malformed value would otherwise delete nothing and report
# success, which reads as "that day is gone" when it is not.
_DAY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

# Every id this API accepts is a uuid4 hex minted server-side. Validating that at
# the boundary is not decoration: `Path(root) / "/etc/x"` discards the root and
# `".."` climbs out of it, so an unchecked session id turns "delete this
# recording" into an rmdir elsewhere on the filesystem.
_ID_RE = re.compile(r"^[0-9a-f]{32}$")

# Client-controlled growth bounds. Each of these is reachable from one socket by
# a client that simply never finishes what it started.
_MAX_PARTIAL_TRACKS = 8          # concurrent unfinished utterances per socket
_MAX_PARTIAL_CHARS = 16 * 1024   # accumulated text before a partial:false
_MAX_SEGMENT_CHARS = 8 * 1024    # one stored utterance
_MAX_SEGMENTS_PER_REQUEST = 200  # one batch
_MAX_WRITERS_PER_SESSION = 8     # distinct capture devices on one conversation
_WRITER_IDLE_SECONDS = 15 * 60   # reap a writer nothing has written to
# An on-demand fact-check builds a whole AIAgent, so N concurrent requests are N
# concurrent agent runs. Two at a time is plenty for a human tapping segments.
_MAX_WATCHER_INFLIGHT = 2

# Anything at or above this is an absolute epoch timestamp, not a session offset:
# 1e12 ms is 2001, and a session offset that large would be a 31-year recording.
_EPOCH_THRESHOLD_MS = 1_000_000_000_000


class LiveDisabled(Exception):
    """`live.enabled` is off, so no NEW capture may start.

    Raised from `start_live_session` rather than checked at each call site: the
    gate belongs to the act of creating a session, so a future caller cannot
    forget it.
    """


def capture_enabled() -> bool:
    return bool(live_config.load().get("enabled"))


_sweep_done = False
_sweep_lock = threading.Lock()


def sweep_orphan_audio_once() -> Optional[Dict[str, Any]]:
    """Adopt audio files left by a crash mid-chunk. Once per process.

    A chunk gets its `live_audio` row when it rolls, so a crash leaves a real
    file no row knows about: invisible to the storage panel and missed by
    `delete_session`'s unlink, which is what made "delete this day" quietly
    leave audio behind. Safe to call from startup and idempotent; returns None
    if another caller already ran it.
    """
    global _sweep_done
    with _sweep_lock:
        if _sweep_done:
            return None
        _sweep_done = True
    try:
        result = live_store.sweep_orphan_audio()
    except Exception:
        # Startup housekeeping must never be able to stop the server.
        logger.warning("live orphan-audio sweep failed", exc_info=True)
        return None
    if result.get("adopted"):
        logger.info("live: adopted %s orphaned audio chunk(s), %s bytes",
                    result["adopted"], result["bytes"])
    return result


# ── lane assignment (design §2.1, §5.3) ────────────────────────────────────


def server_caps() -> Dict[str, Any]:
    """What this server can actually do, stated honestly.

    ``embed`` is False until the phase-5 embedding spike lands; claiming it
    would make a device trust server-side identification that does not exist.
    """
    return {
        "stt": _server_stt_available(),
        "embed": False,
        "embed_model": live_config.load()["embed_model"],
    }


_server_stt_cache: Optional[bool] = None


def _server_stt_available() -> bool:
    global _server_stt_cache
    if _server_stt_cache is None:
        try:
            from api.voice import _try_import_stt
            _server_stt_cache = bool(_try_import_stt())
        except Exception:
            _server_stt_cache = False
    return _server_stt_cache


def assign_lane(caps: Optional[Dict[str, Any]]) -> str:
    """Grant the edge lane only to a device the server can trust to label voices.

    All three conditions are the same condition: this device's vectors must be
    comparable with the ones already stored. On-device STT without an on-device
    embedder produces text with no voiceprint; a matching embedder id is what
    makes the voiceprint mean anything.
    """
    if not isinstance(caps, dict):
        return LANE_SERVER
    if str(caps.get("stt") or "").strip() != "on_device":
        return LANE_SERVER
    if str(caps.get("embed") or "").strip() != "on_device":
        return LANE_SERVER
    declared = str(caps.get("embed_model") or "").strip()
    expected = str(live_config.load()["embed_model"] or "").strip()
    if not declared or not expected or declared != expected:
        return LANE_SERVER
    return LANE_EDGE


# ── audio on disk ──────────────────────────────────────────────────────────


def _codec_profile(codec: str, rate: int) -> Dict[str, Any]:
    """How to store what the client is sending, and what to call it.

    Raw Opus packets are NOT a playable ``.opus`` file: Ogg/WebM framing is what
    makes one, and adding a container library would be a new dependency. So each
    packet is stored with a 4-byte big-endian length prefix, preserving the
    client's packet boundaries, and the codec recorded in ``live_audio`` says
    exactly that. Naming the file ``.opus`` would be a lie a future decoder
    would trip over.
    """
    name = str(codec or "").strip().lower()
    if name in ("", "pcm", "pcm16", "raw", "s16le", "pcm_s16le"):
        return {"ext": "pcm", "stored": f"pcm16@{int(rate)}", "framed": False}
    if name in ("opus", "opus-packets"):
        return {"ext": "opuspkt", "stored": f"opus-packets-len32@{int(rate)}",
                "framed": True}
    # Unknown codec: keep the bytes and the boundaries, and keep the client's
    # own name for it so nothing downstream has to guess.
    return {"ext": "bin", "stored": f"{name}-len32@{int(rate)}", "framed": True}


class _AudioWriter:
    """One rolling audio chunk for (session, device).

    The buffer is bounded and drops oldest on overflow. That only happens when
    the flush to disk keeps failing — §8's disk-full case — and it is reported as
    a ``state`` warning rather than swallowed, because silently losing hours is
    the outcome this whole design exists to prevent.
    """

    def __init__(self, live_session_id: str, device_id: str = "",
                 codec: str = "", rate: int = 16000) -> None:
        self.live_session_id = live_session_id
        self.device_id = device_id or ""
        self.profile = _codec_profile(codec, rate)
        self._lock = threading.Lock()
        self._buf = bytearray()
        self._path: Optional[Path] = None
        self._ts0_ms = 0
        self._ts1_ms = 0
        self._opened_at = 0.0
        self.last_write = time.time()
        self.dropped_bytes = 0
        self.refused = False

    def append(self, payload: bytes, ts_ms: int = 0) -> Dict[str, Any]:
        """Buffer one packet. Returns what the caller must tell the client."""
        if not payload:
            return {"dropped_bytes": 0, "rolled": None}
        rolled = None
        dropped = 0
        with self._lock:
            self.last_write = time.time()
            # One time base with the transcript, or per-voice audio deletion
            # matches nothing (see the module docstring).
            now_ms = to_offset_ms(self.live_session_id, ts_ms or None)
            if self._path is not None and self._should_roll():
                rolled = self._close_locked()
            if self._path is None and not self._open_locked(now_ms):
                # The session was deleted under us. Writing would recreate its
                # directory and register rows for a session row that no longer
                # exists — audio the user deleted, reachable by no delete path.
                return {"dropped_bytes": len(payload), "rolled": None,
                        "refused": "session_deleted"}
            self._ts1_ms = max(self._ts1_ms, now_ms)
            if self.profile["framed"]:
                self._buf.extend(struct.pack(">I", len(payload)))
            self._buf.extend(payload)
            if len(self._buf) >= _AUDIO_FLUSH_BYTES:
                self._flush_locked()
            if len(self._buf) > _WS_AUDIO_BUFFER_LIMIT_BYTES:
                # Cutting bytes off the front (the obvious "drop oldest") slices
                # mid-frame on a framed codec: the next flush appends half a
                # length prefix and every packet after it is undecodable, while
                # the file still claims `…-len32` framing. Losing one chunk with
                # intact framing on both sides is the honest trade.
                dropped = len(self._buf)
                self.dropped_bytes += dropped
                self._buf.clear()
                rolled = self._close_locked() or rolled
        return {"dropped_bytes": dropped, "rolled": rolled}

    def close(self) -> Optional[Dict[str, Any]]:
        with self._lock:
            return self._close_locked()

    # ── internals (caller holds the lock) ──

    def _should_roll(self) -> bool:
        """Wall clock only.

        Rolling on the CLIENT's timestamp let a client alternating a small and a
        huge ts_ms roll a chunk per packet — a file plus a `live_audio` row every
        20 ms. The clock that decides how much a crash costs has to be ours.
        """
        return bool(self._opened_at
                    and time.time() - self._opened_at >= _AUDIO_CHUNK_SECONDS)

    def _open_locked(self, now_ms: int) -> bool:
        if session_is_gone(self.live_session_id):
            self.refused = True
            return False
        self._ts0_ms = now_ms
        self._ts1_ms = now_ms
        self._opened_at = time.time()
        # A client sending a constant ts_ms made every chunk reuse one filename:
        # `open(…, "ab")` then appended, and each roll registered another row for
        # the same path with the cumulative size, so deleting any one row
        # unlinked the file the others pointed at. The suffix makes the name the
        # chunk's identity rather than the client's clock.
        stem = f"{now_ms}-{uuid.uuid4().hex[:8]}"
        if self.device_id:
            safe = "".join(c if c.isalnum() or c in "-_" else "-"
                           for c in self.device_id)[:40]
            stem = f"{now_ms}-{safe}-{uuid.uuid4().hex[:8]}"
        self._path = live_store.audio_dir(self.live_session_id) / \
            f"{stem}.{self.profile['ext']}"
        return True

    def _flush_locked(self) -> None:
        if self._path is None or not self._buf:
            return
        try:
            with open(self._path, "ab") as fh:
                fh.write(bytes(self._buf))
            self._buf.clear()
        except OSError:
            # Keep the bytes; the bound above decides when to give up on them.
            # Logged without the path: the filename carries the session and the
            # capturing device, and this line lands in a shared log.
            logger.warning("live audio flush failed (session %s…)",
                           self.live_session_id[:8], exc_info=True)

    def _close_locked(self) -> Optional[Dict[str, Any]]:
        if self._path is None:
            return None
        self._flush_locked()
        path, ts0, ts1 = self._path, self._ts0_ms, self._ts1_ms
        self._path = None
        self._buf.clear()
        self._ts0_ms = self._ts1_ms = 0
        self._opened_at = 0.0
        if not Path(path).exists():
            return None
        row = live_store.register_audio(
            self.live_session_id, path, codec=self.profile["stored"],
            ts0_ms=ts0, ts1_ms=ts1, device_id=self.device_id)
        return row


# One writer per (session, device) shared by the WS and the REST batch path, so
# a client that switches between them keeps appending to the same chunk.
_writers: Dict[Tuple[str, str], _AudioWriter] = {}
_writers_lock = threading.Lock()


class TooManyDevices(Exception):
    """More distinct capture devices on one session than anyone can be using."""


def writer_for(live_session_id: str, device_id: str = "", codec: str = "",
               rate: int = 16000) -> _AudioWriter:
    """The writer for (session, device), creating one within bounds.

    `device_id` comes from the client, and a REST-only client never closes
    anything, so an unbounded registry was a 4 MB buffer plus a file per made-up
    device name. Idle writers are reaped (which also registers their chunk, so
    nothing is lost) and the per-session count is capped.
    """
    # The codec is part of the key. Sharing one writer across encodings wrote
    # opus packets and raw PCM into a single file labelled with whichever arrived
    # first — a device declares opus in `hello` and then omits codec on a REST
    # batch, and the file becomes undecodable while claiming otherwise.
    profile = _codec_profile(codec, rate)
    key = (live_session_id, device_id or "", profile["stored"])
    stale: List[_AudioWriter] = []
    with _writers_lock:
        writer = _writers.get(key)
        if writer is None:
            cutoff = time.time() - _WRITER_IDLE_SECONDS
            for other_key, other in list(_writers.items()):
                if other_key != key and other.last_write < cutoff:
                    stale.append(_writers.pop(other_key))
            live = sum(1 for k in _writers if k[0] == live_session_id)
            if live >= _MAX_WRITERS_PER_SESSION:
                raise TooManyDevices(
                    f"at most {_MAX_WRITERS_PER_SESSION} capture devices per "
                    "live session")
            writer = _AudioWriter(live_session_id, device_id, codec, rate)
            _writers[key] = writer
    # Outside the registry lock: closing writes a file and a row.
    for old in stale:
        try:
            old.close()
        except Exception:
            logger.warning("closing an idle live audio writer failed",
                           exc_info=True)
    return writer


def close_writers(live_session_id: str = "") -> List[Dict[str, Any]]:
    """Flush and register the open chunks, for one session or all of them."""
    with _writers_lock:
        keys = [k for k in _writers
                if not live_session_id or k[0] == live_session_id]
        writers = [(k, _writers.pop(k)) for k in keys]
    rows = []
    for _key, writer in writers:
        try:
            row = writer.close()
        except Exception:
            logger.warning("closing live audio writer failed", exc_info=True)
            continue
        if row:
            rows.append(row)
    return rows


# Nothing else flushes these: the HTTP server runs daemon threads, so a graceful
# restart would otherwise discard whatever each writer still held in memory.
atexit.register(close_writers)


def ingest_audio_chunk(live_session_id: str, payload: bytes, *, ts_ms: int = 0,
                       device_id: str = "", codec: str = "",
                       rate: int = 16000) -> Dict[str, Any]:
    writer = writer_for(live_session_id, device_id, codec, rate)
    return writer.append(payload, ts_ms)


_started_ms_cache: "OrderedDict[str, int]" = OrderedDict()
_started_ms_lock = threading.Lock()
_MAX_STARTED_CACHE = 256


def session_started_ms(live_session_id: str) -> int:
    """`live_session.started_at` in ms, cached. 0 when the session is unknown."""
    with _started_ms_lock:
        cached = _started_ms_cache.get(live_session_id)
    if cached is not None:
        return cached
    try:
        row = live_store.get_session(live_session_id)
    except Exception:
        return 0
    if row is None:
        return 0
    started = int(float(row.get("started_at") or 0) * 1000)
    with _started_ms_lock:
        _started_ms_cache[live_session_id] = started
        _started_ms_cache.move_to_end(live_session_id)
        while len(_started_ms_cache) > _MAX_STARTED_CACHE:
            _started_ms_cache.popitem(last=False)
    return started


def to_offset_ms(live_session_id: str, raw: Any) -> int:
    """Normalise any timestamp a client sends to ms since the session started.

    Three inputs arrive here and all three have to land on one base, because
    per-voice audio deletion overlaps segment time against chunk time:

    * nothing at all — stamped from the wall clock, NOT left at 0, which matched
      no chunk and made a privacy delete a silent no-op;
    * an absolute epoch timestamp — converted;
    * an offset already — kept.
    """
    started = session_started_ms(live_session_id)
    if raw is None:
        return max(0, int(time.time() * 1000) - started) if started else 0
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return max(0, int(time.time() * 1000) - started) if started else 0
    if value >= _EPOCH_THRESHOLD_MS:
        return max(0, value - started) if started else value
    return max(0, value)


# Sessions deleted in this process. `writer_for`/`_open_locked` consult the store
# too (authoritative, and works across processes); this is the cheap first check.
_tombstones: "OrderedDict[str, float]" = OrderedDict()
_tombstones_lock = threading.Lock()
_MAX_TOMBSTONES = 512


def tombstone_session(live_session_id: str) -> None:
    with _tombstones_lock:
        _tombstones[live_session_id] = time.time()
        _tombstones.move_to_end(live_session_id)
        while len(_tombstones) > _MAX_TOMBSTONES:
            _tombstones.popitem(last=False)


def session_is_gone(live_session_id: str) -> bool:
    """True when opening a new chunk for this session would resurrect it.

    A still-connected client keeps streaming after the user deletes a recording.
    Opening a chunk then recreates the session's directory and registers rows
    for a session row that no longer exists — audio the user explicitly deleted,
    unreachable by every delete path, since the orphan sweep skips directories
    with no session row and there is no session left to delete.
    """
    with _tombstones_lock:
        if live_session_id in _tombstones:
            return True
    try:
        return live_store.get_session(live_session_id) is None
    except Exception:
        # Never let a store hiccup look like a deletion.
        return False


# ── watchers: optional by construction (design §8) ─────────────────────────


_watcher_hook_warned = False


def _notify_segment_appended(live_session_id: str, seq: int) -> None:
    """Tell the watchers a segment landed. Their failure is never ours.

    Imported lazily and on every call: ``api.live_watchers`` may not exist yet,
    may fail to import, or may raise. Capture is the floor, so all three are the
    same non-event here.
    """
    try:
        from api.live_watchers import on_segment_appended
        on_segment_appended(live_session_id, seq)
    except Exception:
        # Once at warning, then quiet: a syntax error in live_watchers.py
        # disables every watcher for the life of the process, and at debug that
        # was invisible. Per-segment noise afterwards would be its own problem.
        global _watcher_hook_warned
        if not _watcher_hook_warned:
            _watcher_hook_warned = True
            logger.warning(
                "live: watcher hook unavailable; monitor, memory and artifacts "
                "are OFF for this process (capture continues)", exc_info=True)
        else:
            logger.debug("live watcher on_segment_appended failed for %s/%s",
                         live_session_id, seq, exc_info=True)


def _notify_session_ended(live_session_id: str) -> None:
    try:
        from api.live_watchers import on_session_ended
        on_session_ended(live_session_id)
    except Exception:
        logger.debug("live watcher on_session_ended failed for %s",
                     live_session_id, exc_info=True)


# ── segments ───────────────────────────────────────────────────────────────


def publish(live_session_id: str, event: str,
            data: Optional[Dict[str, Any]] = None) -> None:
    """Fan one frame out to every device watching this live session."""
    try:
        LIVE_EVENTS.publish(live_session_id, event, dict(data or {}))
    except Exception:
        logger.warning("live fan-out failed for %s/%s", live_session_id, event,
                       exc_info=True)


# Which live sessions currently have a viewer. Both places that subscribe (the
# WS pump and the SSE endpoint) are in this module, so this stays accurate — and
# it is the right target set for a global announcement like a speaker rename,
# which must reach a viewer of ANY transcript, not just the most recent ones a
# session listing would return.
_viewers: Dict[str, int] = {}
_viewers_lock = threading.Lock()


def subscribe(live_session_id: str) -> "queue.Queue":
    q = LIVE_EVENTS.subscribe(live_session_id)
    with _viewers_lock:
        _viewers[live_session_id] = _viewers.get(live_session_id, 0) + 1
    return q


def unsubscribe(live_session_id: str, q: "queue.Queue") -> None:
    LIVE_EVENTS.unsubscribe(live_session_id, q)
    with _viewers_lock:
        left = _viewers.get(live_session_id, 0) - 1
        if left > 0:
            _viewers[live_session_id] = left
        else:
            _viewers.pop(live_session_id, None)


def viewed_sessions() -> List[str]:
    with _viewers_lock:
        return list(_viewers)


# The keys every segment carries, wherever a client meets one: an SSE
# `snapshot`, an SSE `seg`, a WS `seg` frame, a resume replay. A client keys on
# `seq`, so the same seq arriving in two different shapes is a bug even when
# both shapes are individually valid. Extras are preserved rather than dropped,
# so a new live_segment column reaches clients without a change here.
SEGMENT_FRAME_FIELDS = (
    "live_session_id", "seq", "ts_start_ms", "ts_end_ms", "speaker_id",
    "speaker_conf", "label_state", "local_label", "text", "lang",
    "translation", "device_id", "audio_ref",
)


def segment_frame(row: Dict[str, Any]) -> Dict[str, Any]:
    """One segment in the single shape every transport presents it in."""
    frame = dict(row or {})
    for field in SEGMENT_FRAME_FIELDS:
        frame.setdefault(field, None)
    return frame


def append_and_publish(live_session_id: str, *, ts_start_ms: int,
                       ts_end_ms: int, text: str, lang: str = "",
                       local_label: str = "", speaker_id: str = "",
                       speaker_conf: Optional[float] = None,
                       device_id: str = "",
                       audio_ref: str = "") -> Dict[str, Any]:
    """Append one utterance, fan it out, then poke the watchers.

    Order matters: the row is durable before anyone is told about it, and the
    watchers run last so a slow or broken one delays nothing a viewer sees.
    """
    row = live_store.append_segment(
        live_session_id, ts_start_ms=int(ts_start_ms), ts_end_ms=int(ts_end_ms),
        text=text, lang=lang, speaker_id=speaker_id, speaker_conf=speaker_conf,
        local_label=local_label, device_id=device_id, audio_ref=audio_ref)
    row = segment_frame(row)
    publish(live_session_id, "seg", row)
    _notify_segment_appended(live_session_id, int(row["seq"]))
    return row


# ── sessions and the paired chat (design §4) ───────────────────────────────


def _default_title() -> str:
    return time.strftime("Live · %Y-%m-%d %H:%M")


def _chat_header_text(live_session_id: str, title: str, device_id: str,
                      source_label: str, started_at: float) -> str:
    when = time.strftime("%Y-%m-%d %H:%M", time.localtime(started_at))
    source = source_label or "unspecified mic"
    device = device_id or "unknown device"
    return (
        f"**Live session** — {title}\n"
        f"Started {when} · source: {source} · device: {device}\n"
        f"Live transcript id: `{live_session_id}`\n\n"
        "Participants are labelled as voices are identified; a provisional "
        "label can be corrected later and the whole history follows.\n\n"
        "The full transcript is deliberately NOT streamed into this chat — "
        "that would rewrite the prompt prefix every few seconds. Use the "
        "`live_transcript` tool to search it, quote it, or pull a time range. "
        "Monitor notes arrive here as they are produced, and a summary lands "
        "when the session ends."
    )


def _create_paired_chat(live_session_id: str, title: str, device_id: str,
                        source_label: str, started_at: float) -> str:
    """A live session is also a normal chat, created at start (design §4).

    Existing plumbing — ``/api/sessions``, the iOS chat list, search, rename —
    then works with no new code. Best-effort by design: if the chat store is
    unavailable the recording still starts.
    """
    try:
        import uuid as _uuid

        from api.models import (LOCK, SESSIONS, SESSIONS_MAX, Session,
                                get_last_workspace)
        try:
            workspace = get_last_workspace() or str(Path.home())
        except Exception:
            workspace = str(Path.home())
        session = Session(
            session_id=_uuid.uuid4().hex[:12],
            title=title,
            workspace=workspace,
            source_tag=LIVE_SOURCE_TAG,
        )
        session.messages.append({
            "role": "assistant",
            "content": _chat_header_text(live_session_id, title, device_id,
                                         source_label, started_at),
        })
        with LOCK:
            SESSIONS[session.session_id] = session
            SESSIONS.move_to_end(session.session_id)
            while len(SESSIONS) > SESSIONS_MAX:
                SESSIONS.popitem(last=False)
        session.save()
        return session.session_id
    except Exception:
        logger.warning("paired chat session for live %s could not be created",
                       live_session_id, exc_info=True)
        return ""


def start_live_session(*, device_id: str = "", source_label: str = "",
                       title: str = "") -> Dict[str, Any]:
    """Open a live session, or refuse if the user turned Live off.

    Turning the feature off in settings means the server stops accepting
    capture, not that it keeps recording with the watchers muted. Reading and
    deleting what already exists stays available, and a session already
    recording is allowed to finish rather than being cut mid-utterance.
    """
    if not capture_enabled():
        raise LiveDisabled(
            "Live capture is turned off (live.enabled in config.yaml). "
            "Existing transcripts remain readable and deletable.")
    row = live_store.start_session(
        device_id=device_id, title=title or _default_title(),
        source_label=source_label)
    chat_id = _create_paired_chat(row["id"], row["title"] or _default_title(),
                                  device_id, source_label, row["started_at"])
    if chat_id:
        live_store.set_chat_session(row["id"], chat_id)
        row["chat_session_id"] = chat_id
    return row


def end_live_session(live_session_id: str) -> Dict[str, Any]:
    chunks = close_writers(live_session_id)
    live_store.end_session(live_session_id)
    publish(live_session_id, "state",
            {"live_session_id": live_session_id, "state": "ended",
             "recording": False})
    _notify_session_ended(live_session_id)
    row = live_store.get_session(live_session_id) or {"id": live_session_id}
    row["audio_chunks_closed"] = len(chunks)
    return row


# ── the connection (design §2.1–2.3) ───────────────────────────────────────


class LiveConnection:
    """One client's protocol state, deliberately transport-free.

    ``send`` receives server→client frames as dicts. The wsproto pump below
    supplies one that serialises to the socket; a test supplies a list append.
    """

    def __init__(self, send: Callable[[Dict[str, Any]], None],
                 on_bind: Optional[Callable[[str], None]] = None) -> None:
        self._send = send
        self._on_bind = on_bind
        self.live_session_id = ""
        self.chat_session_id = ""
        self.lane = LANE_SERVER
        self.device_id = ""
        self.device_kind = ""
        self.codec = ""
        self.rate = 16000
        self.can_speak = False
        self.ready = False
        self.closed = False
        # Accumulating partials, keyed by the track a device is streaming, so a
        # two-mic device cannot interleave two sentences into one. Ordered so the
        # bound below can drop the oldest unfinished one.
        self._partials: "OrderedDict[str, Dict[str, Any]]" = OrderedDict()
        # Non-None only while a resume replay is in flight (see on_bus_event).
        self._replay_buffer: Optional[List[Dict[str, Any]]] = None
        self._replay_lock = threading.Lock()
        self._last_audio_seq = -1

    # ── outbound ──

    def send(self, frame: Dict[str, Any]) -> None:
        """Push one frame, distinguishing a bad frame from a dead socket.

        Treating every failure as "the socket is gone" meant one
        non-serialisable insight payload silently one-wayed the connection: it
        kept accepting audio while the device never received another frame, and
        nothing said why. A frame we cannot serialise is that frame's problem.
        """
        if self.closed:
            return
        try:
            self._send(frame)
        except (TypeError, ValueError):
            logger.warning(
                "live: dropping an unserialisable %r frame on session %s",
                frame.get("t"), self.live_session_id[:8] or "?", exc_info=True)
        except Exception:
            logger.warning("live: send failed, closing session %s",
                           self.live_session_id[:8] or "?", exc_info=True)
            self.closed = True

    def error(self, code: str, message: str, **extra: Any) -> None:
        frame = {"t": "error", "code": code, "message": message}
        frame.update(extra)
        self.send(frame)

    def on_bus_event(self, event: str, data: Dict[str, Any]) -> None:
        """Forward one fan-out event to this device (design §2.4).

        A device sees its own utterance come back as the canonical ``seg``: that
        round trip is how it learns the server's ``seq`` and any speaker
        resolution, and clients key on ``seq`` so a duplicate is free.
        """
        if event == "resync":
            # The bus dropped something for this subscriber. Say so rather than
            # let the client look connected while missing a whole window.
            self.send({"t": "state", "warning": "resync",
                       "live_session_id": self.live_session_id})
            return
        if event == "speak" and not self.can_speak:
            return
        if event not in ("seg", "speaker", "insight", "speak", "state"):
            return
        frame = dict(data or {})
        frame["t"] = event
        with self._replay_lock:
            if self._replay_buffer is not None:
                # Mid-resume. Subscribing before the replay is what stops an
                # utterance falling into the gap, but delivering a live seg
                # before the older ones it follows would hand the client seq out
                # of order, so it waits here until the backlog is out.
                self._replay_buffer.append(frame)
                return
        self.send(frame)

    # ── inbound ──

    def on_text(self, raw: Any) -> None:
        try:
            msg = json.loads(raw if isinstance(raw, str) else (raw or b"{}"))
        except Exception:
            self.error("bad_json", "frame was not JSON")
            return
        if not isinstance(msg, dict):
            self.error("bad_frame", "frame must be an object")
            return
        kind = str(msg.get("t") or "").strip()
        if kind == "hello":
            self._on_hello(msg)
            return
        if not self.ready:
            self.error("not_ready", "send hello first")
            return
        if kind == "seg":
            self._on_seg(msg)
        elif kind == "text":
            self._on_text_batch(msg)
        elif kind == "audio":
            self._on_audio_batch(msg)
        elif kind == "state":
            # A device reporting pause/resume/mic-interrupted. Not stored; the
            # other devices need to see it, and only they do.
            data = {k: v for k, v in msg.items() if k != "t"}
            data.setdefault("live_session_id", self.live_session_id)
            data.setdefault("device_id", self.device_id)
            publish(self.live_session_id, "state", data)
        elif kind == "source":
            # Which mic this session is capturing from — "AirPods Pro", "Jarvis
            # glasses", "iPhone mic". The client sends it at start and again
            # whenever the route changes mid-session (AirPods pulled out), so a
            # recording carries the source that actually produced it.
            # Rejecting this frame put "unsupported frame type 'source'" over
            # the phone's controls while capture itself was fine.
            label = str(msg.get("source_label") or msg.get("label") or "").strip()
            if label:
                live_store.set_source_label(self.live_session_id, label[:120])
            publish(self.live_session_id, "state",
                    {"live_session_id": self.live_session_id,
                     "device_id": self.device_id, "source_label": label})
        elif kind == "end":
            row = end_live_session(self.live_session_id)
            self.send({"t": "state", "live_session_id": self.live_session_id,
                       "state": row.get("state") or "ended",
                       "recording": False})
        elif kind in ("ping", "pong"):
            return
        else:
            self.error("unknown_frame", f"unsupported frame type {kind!r}")

    def on_binary(self, data: bytes) -> None:
        if not self.ready:
            self.error("not_ready", "send hello first")
            return
        frame = decode_audio_frame(data)
        if frame is None:
            self.error("short_frame",
                       f"audio frame needs {AUDIO_HEADER_BYTES} header bytes")
            return
        seq, ts_ms, payload = frame
        if seq < self._last_audio_seq:
            # Reordering is expected on a real phone; the header carries the
            # truth, so log it and keep the bytes.
            logger.debug("live audio frame out of order on %s: %s after %s",
                         self.live_session_id, seq, self._last_audio_seq)
        self._last_audio_seq = max(self._last_audio_seq, seq)
        self._write_audio(payload, ts_ms)

    def close(self) -> None:
        self.closed = True

    # ── handshake ──

    def _relane(self, msg: Dict[str, Any]) -> None:
        """Apply a mid-session capability change and re-announce the lane.

        No new session, no new paired chat, no replay: the client keeps its
        cursor and only its declared capabilities change.
        """
        caps = msg.get("caps") if isinstance(msg.get("caps"), dict) else {}
        self.can_speak = bool(caps.get("speak"))
        codec = str(caps.get("codec") or "").strip()
        if codec:
            self.codec = codec
        self.lane = assign_lane(caps)
        logger.info("live: %s re-declared caps, lane now %s",
                    self.live_session_id, self.lane)
        self.send({
            "t": "ready",
            "live_session_id": self.live_session_id,
            "chat_session_id": self.chat_session_id,
            "seq": int((live_store.get_session(self.live_session_id)
                        or {}).get("last_seq") or 0),
            "lane": self.lane,
            "server_caps": server_caps(),
            "relane": True,
        })

    def _on_hello(self, msg: Dict[str, Any]) -> None:
        if self.ready:
            # A re-hello naming THIS session is a capability update, not a new
            # session. The iOS client sends one mid-session when on-device
            # transcription gives up and it falls back to the server lane
            # (`fallBackToServerTranscription`). Refusing it outright left the
            # phone believing it was still on the edge lane while no longer
            # transcribing — the transcript simply stopped, silently.
            resume = msg.get("resume") if isinstance(msg.get("resume"), dict) else {}
            same = str(resume.get("live_session_id") or "").strip()
            if same and same == self.live_session_id:
                self._relane(msg)
                return
            # Anything else would orphan the first session: it stayed
            # state='recording' forever with no tail digest, its writer kept
            # buffered audio that was never registered, its fan-out thread
            # leaked, and a second paired chat appeared. One socket, one
            # session; switching means reconnecting.
            self.error("already_ready",
                       "this socket already has a live session; open a new "
                       "connection to start another",
                       live_session_id=self.live_session_id)
            return
        caps = msg.get("caps") if isinstance(msg.get("caps"), dict) else {}
        self.device_id = str(msg.get("device_id") or "").strip()
        self.device_kind = str(msg.get("device_kind") or "").strip()
        self.codec = str(caps.get("codec") or "").strip()
        try:
            self.rate = int(caps.get("rate") or 16000)
        except (TypeError, ValueError):
            self.rate = 16000
        self.can_speak = bool(caps.get("speak"))
        self.lane = assign_lane(caps)

        resume = msg.get("resume") if isinstance(msg.get("resume"), dict) else {}
        want_sid = str(resume.get("live_session_id") or "").strip()
        after_seq = _as_int(resume.get("after_seq"), 0)

        row = live_store.get_session(want_sid) if want_sid else None
        resuming_known_session = row is not None
        replay_from = after_seq if resuming_known_session else 0

        # `live.enabled` off refuses NEW capture. Resuming a session that is
        # still recording is not new capture — a real phone drops its stream
        # about once a minute (§8), and killing that mid-utterance is the
        # failure mode the toggle is not for.
        resuming_live = (row is not None
                         and str(row.get("state") or "") == "recording")
        if not resuming_live and not capture_enabled():
            # Names the setting so the client can say WHICH switch to flip
            # instead of showing a generic refusal.
            self.error("live_disabled",
                       "Live capture is turned off (live.enabled in "
                       "config.yaml). Existing transcripts stay readable.",
                       setting="live.enabled")
            return

        if row is None:
            # Either a fresh connection or a resume for a session this server no
            # longer has. Both get a new session, and `ready` carries the id so
            # the client resets its cursor instead of spooling against a ghost.
            row = start_live_session(device_id=self.device_id,
                                     source_label=str(msg.get("source_label") or ""),
                                     title=str(msg.get("title") or ""))
            self.live_session_id = row["id"]
            self.chat_session_id = row.get("chat_session_id") or ""
            last_seq = 0
        else:
            # An already-ended session is adopted rather than refused: the client
            # is holding spooled audio that belongs to it, and appending to it is
            # strictly better than dropping the backlog on the floor.
            self.live_session_id = row["id"]
            self.chat_session_id = row.get("chat_session_id") or ""
            last_seq = int(row.get("last_seq") or 0)

        self.ready = True
        self.send({
            "t": "ready",
            "live_session_id": self.live_session_id,
            "chat_session_id": self.chat_session_id,
            "seq": last_seq,
            "lane": self.lane,
            "server_caps": server_caps(),
        })
        # Hold live frames while the backlog goes out, so subscribing first
        # (which is what stops an utterance falling into the gap) cannot deliver
        # a new seq ahead of the older ones it follows.
        with self._replay_lock:
            self._replay_buffer = []
        try:
            if self._on_bind:
                try:
                    self._on_bind(self.live_session_id)
                except Exception:
                    logger.warning("live fan-out subscribe failed for %s",
                                   self.live_session_id, exc_info=True)
            # `after_seq: 0` means "I have nothing, send the backlog" — treating
            # it as "no cursor, replay nothing" left a reconnecting client
            # silently empty. Bounded by segments_after's own limit.
            if resuming_known_session and replay_from < last_seq:
                try:
                    backlog = live_store.segments_after(self.live_session_id,
                                                        replay_from)
                except Exception:
                    logger.warning("live resume replay failed for %s",
                                   self.live_session_id, exc_info=True)
                    backlog = []
                for seg in backlog:
                    self.send(dict(segment_frame(seg), t="seg"))
        finally:
            with self._replay_lock:
                held, self._replay_buffer = self._replay_buffer or [], None
            for frame in held:
                self.send(frame)

    # ── ingestion ──

    def _on_seg(self, msg: Dict[str, Any]) -> None:
        track = str(msg.get("track") or msg.get("local_label") or "default")
        partial = bool(msg.get("partial"))
        text = str(msg.get("text") or "")
        held = self._partials.get(track)

        if partial:
            if held is None:
                # `track` is client-chosen and a partial may never be finished,
                # so both the key count and the text are bounded. Drop-oldest,
                # like the audio buffer, and say so rather than silently.
                while len(self._partials) >= _MAX_PARTIAL_TRACKS:
                    dropped_track, _ = self._partials.popitem(last=False)
                    self.send({"t": "state", "warning": "partials_overflow",
                               "live_session_id": self.live_session_id,
                               "dropped_track": dropped_track,
                               "message": "too many unfinished utterances; the "
                                          "oldest was dropped"})
                held = {"text": "", "ts_start_ms": _as_int(msg.get("ts_start_ms"), 0),
                        "ts_end_ms": 0, "lang": "", "local_label": ""}
                self._partials[track] = held
            room = _MAX_PARTIAL_CHARS - len(held["text"] or "")
            if room <= 0:
                self.send({"t": "state", "warning": "partial_too_long",
                           "live_session_id": self.live_session_id,
                           "track": track,
                           "message": "utterance exceeded "
                                      f"{_MAX_PARTIAL_CHARS} characters without "
                                      "a final frame; further text ignored"})
            else:
                held["text"] = (held["text"] or "") + text[:room]
            held["ts_end_ms"] = max(_as_int(msg.get("ts_end_ms"), 0),
                                    held["ts_end_ms"])
            held["lang"] = str(msg.get("lang") or held["lang"])
            held["local_label"] = str(msg.get("local_label") or held["local_label"])
            return

        # Final frame. Its own text wins when it has any — Apple's
        # SpeechAnalyzer re-states the whole utterance at the end, so
        # concatenating would duplicate it. An empty final frame means "that
        # accumulation was the sentence".
        final_text = text.strip() or ((held or {}).get("text") or "").strip()
        if not final_text:
            self._partials.pop(track, None)
            return
        raw_start = msg.get("ts_start_ms")
        if raw_start is None:
            raw_start = (held or {}).get("ts_start_ms")
        ts_start = to_offset_ms(self.live_session_id, raw_start)
        raw_end = msg.get("ts_end_ms") or (held or {}).get("ts_end_ms")
        ts_end = max(ts_start, to_offset_ms(self.live_session_id, raw_end)
                     if raw_end else ts_start)
        lang = str(msg.get("lang") or (held or {}).get("lang") or "")
        local_label = str(msg.get("local_label")
                          or (held or {}).get("local_label") or "")
        self._partials.pop(track, None)
        try:
            append_and_publish(
                self.live_session_id, ts_start_ms=ts_start, ts_end_ms=ts_end,
                text=final_text[:_MAX_SEGMENT_CHARS], lang=lang,
                local_label=local_label, device_id=self.device_id)
        except KeyError:
            self.error("no_session", "live session no longer exists")
        except Exception:
            self._store_unavailable("utterance", exc=True)

    def _on_text_batch(self, msg: Dict[str, Any]) -> None:
        segments = msg.get("segments")
        if not isinstance(segments, list):
            self.error("bad_frame", "text frame needs a segments array")
            return
        try:
            ingest_text_segments(self.live_session_id, segments,
                                 device_id=self.device_id)
        except KeyError:
            self.error("no_session", "live session no longer exists")
        except Exception:
            self._store_unavailable("batch", exc=True)

    def _store_unavailable(self, what: str, exc: bool = False) -> None:
        """A store write failed. Tell the client and KEEP the socket.

        `sqlite3.OperationalError("database is locked")` is the expected outcome
        when the recorder, the watchers and the storage panel contend, and a full
        disk raises here too. Letting it escape reached the pump's blanket
        handler, whose `finally` closed the socket — losing the utterance AND the
        transport holding the client's spooled backlog, which `after_seq` cannot
        recover because the client has already moved on locally.
        """
        logger.warning("live: store write failed (%s) on session %s",
                       what, self.live_session_id[:8] or "?", exc_info=exc)
        self.error("store_unavailable",
                   "the transcript store did not accept that write; retry it")
        self.send({"t": "state", "warning": "store_unavailable",
                   "live_session_id": self.live_session_id,
                   "message": f"{what} could not be saved; capture continues"})

    def _on_audio_batch(self, msg: Dict[str, Any]) -> None:
        codec = str(msg.get("codec") or self.codec)
        rate = _as_int(msg.get("rate"), self.rate)
        chunks = msg.get("chunks")
        if not isinstance(chunks, list):
            chunks = [{"data": msg.get("data"), "ts_ms": msg.get("ts_ms")}]
        dropped = 0
        for chunk in chunks:
            if not isinstance(chunk, dict):
                continue
            payload = _decode_b64(chunk.get("data"))
            if payload is None:
                self.error("bad_audio", "chunk data must be base64")
                continue
            result = self._write_audio(payload, _as_int(chunk.get("ts_ms"), 0),
                                       codec=codec, rate=rate, warn=False)
            dropped += int((result or {}).get("dropped_bytes") or 0)
        if dropped:
            self._warn_dropped(dropped)

    def _write_audio(self, payload: bytes, ts_ms: int, codec: str = "",
                     rate: int = 0, warn: bool = True) -> Dict[str, Any]:
        try:
            result = ingest_audio_chunk(
                self.live_session_id, payload, ts_ms=ts_ms,
                device_id=self.device_id, codec=codec or self.codec,
                rate=rate or self.rate)
        except TooManyDevices as exc:
            self.error("too_many_devices", str(exc))
            return {"dropped_bytes": len(payload)}
        except Exception:
            logger.warning("live audio ingest failed on session %s",
                           self.live_session_id[:8] or "?", exc_info=True)
            return {"dropped_bytes": 0}
        if result.get("refused") == "session_deleted":
            # The user deleted this recording while the socket was still open.
            self.error("session_deleted",
                       "this live session was deleted; audio is no longer "
                       "being stored")
            return result
        if warn and result.get("dropped_bytes"):
            self._warn_dropped(int(result["dropped_bytes"]))
        return result

    def _warn_dropped(self, dropped: int) -> None:
        self.send({"t": "state", "warning": "audio_buffer_overflow",
                   "dropped_bytes": int(dropped),
                   "live_session_id": self.live_session_id,
                   "message": "audio could not be written to disk; oldest "
                              "buffered audio was dropped"})


def decode_audio_frame(data: bytes) -> Optional[Tuple[int, int, bytes]]:
    """``[4B seq][8B ts_ms][payload]`` → ``(seq, ts_ms, payload)``."""
    if not isinstance(data, (bytes, bytearray)) or len(data) < AUDIO_HEADER_BYTES:
        return None
    seq, ts_ms = _AUDIO_HEADER.unpack(bytes(data[:AUDIO_HEADER_BYTES]))
    return int(seq), int(ts_ms), bytes(data[AUDIO_HEADER_BYTES:])


def encode_audio_frame(seq: int, ts_ms: int, payload: bytes) -> bytes:
    """The client's side of the wire format, kept here so tests use one truth."""
    return _AUDIO_HEADER.pack(int(seq) & 0xFFFFFFFF, int(ts_ms)) + bytes(payload)


def ingest_text_segments(live_session_id: str, segments: List[dict],
                         device_id: str = "",
                         into: Optional[List[dict]] = None) -> List[dict]:
    """Append a batch of finished utterances, bounded and time-stamped.

    Timestamps are filled from the wall clock when a client omits them. A
    zero-timestamp segment is not merely untidy: `delete_audio_with_speaker`
    places a voice by overlapping segment time against chunk time, so segments at
    t=0 match no chunk and the audio is silently KEPT while the UI promises to
    delete "every recording this voice can be heard in".
    """
    # Validate the whole batch before writing any of it. Writing as we went meant
    # a bad segment halfway through left the first half stored and the client
    # seeing an error, so §8's spool re-upload duplicated those utterances under
    # fresh seqs — which seq-dedup cannot catch.
    prepared = []
    for seg in segments[:_MAX_SEGMENTS_PER_REQUEST]:
        if not isinstance(seg, dict):
            continue
        text = str(seg.get("text") or "").strip()[:_MAX_SEGMENT_CHARS]
        if not text:
            continue
        ts_start = to_offset_ms(live_session_id, seg.get("ts_start_ms"))
        raw_end = seg.get("ts_end_ms")
        ts_end = ts_start if raw_end is None else max(
            ts_start, to_offset_ms(live_session_id, raw_end))
        prepared.append({
            "ts_start_ms": ts_start, "ts_end_ms": ts_end, "text": text,
            "lang": str(seg.get("lang") or ""),
            "local_label": str(seg.get("local_label") or ""),
            "speaker_id": str(seg.get("speaker_id") or ""),
            "device_id": str(seg.get("device_id") or device_id or ""),
        })
    # `into` lets a caller see what landed even if a later write raises, so it
    # can report a partial result instead of an all-or-nothing error.
    rows = into if into is not None else []
    for item in prepared:
        rows.append(append_and_publish(live_session_id, **item))
    return rows


# ── wsproto pump (the same shape as api/voice.py) ──────────────────────────

_WS_RECV_CHUNK = 8192


def handle_websocket(handler, parsed) -> bool:
    """Claim ``/api/live/ws``, finish the WS handshake, run the pump.

    Returns True iff this handler claimed the request. Auth already happened:
    ``check_auth`` runs in ``do_GET`` before any upgrade dispatch, and
    ``/api/live/ws`` is not in ``PUBLIC_PATHS``.
    """
    if parsed.path != LIVE_WS_PATH:
        return False

    # CSRF does not apply to a GET, so without this the only thing stopping a
    # page on another origin from opening this socket — and reading every frame,
    # i.e. a live transcript of the room — is the SameSite cookie. One control is
    # not enough for that. Same policy as every write endpoint: Origin/Referer
    # against Host plus the allowed-origins env, with a missing Origin treated as
    # a non-browser client.
    if not _origin_allowed(handler):
        try:
            handler.send_response(403)
            handler.send_header("Content-Type", "application/json")
            handler.end_headers()
            handler.wfile.write(b'{"error":"cross-origin websocket rejected"}')
        except Exception:
            pass
        return True

    try:
        from wsproto import ConnectionType, WSConnection
        from wsproto.events import AcceptConnection, Request
    except Exception:
        try:
            handler.send_response(503)
            handler.send_header("Content-Type", "application/json")
            handler.end_headers()
            handler.wfile.write(b'{"error":"wsproto not installed"}')
        except Exception:
            pass
        return True

    sock = handler.connection
    # Long-lived connection: a read timeout would cycle the socket out from
    # under a blocking recv. One thread owns one socket, so this is local.
    try:
        sock.settimeout(None)
    except Exception:
        pass

    from api.voice import _reconstruct_http_request

    conn = WSConnection(ConnectionType.SERVER)
    conn.receive_data(_reconstruct_http_request(handler))
    accepted = False
    for event in conn.events():
        if isinstance(event, Request):
            try:
                sock.sendall(conn.send(AcceptConnection()))
                accepted = True
            except Exception:
                return True
            break
    if not accepted:
        return True
    _run_live_ws(conn, sock)
    return True


def _origin_allowed(handler) -> bool:
    """Reuse the WebUI's own cross-origin policy for the upgrade.

    Imported lazily: routes imports this module, so a module-level import would
    be a cycle. Fails CLOSED — if the policy cannot be consulted, a browser
    request (one that sent an Origin) is refused rather than waved through.
    """
    try:
        from api.routes import _check_csrf
    except Exception:
        logger.warning("live: cross-origin policy unavailable", exc_info=True)
        return not (handler.headers.get("Origin")
                    or handler.headers.get("Referer"))
    try:
        return bool(_check_csrf(handler))
    except Exception:
        logger.warning("live: cross-origin check failed", exc_info=True)
        return False


def _run_live_ws(conn, sock) -> None:
    """Pump one live socket until the client goes away."""
    from wsproto.events import (BytesMessage, CloseConnection, Ping, Pong,
                                TextMessage)

    send_lock = threading.Lock()
    state = {"closed": False, "sid": "", "queue": None, "thread": None}
    stop = threading.Event()

    def _send(frame: Dict[str, Any]) -> None:
        payload = json.dumps(frame, ensure_ascii=False)
        with send_lock:
            sock.sendall(conn.send(TextMessage(data=payload)))

    def _bind(sid: str) -> None:
        # Subscribe as soon as the session is known so a seg appended by another
        # device (or by REST) reaches this socket too.
        if state["sid"] == sid:
            return
        _unbind()
        state["sid"] = sid
        state["queue"] = subscribe(sid)
        thread = threading.Thread(
            target=_fanout, args=(sid, state["queue"]),
            name=f"live-fanout-{sid[:8]}", daemon=True)
        state["thread"] = thread
        thread.start()

    def _unbind() -> None:
        if state["queue"] is not None and state["sid"]:
            unsubscribe(state["sid"], state["queue"])
        state["queue"] = None
        state["sid"] = ""

    def _fanout(sid: str, q) -> None:
        while not stop.is_set():
            try:
                event, data = q.get(timeout=_FANOUT_POLL_SECONDS)
            except queue.Empty:
                continue
            except Exception:
                return
            live.on_bus_event(event, data)
            if live.closed:
                return

    live = LiveConnection(_send, on_bind=_bind)

    try:
        while not state["closed"]:
            try:
                data = sock.recv(_WS_RECV_CHUNK)
            except _CLIENT_DISCONNECT_ERRORS:
                break
            if not data:
                break
            conn.receive_data(data)
            for event in conn.events():
                if isinstance(event, BytesMessage):
                    live.on_binary(event.data or b"")
                elif isinstance(event, TextMessage):
                    live.on_text(event.data or "{}")
                elif isinstance(event, Ping):
                    try:
                        with send_lock:
                            sock.sendall(conn.send(Pong(event.payload)))
                    except Exception:
                        state["closed"] = True
                elif isinstance(event, CloseConnection):
                    try:
                        with send_lock:
                            sock.sendall(conn.send(event.response()))
                    except Exception:
                        pass
                    state["closed"] = True
                    break
    except Exception:
        logger.warning("live WS error", exc_info=True)
    finally:
        state["closed"] = True
        live.close()
        stop.set()
        _unbind()
        thread = state.get("thread")
        if thread is not None and thread.is_alive():
            thread.join(timeout=2.0)
        # The recording is not over just because this socket dropped — a phone
        # loses its stream about once a minute (§8) and resumes with after_seq.
        # Flushing the chunk is what makes that resume cheap.
        close_writers(live.live_session_id)
        try:
            sock.close()
        except Exception:
            pass


# ── REST + SSE ─────────────────────────────────────────────────────────────


def handle_live_get(handler, parsed) -> bool:
    path = parsed.path
    if path == "/api/live/events":
        return _live_events_sse(handler, parsed)
    if path == "/api/live/sessions":
        j(handler, {"sessions": live_store.list_sessions()})
        return True
    if path == "/api/live/transcript":
        return _live_transcript(handler, parsed)
    if path == "/api/live/speakers":
        speakers = live_store.list_speakers()
        for speaker in speakers:
            speaker["samples"] = live_store.speaker_samples(speaker["id"])
        j(handler, {"speakers": speakers})
        return True
    if path == "/api/live/storage":
        j(handler, live_store.storage_summary())
        return True
    if path == "/api/live/config":
        j(handler, {"config": live_config.load(),
                    "defaults": live_config.DEFAULTS})
        return True
    return False


def handle_live_post(handler, parsed, body) -> bool:
    path = parsed.path
    body = body if isinstance(body, dict) else {}
    if path == "/api/live/session/start":
        try:
            row = start_live_session(
                device_id=str(body.get("device_id") or ""),
                source_label=str(body.get("source_label") or ""),
                title=str(body.get("title") or ""))
        except LiveDisabled as exc:
            j(handler, {"error": str(exc), "setting": "live.enabled"},
              status=403)
            return True
        j(handler, {"live_session_id": row["id"],
                    "chat_session_id": row.get("chat_session_id") or "",
                    "session": row})
        return True
    if path == "/api/live/session/end":
        sid = _require_session(handler, body)
        if sid is None:
            return True
        j(handler, {"ok": True, "session": end_live_session(sid)})
        return True
    if path == "/api/live/text":
        sid = _require_session(handler, body)
        if sid is None:
            return True
        segments = body.get("segments")
        if not isinstance(segments, list):
            bad(handler, "segments array required")
            return True
        written: List[dict] = []
        try:
            written = ingest_text_segments(
                sid, segments, device_id=str(body.get("device_id") or ""),
                into=written)
        except KeyError:
            bad(handler, "live session not found", 404)
            return True
        except Exception:
            # Report exactly what landed. Saying "error" after a partial write
            # made §8's spool re-upload duplicate those utterances under fresh
            # seqs, which seq-dedup cannot catch.
            logger.warning("live: text batch failed partway on session %s",
                           sid[:8], exc_info=True)
            j(handler, {"ok": False, "written": len(written),
                        "segments": written,
                        "error": "the transcript store stopped accepting writes; "
                                 f"{len(written)} segment(s) were saved — resume "
                                 "from last_seq",
                        "last_seq": int((live_store.get_session(sid) or {})
                                        .get("last_seq") or 0)}, status=503)
            return True
        j(handler, {"ok": True, "written": len(written), "segments": written,
                    "last_seq": written[-1]["seq"] if written else
                    int((live_store.get_session(sid) or {}).get("last_seq") or 0)})
        return True
    if path == "/api/live/audio":
        return _live_audio_batch(handler, body)
    if path == "/api/live/speaker/rename":
        speaker_id = str(body.get("speaker_id") or "").strip()
        name = str(body.get("name") or "").strip()
        if not speaker_id:
            bad(handler, "speaker_id required")
            return True
        live_store.rename_speaker(speaker_id, name)
        _publish_speaker_op({"op": "rename", "speaker_id": speaker_id,
                             "name": name or None})
        j(handler, {"ok": True, "speaker": live_store.get_speaker(speaker_id)})
        return True
    if path == "/api/live/speaker/merge":
        from_id = str(body.get("from_id") or "").strip()
        into_id = str(body.get("into_id") or "").strip()
        if not from_id or not into_id:
            bad(handler, "from_id and into_id required")
            return True
        moved = live_store.merge_speakers(from_id, into_id)
        # Clients apply a merge in place, relabelling earlier segments, which is
        # why the frame carries both ids rather than a reload instruction.
        _publish_speaker_op({"op": "merge", "from_id": from_id,
                             "into_id": into_id, "segments_moved": moved})
        j(handler, {"ok": True, "segments_moved": moved,
                    "speaker": live_store.get_speaker(into_id)})
        return True
    if path == "/api/live/delete":
        return _live_delete(handler, body)
    if path == "/api/live/factcheck":
        return _live_watcher_call(handler, body, "run_fact_check")
    if path == "/api/live/translate":
        return _live_watcher_call(handler, body, "run_translate")
    if path == "/api/live/config":
        # POST is accepted alongside PUT: several shipped clients cannot send a
        # PUT, and a settings write must not depend on which verb they have.
        return _live_config_write(handler, body)
    return False


def handle_live_put(handler, parsed, body) -> bool:
    if parsed.path == "/api/live/config":
        return _live_config_write(handler, body if isinstance(body, dict) else {})
    return False


def _live_config_write(handler, body) -> bool:
    patch = body.get("config") if isinstance(body.get("config"), dict) else body
    try:
        config = live_config.save(patch if isinstance(patch, dict) else {})
    except ValueError as exc:
        bad(handler, str(exc))
        return True
    except Exception:
        # The detail goes to the log, not the response: a config write failure
        # can carry a filesystem path, and provider errors elsewhere can carry a
        # base URL or a key in a query string.
        logger.warning("live: writing config failed", exc_info=True)
        j(handler, {"error": "could not write the live settings"}, status=500)
        return True
    payload = {"ok": True, "config": config}
    ignored = live_config.unknown_keys(patch if isinstance(patch, dict) else {})
    if ignored:
        payload["ignored_keys"] = ignored
    j(handler, payload)
    return True


def _live_transcript(handler, parsed) -> bool:
    qs = parse_qs(parsed.query)
    sid = (qs.get("live_session_id", [""])[0] or "").strip()
    if not sid:
        bad(handler, "live_session_id required")
        return True
    after_seq = _as_int((qs.get("after_seq", ["0"])[0] or "0"), 0)
    limit = max(1, min(_TRANSCRIPT_LIMIT_MAX,
                       _as_int((qs.get("limit", ["500"])[0] or "500"), 500)))
    session = live_store.get_session(sid)
    if session is None:
        bad(handler, "live session not found", 404)
        return True
    segments = [segment_frame(row) for row
                in live_store.segments_after(sid, after_seq, limit=limit)]
    j(handler, {"live_session_id": sid, "session": session,
                "segments": segments,
                "last_seq": int(session.get("last_seq") or 0)})
    return True


def _live_audio_batch(handler, body) -> bool:
    sid = _require_session(handler, body)
    if sid is None:
        return True
    device_id = str(body.get("device_id") or "")
    codec = str(body.get("codec") or "")
    rate = _as_int(body.get("rate"), 16000)
    chunks = body.get("chunks")
    if not isinstance(chunks, list):
        chunks = [{"data": body.get("data"), "ts_ms": body.get("ts_ms")}]
    # Decode everything before writing anything: a bad chunk halfway through used
    # to leave the first half in the file and hand the client an error, so the §8
    # spool re-upload wrote those seconds twice.
    payloads = []
    for chunk in chunks[:_MAX_SEGMENTS_PER_REQUEST]:
        if not isinstance(chunk, dict):
            continue
        payload = _decode_b64(chunk.get("data"))
        if payload is None:
            bad(handler, "chunk data must be base64; nothing was written")
            return True
        if payload:
            payloads.append((payload, chunk.get("ts_ms")))

    written = 0
    accepted = 0
    dropped = 0
    refused = ""
    for payload, ts_ms in payloads:
        try:
            result = ingest_audio_chunk(sid, payload, ts_ms=_as_int(ts_ms, 0),
                                        device_id=device_id, codec=codec,
                                        rate=rate)
        except TooManyDevices as exc:
            j(handler, {"error": str(exc), "written": accepted,
                        "bytes": written}, status=429)
            return True
        if result.get("refused"):
            refused = str(result["refused"])
            break
        accepted += 1
        written += len(payload)
        dropped += int(result.get("dropped_bytes") or 0)
    out: Dict[str, Any] = {"ok": not refused, "chunks": accepted,
                           "written": accepted, "bytes": written}
    if dropped:
        out["dropped_bytes"] = dropped
        out["warning"] = "audio_buffer_overflow"
    if refused:
        out["error"] = ("this live session was deleted; audio is no longer "
                        "being stored")
    j(handler, out, status=409 if refused else 200)
    return True


def _delete_one_session(live_session_id: str) -> Dict[str, Any]:
    """Delete a live session, its audio, and the chat it was paired with.

    The paired chat is not a duplicate of the transcript, but the watchers put
    the monitor notes and the end-of-session summary, decisions and action items
    in it — the substance of the conversation. Leaving it behind meant "delete
    this recording" left that in the chat list, in chat search, and mirrored to
    the phone.
    """
    row = live_store.get_session(live_session_id) or {}
    chat_session_id = str(row.get("chat_session_id") or "")
    # Flush first, then tombstone: a still-connected client must not be able to
    # re-create the directory and register rows for a session row that is gone.
    close_writers(live_session_id)
    tombstone_session(live_session_id)
    result = dict(live_store.delete_session(live_session_id))
    if chat_session_id:
        result["chat_session_id"] = chat_session_id
        deleted, reason = _delete_chat_session(chat_session_id)
        result["chat_deleted"] = deleted
        if not deleted:
            # Reported, not swallowed: the monitor notes and the summary are
            # still in the chat list, and saying "deleted" would be a lie.
            result["ok"] = False
            result["warning"] = (
                f"the paired chat {chat_session_id} could not be deleted "
                f"({reason}); its notes and summary remain in Chats")
    return result


def _delete_chat_session(chat_session_id: str) -> Tuple[bool, str]:
    """Delete a paired chat through the WebUI's own session-delete path."""
    try:
        from api.routes import delete_chat_session
    except Exception as exc:
        logger.warning("live: chat delete helper unavailable", exc_info=True)
        return False, f"delete path unavailable: {type(exc).__name__}"
    try:
        delete_chat_session(chat_session_id)
        return True, ""
    except Exception as exc:
        logger.warning("live: deleting paired chat %s failed", chat_session_id,
                       exc_info=True)
        return False, type(exc).__name__


def _unplaceable_chunk_count() -> int:
    """Chunks whose time span is unknown, so no voice can be matched to them.

    `delete_audio_with_speaker` places a voice by overlapping segment time
    against chunk time. A chunk adopted by the startup sweep has no span at all,
    so it can never match — and the dialog promises to delete "every recording
    this voice can be heard in". Counting them lets the UI say what it cannot do
    instead of implying it did.
    """
    unplaceable = 0
    try:
        for session in live_store.list_sessions(limit=500):
            for chunk in live_store.audio_chunks(session["id"]):
                if not int(chunk.get("ts1_ms") or 0):
                    unplaceable += 1
    except Exception:
        logger.debug("counting unplaceable chunks failed", exc_info=True)
    return unplaceable


def _live_delete(handler, body) -> bool:
    kind = str(body.get("kind") or "").strip()
    target = str(body.get("id") or "").strip()
    if not target:
        bad(handler, "id required")
        return True
    if kind in ("session", "speaker_forget", "speaker_audio"):
        # Not decoration: `Path(audio_root) / "/etc/x"` discards the root and
        # ".." climbs out of it, so an unvalidated session id turned this delete
        # into an rmdir elsewhere on the filesystem. Every id this API issues is
        # uuid4 hex, so anything else is a bug or an attack.
        if not _ID_RE.match(target):
            bad(handler, "id must be a 32-character hex id")
            return True
    if kind == "session":
        j(handler, _delete_one_session(target))
        return True
    if kind == "speaker_forget":
        j(handler, live_store.forget_speaker(target))
        return True
    if kind == "speaker_audio":
        close_writers()
        result = dict(live_store.delete_audio_with_speaker(target))
        unplaceable = _unplaceable_chunk_count()
        if unplaceable:
            result["chunks_unplaceable"] = unplaceable
            result["note"] = (
                f"{unplaceable} audio chunk(s) have no known time span, so no "
                "voice can be matched to them; delete the session or the day to "
                "remove those")
        j(handler, result)
        return True
    if kind == "day":
        if not _DAY_RE.match(target):
            bad(handler, "id must be a local calendar day as YYYY-MM-DD")
            return True
        sessions = live_store.sessions_on_day(target)
        freed = 0
        chats_deleted = 0
        failures = []
        for sid in sessions:
            one = _delete_one_session(sid)
            freed += int(one.get("freed_bytes") or 0)
            if one.get("chat_deleted"):
                chats_deleted += 1
            if one.get("warning"):
                failures.append(one["warning"])
        out = {"day": target, "sessions_deleted": len(sessions),
               "freed_bytes": freed, "chats_deleted": chats_deleted}
        if failures:
            out["ok"] = False
            out["warnings"] = failures
        j(handler, out)
        return True
    bad(handler, "kind must be session, day, speaker_forget or speaker_audio")
    return True


_watcher_inflight = 0
_watcher_inflight_lock = threading.Lock()

# Which `live:` toggle each on-demand watcher answers to, so "it is off" is
# answered here and now instead of being discovered inside a background job the
# client can never hear about.
_WATCHER_TOGGLE = {"run_fact_check": "fact_check", "run_translate": "translate"}


def _live_watcher_call(handler, body, func_name: str) -> bool:
    """On-demand watcher work (fact-check, translate), dispatched off-thread.

    These build a whole ``AIAgent`` and run a full turn with web tools. Running
    that inside the HTTP handler thread meant an uncancellable request that the
    nginx edge would 504 while the agent kept going, and N taps meant N
    concurrent agent runs. So: everything knowable now is answered now, the work
    goes to the watcher pool, and the verdict reaches the client over the same
    ``insight`` fan-out the web client already renders.
    """
    global _watcher_inflight

    sid = _require_session(handler, body)
    if sid is None:
        return True
    seq = _as_int(body.get("seq"), 0)
    if seq <= 0:
        bad(handler, "seq required")
        return True
    # The toggle first, and synchronously: it is the most actionable answer the
    # user can get ("you turned this off"), it needs no watcher layer at all, and
    # discovering it inside a background job would leave the client's spinner
    # waiting for an insight that is never coming.
    cfg = live_config.load()
    toggle = _WATCHER_TOGGLE.get(func_name, "")
    if not cfg.get("enabled") or (toggle and not cfg.get(toggle)):
        setting = "live.enabled" if not cfg.get("enabled") else f"live.{toggle}"
        j(handler, {"ok": False, "setting": setting,
                    "error": f"{toggle or func_name} is turned off ({setting})"})
        return True

    try:
        from api import live_watchers
        func = getattr(live_watchers, func_name)
    except Exception:
        logger.warning("live: watcher %s unavailable", func_name, exc_info=True)
        j(handler, {"ok": False,
                    "error": f"live watchers are unavailable ({func_name})"},
          status=503)
        return True

    with _watcher_inflight_lock:
        if _watcher_inflight >= _MAX_WATCHER_INFLIGHT:
            j(handler, {"ok": False, "error": "too many checks already running; "
                                              "try again in a moment"},
              status=429)
            return True
        _watcher_inflight += 1

    target = str(body.get("target") or "").strip()
    job_id = uuid.uuid4().hex

    def _job() -> None:
        global _watcher_inflight
        try:
            result = (func(sid, seq, target) if func_name == "run_translate"
                      else func(sid, seq))
            ok = bool(result.get("ok", True)) if isinstance(result, dict) else True
            if not ok:
                reason = str((result or {}).get("error") or "") \
                    if isinstance(result, dict) else ""
                # The insight channel has no failure frame, and a `state`
                # warning is what the client already shows in its status line —
                # better than a spinner that never resolves.
                publish(sid, "state", {
                    "live_session_id": sid, "seq": seq, "job_id": job_id,
                    "warning": f"{func_name}_failed",
                    "message": reason or f"{func_name} did not produce a result",
                })
        except Exception:
            logger.warning("live: %s failed for %s#%s", func_name, sid, seq,
                           exc_info=True)
            publish(sid, "state", {
                "live_session_id": sid, "seq": seq, "job_id": job_id,
                "warning": f"{func_name}_failed",
                "message": f"{func_name} could not be completed",
            })
        finally:
            with _watcher_inflight_lock:
                _watcher_inflight -= 1

    submitted = False
    submit = getattr(live_watchers, "_submit", None)
    if callable(submit):
        submitted = bool(submit(_job))
    if not submitted:
        # No pool (or it declined): our own bounded thread, since the in-flight
        # count above is already the ceiling.
        try:
            threading.Thread(target=_job, name=f"live-{func_name}",
                             daemon=True).start()
            submitted = True
        except Exception:
            logger.warning("live: could not dispatch %s", func_name,
                           exc_info=True)
    if not submitted:
        with _watcher_inflight_lock:
            _watcher_inflight -= 1
        j(handler, {"ok": False, "error": f"could not start {func_name}"},
          status=503)
        return True

    j(handler, {"ok": True, "accepted": True, "job_id": job_id,
                "live_session_id": sid, "seq": seq,
                "delivery": "insight"}, status=202)
    return True


def _live_events_sse(handler, parsed) -> bool:
    """SSE fan-out for viewers: the phone records, the browser watches.

    ``seq`` goes in the JSON payload, never the SSE ``id:`` field — iOS's
    ``SSEParser`` drops ``id:`` lines, so a cursor there is invisible to the
    client that needs it.
    """
    from api.streaming import _sse

    qs = parse_qs(parsed.query)
    sid = (qs.get("live_session_id", [""])[0] or "").strip()
    if not sid:
        return bad(handler, "live_session_id required") or True
    after_seq = _as_int((qs.get("after_seq", ["0"])[0] or "0"), 0)

    handler.send_response(200)
    handler.send_header("Content-Type", "text/event-stream; charset=utf-8")
    handler.send_header("Cache-Control", "no-cache")
    handler.send_header("X-Accel-Buffering", "no")
    handler.send_header("Connection", "keep-alive")
    handler.end_headers()

    # Subscribe BEFORE the snapshot. The chat-mirror work proved the reverse
    # order loses whatever lands in the gap; the cost is that a segment can
    # arrive twice, which `seq` makes free to dedupe.
    q = subscribe(sid)
    try:
        session = live_store.get_session(sid) or {"id": sid}
        # Through segment_frame so a backlog segment and a live `seg` are the
        # same shape by construction, not by both happening to come from the
        # same table today.
        segments = [segment_frame(row)
                    for row in live_store.segments_after(sid, after_seq)]
        _sse(handler, "snapshot", {
            "live_session_id": sid,
            "session": session,
            "segments": segments,
            "last_seq": int(session.get("last_seq") or 0),
            "after_seq": after_seq,
        })
        while True:
            try:
                event, data = q.get(timeout=_SSE_HEARTBEAT_INTERVAL_SECONDS)
            except queue.Empty:
                handler.wfile.write(b": keepalive\n\n")
                handler.wfile.flush()
                continue
            _sse(handler, event, data)
    except _CLIENT_DISCONNECT_ERRORS:
        pass
    finally:
        unsubscribe(sid, q)
    return True


def _publish_speaker_op(frame: Dict[str, Any]) -> None:
    """A voice is global, so every viewer hears about a rename or a merge.

    Deliberately NOT limited to recording sessions: naming a voice is exactly
    what someone does while reviewing a finished conversation, and scoping this
    to live sessions meant a second device viewing that transcript never
    learned. Publishing into a channel nobody is on is already a no-op in
    SessionEventBus, so the wide fan-out costs nothing.
    """
    try:
        for sid in viewed_sessions():
            publish(sid, "speaker", frame)
    except Exception:
        logger.debug("speaker fan-out failed", exc_info=True)


def _require_session(handler, body) -> Optional[str]:
    sid = str((body or {}).get("live_session_id") or "").strip()
    if not sid:
        bad(handler, "live_session_id required")
        return None
    if live_store.get_session(sid) is None:
        bad(handler, "live session not found", 404)
        return None
    return sid


def _decode_b64(raw: Any) -> Optional[bytes]:
    if raw is None:
        return b""
    if isinstance(raw, (bytes, bytearray)):
        return bytes(raw)
    if not isinstance(raw, str):
        return None
    # Validate strictly so a mangled upload is reported rather than silently
    # decoded into garbage audio, but tolerate line-wrapped base64, which several
    # HTTP clients still emit.
    try:
        return base64.b64decode("".join(raw.split()), validate=True)
    except (binascii.Error, ValueError):
        return None


def _as_int(raw: Any, default: int = 0) -> int:
    try:
        return int(raw)
    except (TypeError, ValueError):
        return default
