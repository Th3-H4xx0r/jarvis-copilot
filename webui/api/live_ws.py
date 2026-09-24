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
import math
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

from api import live_config, live_deliver, live_store
from api.helpers import bad, j
from api.session_events import SessionEventBus

logger = logging.getLogger(__name__)

LIVE_WS_PATH = "/api/live/ws"

# A second bus instance, keyed by live_session_id. Same machinery as the chat
# mirror's SESSION_EVENTS (no offline buffer, bounded queues, resync on drop) —
# a separate instance only so a live session id can never collide with a chat
# session id in one keyspace.
class _LiveEventBus(SessionEventBus):
    """The live fan-out, plus the durability the Live screen needs.

    An insight used to exist ONLY as a frame. `SessionEventBus.publish` returns
    immediately when nobody is subscribed, so a note produced while the phone
    was backgrounded, mid-reconnect (§8: the stream drops about once a minute)
    or simply not on the Live screen reached no one and could never be asked
    for again — while the paired chat kept it forever. That asymmetry is the
    report "the fact-check showed up in the chat, but not in the live view".

    Recording happens HERE, before the fan-out, rather than at each watcher's
    call site: watchers publish straight onto this bus, so this is the one
    place every insight must pass, and it means the frame a client sees and the
    row it can fetch later cannot drift apart. It also needs no change in
    `live_watchers`, which owns the watchers but not the transport.
    """

    def publish(self, session_id: str, event: str,
                data: Optional[Dict[str, Any]] = None) -> None:
        if event == "insight" and session_id:
            _record_insight(session_id, data or {})
        super().publish(session_id, event, data)


LIVE_EVENTS = _LiveEventBus()


def _record_insight(live_session_id: str, payload: Dict[str, Any]) -> None:
    """Persist one insight. Never raises — a watcher's note is not worth a crash.

    The seq RANGE matters more than a single anchor (§5.2's fact-check is
    becoming conversation-level, and the artifacts note already covers a whole
    session), so:

    * a note that names a `seq` is about that one utterance;
    * a note that names an `anchor_seq` is about the line it quoted — a
      conversation-level fact-check reads a stretch but judges one claim
      inside it, and the card belongs under that claim;
    * a monitor note carries a `digest_id`, and that digest knows the window it
      summarised — the accurate range, recovered with one lookup;
    * anything else is anchored at the last segment it could have seen, so a
      client can still place it in order instead of dumping it at the end.
    """
    try:
        text = str(payload.get("text") or "").strip()
        if not text:
            return
        seq = payload.get("seq")
        seq_from = seq_to = int(seq) if isinstance(seq, (int, float)) else None
        # WHERE it goes, kept apart from WHAT it covered. Collapsing the range
        # onto the anchor placed the card correctly and then hid the note from
        # any client resuming past that row, because the fetch filters on
        # `seq_to` — which is exactly the case this table exists to serve.
        anchor = payload.get("anchor_seq")
        anchor_seq = int(anchor) if isinstance(anchor, (int, float)) else seq_from
        digest_id = str(payload.get("digest_id") or "")
        if seq_from is None and digest_id:
            digest = live_store.get_digest(digest_id)
            if digest:
                seq_from = int(digest.get("seq_from") or 0) or None
                seq_to = int(digest.get("seq_to") or 0) or None
        if seq_to is None:
            session = live_store.get_session(live_session_id)
            seq_to = int((session or {}).get("last_seq") or 0) or None
        live_store.add_insight(
            live_session_id, kind=str(payload.get("kind") or "monitor"),
            text=text, seq_from=seq_from, seq_to=seq_to, anchor_seq=anchor_seq,
            scope=str(payload.get("scope") or ""),
            verdict=str(payload.get("verdict") or ""),
            sources=payload.get("sources") or [], digest_id=digest_id,
            created_at=payload.get("created_at"))
    except Exception:
        logger.warning("live: an insight could not be stored for %s",
                       live_session_id[:8] or "?", exc_info=True)

def _insight_frame(note: Dict[str, Any]) -> Dict[str, Any]:
    """A stored note, shaped like the `insight` frame a live client already reads.

    The table keeps a RANGE; the frame carries a `seq`, which is the field every
    client places a card by. A note pinned to one row (a translation, or a
    fact-check that named the line it judged) has a range of exactly that row,
    so it can say `seq` and be placed after a reload instead of falling to the
    bottom of the transcript. A note that really does span a window keeps
    `seq: null` and stays where it belongs, after everything it read.
    """
    anchor = note.get("anchor_seq")
    if isinstance(anchor, (int, float)):
        return dict(note, seq=int(anchor))
    seq_from, seq_to = note.get("seq_from"), note.get("seq_to")
    pinned = seq_from is not None and seq_from == seq_to
    return dict(note, seq=int(seq_to) if pinned else None)


LANE_EDGE = "edge"
LANE_SERVER = "server"
# How often a device that cannot transcribe looks for its engine again after
# losing it (the backoff itself lives in api/live_speech.py).
_ENGINE_RECHECK_SECONDS = 5.0
# Shorter lines are identified but never learned from (a voice needs more than
# a word or two to be sure of).
_LEARN_MIN_MS = 3000

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
# A jump this big in the client's OWN packet clock means audio it chose not to
# send — the phone does not upload the silence between utterances — so the next
# packet starts a new chunk. Every reader assumes a chunk's samples run on
# unbroken from its `ts0_ms`; across a skipped silence that put every later line
# in the chunk seconds away from its own audio, so identification and the
# language rescue heard someone else's words. Packets inside an utterance are
# 20 ms apart. Rate-limited by the chunk's wall-clock age, so a client
# alternating its timestamps cannot mint a file per packet.
_AUDIO_GAP_ROLL_MS = 300
_AUDIO_GAP_MIN_CHUNK_SECONDS = 1.0

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

    ``embed`` is True only when the voiceprint model is loadable RIGHT NOW —
    the extra installed and the checkpoint already on disk. It was hardcoded
    False for a good reason and that reason has not changed: a device that
    believes in server-side identification which does not exist trusts labels
    nothing is producing. So this reports the machine, not the intention.

    A fresh install therefore says False on its first handshake, because the
    26 MB checkpoint is fetched in the background by the first identification
    job rather than on the handshake path. Later handshakes say True.
    """
    return {
        "stt": _server_stt_available(),
        "embed": _embed_available(),
        "embed_model": live_config.load()["embed_model"],
        # What a device may ask for in `caps.out` (design §13.1). A device with
        # no synthesiser of its own needs to know what the server can hand it
        # before it declares a codec it will then never be sent.
        "out": {"text": True, "speak": True,
                "audio": [live_deliver.SERVER_AUDIO_CODEC]},
    }


def _embed_available() -> bool:
    """Whether server-side identification can run. Never raises, never False-y
    for the wrong reason: an import error in the optional module is exactly the
    case that must answer False rather than break the handshake."""
    try:
        from api import live_voiceprint
        return bool(live_voiceprint.available())
    except Exception:
        logger.debug("live: voiceprint module unavailable", exc_info=True)
        return False


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


# Used when the model's context window cannot be resolved. Deliberately
# modest: rolling over too early costs an extra chat, too late costs the
# model its ability to read the session back.
_FALLBACK_CONTEXT_TOKENS = 128_000


def rollover_token_budget(cfg: Optional[Dict[str, Any]] = None) -> int:
    """How much transcript a live session may hold before a new one starts.

    A session used to begin on every tap of Record, which produced nine "Live"
    chats in half an hour. The ceiling is expressed against the MODEL's context
    window rather than a flat number, because the thing it protects is the
    model's ability to read the session back: half a context is the default.

    An explicit `session_rollover_tokens` wins when set, for a user who would
    rather name the number than trust a context lookup.
    """
    cfg = cfg or live_config.load()
    explicit = int(cfg.get("session_rollover_tokens") or 0)
    if explicit > 0:
        return explicit
    fraction = float(cfg.get("session_rollover_fraction") or 0.5)
    return max(1000, int(_model_context_tokens(cfg) * fraction))


def _model_context_tokens(cfg: Optional[Dict[str, Any]] = None) -> int:
    """The context window of the model that reads these transcripts.

    `live.model` first: the whole point of this budget is the context of the
    model that will have to read the session back, and since that model became
    pickable in the Live settings, the app's default is no longer the right
    answer for a user who chose one. Falls back to the app's model, and then to
    a conservative constant — an unknown model must not stop a recording, and a
    short guess only means sessions roll over sooner.
    """
    cfg = cfg or {}
    for name in (str(cfg.get("model") or ""), _app_model()):
        found = _catalogue_context(name)
        if found:
            return found
    return _FALLBACK_CONTEXT_TOKENS


def _app_model() -> str:
    try:
        from api import config as _config
        return str(getattr(_config, "DEFAULT_MODEL", "") or "")
    except Exception:
        logger.debug("live: could not read the app's model", exc_info=True)
        return ""


def _catalogue_context(model: str) -> int:
    """The offline context lookup, and only the offline one.

    `get_model_context_length()` is the full resolver, and it can probe an
    endpoint over the network — which is not something to do on the handshake
    path of a recorder. This is its last offline step: the hardcoded
    catalogue, longest key first so `claude-sonnet-4` cannot match the entry
    for `claude-sonnet-4-6`. A provider-qualified id (`anthropic/claude-opus-5`
    from /api/models) matches the same way, because the keys are substrings.

    Previously this read a name that module does not export, so every lookup
    raised and every session silently rolled over against the fallback.
    """
    lowered = str(model or "").strip().lower()
    if not lowered:
        return 0
    try:
        from agent.model_metadata import DEFAULT_CONTEXT_LENGTHS
    except Exception:
        logger.debug("live: the model catalogue is unavailable", exc_info=True)
        return 0
    for key, length in sorted(DEFAULT_CONTEXT_LENGTHS.items(),
                              key=lambda kv: len(kv[0]), reverse=True):
        if key.lower() in lowered:
            return int(length)
    return 0


def session_is_full(live_session_id: str,
                    cfg: Optional[Dict[str, Any]] = None) -> bool:
    """Whether this session has accumulated enough transcript to roll over."""
    if not live_session_id:
        return False
    budget = rollover_token_budget(cfg)
    return int(live_store.session_text_stats(live_session_id)["est_tokens"]) >= budget


def assign_lane(caps: Optional[Dict[str, Any]]) -> str:
    """Edge lane iff the device transcribes on its own.

    Transcription and voiceprints are INDEPENDENT capabilities, and treating
    them as one was a real bug: requiring a matching embedder before granting
    the edge lane demoted a phone that had Apple's on-device transcriber but no
    embedder yet, sending it to the server lane — which does not transcribe at
    all. The result was a session that recorded audio and produced an empty
    transcript, with the UI honestly reporting "transcribing on the server".

    So the lane answers only "who turns audio into text". Whether this device
    can also produce a comparable voiceprint is answered separately by
    `embeddings_trusted`, and affects identification, not transcription: an
    edge device without an embedder sends text, and its speakers stay
    provisional until server-side identification exists.
    """
    if not isinstance(caps, dict):
        return LANE_SERVER
    if str(caps.get("stt") or "").strip() != "on_device":
        return LANE_SERVER
    return LANE_EDGE


def embeddings_trusted(caps: Optional[Dict[str, Any]]) -> bool:
    """Whether this device's voiceprints are comparable with the stored ones.

    The interlock of §5.3, kept intact and simply moved off the lane decision:
    a vector computed by a different checkpoint is meaningless rather than
    merely imprecise, so an id mismatch costs the device its voiceprints, not
    its ability to transcribe.
    """
    if not isinstance(caps, dict):
        return False
    if str(caps.get("embed") or "").strip() != "on_device":
        return False
    declared = str(caps.get("embed_model") or "").strip()
    expected = str(live_config.load()["embed_model"] or "").strip()
    return bool(declared and expected and declared == expected)


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
        # The last timestamp the CLIENT stamped, for spotting audio it skipped.
        self._last_client_ms: Optional[int] = None
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
            elif self._path is not None and ts_ms and self._skipped_audio(now_ms):
                rolled = self._close_locked()
            if ts_ms:
                # Only a client's own stamps: wall-clock stand-ins advance by
                # ARRIVAL, and a burst after a stall would look like a gap.
                self._last_client_ms = now_ms
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

    def snapshot(self) -> Optional[Dict[str, Any]]:
        """What this writer currently holds, for reading audio back mid-chunk.

        Speaker identification needs an utterance's audio while the chunk it
        landed in is still open — a chunk is five minutes and an utterance is
        seconds, so waiting for the roll would mean identifying nothing until
        the recording was nearly over. The buffered tail is copied out because
        it is about to be flushed under the caller.
        """
        with self._lock:
            if self._path is None:
                return None
            return {"path": self._path, "ts0_ms": self._ts0_ms,
                    "ts1_ms": self._ts1_ms, "buffered": bytes(self._buf),
                    "codec": self.profile["stored"],
                    "device_id": self.device_id}

    # ── internals (caller holds the lock) ──

    def _should_roll(self) -> bool:
        """Wall clock only.

        Rolling on the CLIENT's timestamp let a client alternating a small and a
        huge ts_ms roll a chunk per packet — a file plus a `live_audio` row every
        20 ms. The clock that decides how much a crash costs has to be ours.
        """
        return bool(self._opened_at
                    and time.time() - self._opened_at >= _AUDIO_CHUNK_SECONDS)

    def _skipped_audio(self, now_ms: int) -> bool:
        """Whether this packet comes after audio the client did not send."""
        last = self._last_client_ms
        if last is None or now_ms - last <= _AUDIO_GAP_ROLL_MS:
            return False
        return bool(self._opened_at and time.time() - self._opened_at
                    >= _AUDIO_GAP_MIN_CHUNK_SECONDS)

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


def close_language_pool(wait: bool = True) -> None:
    """Stop the language-rescue worker and wait for the job in flight.

    It is a background thread that reads audio and writes to the transcript
    AFTER the request that spawned it has returned, so anything that tears the
    store down underneath it — a test's temp directory, a profile switch, an
    interpreter exiting — has to stop it first or it writes into a database
    that is no longer there.
    """
    global _lang_pool, _lang_inflight
    with _lang_lock:
        pool, _lang_pool = _lang_pool, None
        _lang_inflight = 0
    if pool is not None:
        try:
            pool.shutdown(wait=wait)
        except Exception:
            logger.debug("live: language pool would not shut down",
                         exc_info=True)


atexit.register(close_language_pool)


def ingest_audio_chunk(live_session_id: str, payload: bytes, *, ts_ms: int = 0,
                       device_id: str = "", codec: str = "",
                       rate: int = 16000) -> Dict[str, Any]:
    writer = writer_for(live_session_id, device_id, codec, rate)
    return writer.append(payload, ts_ms)


# ── reading audio back for one utterance ───────────────────────────────────

# The two spellings `_codec_profile` writes that can be turned back into
# samples. Anything else (an unknown codec stored as `<name>-len32@<rate>`) is
# kept verbatim on disk but cannot be read back here.
_PCM_CODEC_RE = re.compile(r"^pcm16@(\d+)$")
_OPUS_CODEC_RE = re.compile(r"^opus-packets-len32@(\d+)$")

# Opus decodes to any rate the caller asks for, so ask for the one the model
# wants. That also sidesteps `live_voiceprint`'s crude resampler: libopus'
# internal resampling is far better than a boxcar decimation.
_OPUS_DECODE_RATE = 16000
_MAX_OPUS_PACKET_BYTES = 1500
# How many overlapping chunks to actually read before giving up. More than one
# because a claimed extent can be wrong in either direction; small because each
# try decodes audio.
_MAX_CHUNK_TRIES = 3


def _pcm_codec(codec: str) -> Tuple[str, int]:
    """``("pcm16"|"opus", rate)`` for a stored codec label, else ``("", 0)``."""
    match = _PCM_CODEC_RE.match(codec or "")
    if match:
        return "pcm16", int(match.group(1))
    match = _OPUS_CODEC_RE.match(codec or "")
    if match:
        return "opus", int(match.group(1))
    return "", 0


def pcm_for_range(live_session_id: str, ts_start_ms: int, ts_end_ms: int,
                  device_id: str = "") -> Optional[Tuple[bytes, int]]:
    """The stored samples covering one segment's time range: ``(pcm16, rate)``.

    The region of the chunk covering the segment, located by the ONE time base
    the module docstring describes — ``ts_start_ms``/``ts_end_ms`` are already
    ms-since-session-start (`to_offset_ms` guarantees it) and so is a chunk's
    ``ts0_ms``, so the offset is a subtraction rather than a guess.

    Both stored shapes are readable. ``pcm16`` is sliced by byte offset;
    ``opus-packets-len32`` is unframed and decoded through ``api.voice_opus``,
    the ctypes binding over the system libopus that the voice socket already
    uses — so this costs no new dependency. **The iPhone streams Opus**, which
    is the case that matters: an earlier version of this function recognised
    only ``pcm16``, so it returned None for every real recording and
    identification silently never ran.

    One honest limit: the offset assumes the chunk's samples run contiguously
    at ``rate`` from ``ts0_ms``, which is what continuous ambient capture
    produces. A client that stops and restarts inside one chunk leaves a gap no
    offset can see, and the slice drifts. That costs one identification, not
    the transcript.
    """
    span_ms = max(0, int(ts_end_ms) - int(ts_start_ms))
    if span_ms <= 0:
        return None
    candidates: List[Dict[str, Any]] = []
    with _writers_lock:
        writers = [w for key, w in _writers.items() if key[0] == live_session_id]
    for writer in writers:
        snap = writer.snapshot()
        if snap:
            candidates.append(snap)
    try:
        for row in live_store.audio_chunks(live_session_id):
            candidates.append({"path": Path(row["path"]),
                               "ts0_ms": int(row.get("ts0_ms") or 0),
                               "ts1_ms": int(row.get("ts1_ms") or 0),
                               "buffered": b"",
                               "codec": str(row.get("codec") or ""),
                               "device_id": str(row.get("device_id") or "")})
    except Exception:
        logger.debug("live: could not list audio chunks for %s",
                     live_session_id, exc_info=True)

    ranked: List[Tuple[int, Dict[str, Any], str, int]] = []
    for chunk in candidates:
        kind, rate = _pcm_codec(chunk["codec"])
        if not kind or rate <= 0:
            continue
        available = _chunk_bytes(chunk)
        if available < 8:
            continue
        if kind == "pcm16":
            # Derived from how many samples the chunk HOLDS. Exact, and it has
            # to be: `ts1_ms` is only the highest `ts_ms` a packet carried.
            chunk_end_ms = max(
                int(chunk["ts1_ms"]),
                int(chunk["ts0_ms"]) + int(available / 2 * 1000 / rate))
        else:
            # Compressed bytes do not map to time, so there is no cheap exact
            # extent for Opus, and `ts1_ms` cannot be trusted as one: a client
            # that omits `ts_ms` gets wall-clock stamps that advance by the
            # ARRIVAL time of its packets, so a spool replay uploading four
            # seconds of audio in one burst claims a few milliseconds. Claim
            # the roll period instead and let the decode settle it below.
            chunk_end_ms = max(int(chunk["ts1_ms"]),
                               int(chunk["ts0_ms"]) + _AUDIO_CHUNK_SECONDS * 1000)
        overlap = min(int(ts_end_ms), chunk_end_ms) - \
            max(int(ts_start_ms), int(chunk["ts0_ms"]))
        if overlap <= 0:
            continue
        # The capturing device first: two mics on one conversation hear the
        # same words at different distances, and the voiceprint should come
        # from the mic that produced the transcript row.
        if device_id and chunk["device_id"] and chunk["device_id"] != device_id:
            overlap -= span_ms  # ranked below any same-device chunk
        ranked.append((overlap, chunk, kind, rate))
    if not ranked:
        return None

    # Try the best-ranked chunks in order and let the READ decide, rather than
    # trusting any single extent. A claimed extent can be too small (a client
    # that does not advance `ts_ms`) or too large (the permissive Opus fallback
    # above, which let a finished chunk out-rank the one that genuinely held a
    # later utterance and decode off its own end). Both failure modes look the
    # same from here and both are settled by the same thing: whether real
    # samples come back.
    # Equal overlaps are the normal case for Opus, whose claimed extent is the
    # whole roll period: then the chunk that began most recently before the
    # line is the one holding it, now that a skipped silence starts a new chunk.
    start = int(ts_start_ms)
    ranked.sort(key=lambda item: (
        -item[0],
        -int(item[1]["ts0_ms"]) if int(item[1]["ts0_ms"]) <= start else float("inf")))
    best_pcm, best_rate = b"", 0
    for _overlap, chunk, kind, rate in ranked[:_MAX_CHUNK_TRIES]:
        if kind == "opus":
            pcm, out_rate = _decode_opus_span(
                chunk, int(ts_start_ms), int(ts_end_ms)), _OPUS_DECODE_RATE
        else:
            pcm, out_rate = _read_pcm_span(
                chunk, rate, int(ts_start_ms), int(ts_end_ms)), rate
        if not pcm:
            continue
        wanted = int(span_ms * out_rate / 1000) * 2
        if len(pcm) * 2 >= wanted:
            # At least half the utterance: good enough to identify on, and the
            # common case on the first try.
            return pcm, out_rate
        if len(pcm) > len(best_pcm):
            best_pcm, best_rate = pcm, out_rate
    return (best_pcm, best_rate) if best_pcm else None


def _decode_opus_span(chunk: Dict[str, Any], ts_start_ms: int,
                      ts_end_ms: int) -> bytes:
    """Unframe and decode an Opus chunk, returning the requested window.

    Opus carries decoder state between packets, so this decodes forward from
    the start of the chunk rather than seeking — but stops as soon as it has
    passed the window, so the cost is proportional to the utterance's position,
    not the chunk's length. Measured on a real iPhone chunk: 531x realtime, so
    even the far end of a five-minute chunk is well under a second on the
    single background worker.
    """
    try:
        from api import voice_opus
    except Exception:
        logger.debug("live: the Opus binding is unavailable", exc_info=True)
        return b""
    data = _chunk_data(chunk)
    if len(data) < 8:
        return b""
    rate = _OPUS_DECODE_RATE
    want_bytes = max(0, int((ts_end_ms - int(chunk["ts0_ms"])) * rate / 1000)) * 2
    try:
        decoder = voice_opus.OpusDecoder(sample_rate=rate, channels=1)
    except Exception as exc:
        # libopus missing is a deployment fact, not a bug: say it once and
        # leave the voice provisional.
        _report_identification("skipped: libopus is not installed, so Opus "
                               "audio cannot be decoded", str(exc))
        return b""
    out = bytearray()
    offset = 0
    while offset + 4 <= len(data):
        size = struct.unpack(">I", data[offset:offset + 4])[0]
        offset += 4
        if size <= 0 or size > _MAX_OPUS_PACKET_BYTES or offset + size > len(data):
            # A truncated tail is normal: the chunk is still being written.
            break
        try:
            # A packet libopus refuses decodes to nothing, which shifts
            # everything after it earlier by that packet's duration. Rare, and
            # the cost is one misaligned identification rather than a crash.
            out += decoder.decode(data[offset:offset + size])
        except Exception:
            logger.debug("live: an Opus packet did not decode", exc_info=True)
            break
        offset += size
        if want_bytes and len(out) >= want_bytes:
            break
    byte_from = max(0, int((ts_start_ms - int(chunk["ts0_ms"])) * rate / 1000)) * 2
    return bytes(out[byte_from:want_bytes or None])


def _chunk_data(chunk: Dict[str, Any]) -> bytes:
    """The whole chunk: what is on disk plus the tail still buffered."""
    path = Path(chunk["path"])
    try:
        on_disk = path.read_bytes() if path.exists() else b""
    except OSError:
        logger.debug("live: could not read an audio chunk", exc_info=True)
        on_disk = b""
    return on_disk + (chunk.get("buffered") or b"")


def _chunk_bytes(chunk: Dict[str, Any]) -> int:
    """Samples on disk plus the tail still buffered, in bytes.

    The file is stat'd rather than trusting `live_audio.bytes`: an open chunk
    has no row yet, and a row's size is written when the chunk closes.
    """
    try:
        path = Path(chunk["path"])
        on_disk = path.stat().st_size if path.exists() else 0
    except OSError:
        on_disk = 0
    return on_disk + len(chunk.get("buffered") or b"")


def _read_pcm_span(chunk: Dict[str, Any], rate: int, ts_start_ms: int,
                   ts_end_ms: int) -> bytes:
    """Bytes ``[ts_start, ts_end)`` of one pcm16 chunk, file plus buffered tail."""
    def _byte_at(ts_ms: int) -> int:
        samples = int(max(0, ts_ms - int(chunk["ts0_ms"])) * rate / 1000)
        return samples * 2  # int16, mono — always sample-aligned

    byte_from, byte_to = _byte_at(ts_start_ms), _byte_at(ts_end_ms)
    if byte_to <= byte_from:
        return b""
    path = Path(chunk["path"])
    buffered = chunk.get("buffered") or b""
    out = bytearray()
    try:
        on_disk = path.stat().st_size if path.exists() else 0
    except OSError:
        on_disk = 0
    if byte_from < on_disk:
        try:
            with open(path, "rb") as fh:
                fh.seek(byte_from)
                out += fh.read(min(byte_to, on_disk) - byte_from)
        except OSError:
            logger.debug("live: could not read audio for identification",
                         exc_info=True)
            return b""
    if buffered and byte_to > on_disk:
        lo = max(0, byte_from - on_disk)
        out += buffered[lo:byte_to - on_disk]
    if len(out) % 2:
        out = out[:-1]
    return bytes(out)


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


# SQLite's signed 64-bit ceiling. A timestamp above it cannot be stored,
# and propagating one raised OverflowError on every chunk close.
_MAX_TS_MS = (1 << 63) - 1


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

    def _stamped() -> int:
        return max(0, int(time.time() * 1000) - started) if started else 0

    if raw is None:
        return _stamped()
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return _stamped()
    # A timestamp we cannot store is worse than one we do not have. The wire
    # field is 8 bytes read UNSIGNED, so a client writing a top-bit-set value
    # produces a number above SQLite's signed 64-bit ceiling: `register_audio`
    # then raised OverflowError on every chunk close, which meant audio piled
    # up on disk while the storage panel kept saying nothing was stored. Fall
    # back to our own clock rather than propagating a number that cannot land.
    if not (0 <= value <= _MAX_TS_MS):
        logger.warning("live: refusing an unusable timestamp %r on %s",
                       raw, live_session_id)
        return _stamped()
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


def _notify_segment_appended(live_session_id: str, seq: int, *,
                             translate: bool = True) -> None:
    """Tell the watchers a segment landed. Their failure is never ours.

    Imported lazily and on every call: ``api.live_watchers`` may not exist yet,
    may fail to import, or may raise. Capture is the floor, so all three are the
    same non-event here.
    """
    try:
        from api.live_watchers import on_segment_appended
        try:
            on_segment_appended(live_session_id, seq, translate=translate)
        except TypeError:
            # A watcher module older than the `translate` flag, or a stub. It
            # keeps working and simply translates on the first label it sees —
            # the behaviour before the rescue existed, which is degraded, not
            # broken. This module already treats the watcher layer as optional
            # and replaceable; its signature is part of that.
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
                       audio_ref: str = "",
                       voiceprint: Optional[List[float]] = None,
                       device_translates: bool = False,
                       transcribed_by: str = "") -> Dict[str, Any]:
    """Append one utterance, fan it out, then poke the watchers.

    `voiceprint` is the capturing device's own embedding of the utterance,
    already validated — identification then matches it directly instead of
    reading the audio back and embedding it here.

    `device_translates` is the device saying it translates this line itself
    (the phone's on-device translation, chosen in its Live settings). The
    server then leaves it alone: translating it here too bills a model call
    for an answer the phone already put on screen. A pair the phone cannot do
    still reaches the server, through `/api/live/translate`.

    `transcribed_by` names the server speech engine that heard this line
    (api/live_speech.py). That engine already decided the language from the
    audio itself, so the Whisper second opinion would only redo its work.

    Order matters: the row is durable before anyone is told about it, and the
    watchers run last so a slow or broken one delays nothing a viewer sees.
    """
    row = live_store.append_segment(
        live_session_id, ts_start_ms=int(ts_start_ms), ts_end_ms=int(ts_end_ms),
        text=text, lang=lang, speaker_id=speaker_id, speaker_conf=speaker_conf,
        local_label=local_label, device_id=device_id, audio_ref=audio_ref)
    row = segment_frame(row)
    publish(live_session_id, "seg", row)
    # The rescue may relabel this row's language, and translation keys on that
    # label — so when a rescue is really going to run, translation waits for
    # it. Otherwise an utterance gets translated on a label that is about to
    # change, which is how English spoken into a phone set to another locale
    # ended up with an English "translation" under it.
    rescuing = (False if transcribed_by
                else _rescue_language_async(row, device_translates=device_translates))
    _notify_segment_appended(live_session_id, int(row["seq"]),
                             translate=not rescuing and not device_translates)
    _identify_async(row, voiceprint,
                    grouped=bool(transcribed_by and local_label) and _engine_splits_speakers())
    return row


def _engine_splits_speakers() -> bool:
    """`live.speaker_split: engine` — the engine's labels decide who is who."""
    try:
        return live_config.load().get("speaker_split") == "engine"
    except Exception:
        return False


def publish_translation(live_session_id: str, seq: int, translation: str,
                        target: str = "") -> None:
    """Store a translation someone other than the server's translator made, and show it."""
    live_store.set_translation(live_session_id, seq, translation)
    _publish_translation_frame(live_session_id, seq, translation, target)


def _publish_translation_frame(live_session_id: str, seq: int, translation: str,
                               target: str = "") -> None:
    # Every viewer sees it through the same frame the server's own translator publishes.
    rows = live_store.segments_after(live_session_id, after_seq=seq - 1, limit=1)
    row = rows[0] if rows and int(rows[0].get("seq") or 0) == seq else None
    publish(live_session_id, "insight", {"kind": "translation", "live_session_id": live_session_id,
                                         "seq": seq, "text": translation,
                                         "translation": translation,
                                         "source_lang": str((row or {}).get("lang") or ""),
                                         "target": str(target or "")})


# ── the language actually spoken (see api/live_language.py) ────────────────

# Its own single worker rather than sharing the identification pool: a Whisper
# pass is hundreds of milliseconds against identification's ~40, and queueing
# them together would make every speaker label wait behind a transcription.
_LANG_WORKERS = 1
_MAX_LANG_INFLIGHT = 32

_lang_pool: Optional[Any] = None
_lang_inflight = 0
_lang_lock = threading.Lock()


def _segment_text(live_session_id: str, seq: int) -> str:
    """What the device heard, for when the rescue relabels without replacing."""
    rows = live_store.segments_after(live_session_id, after_seq=seq - 1, limit=1)
    if rows and int(rows[0].get("seq") or 0) == seq:
        return str(rows[0].get("text") or "")
    return ""


def _notify_language_settled(live_session_id: str, seq: int) -> None:
    """Release the translation that was held while the language was in doubt.

    Same posture as `_notify_segment_appended`: the watcher layer is optional,
    so a module without this entry point (an older one, or a stub) simply means
    no translation for that segment rather than an exception on this thread.
    """
    try:
        from api.live_watchers import on_language_settled
        on_language_settled(live_session_id, seq)
    except Exception:
        logger.debug("live: could not release the translation for %s#%s",
                     live_session_id[:8] or "?", seq, exc_info=True)


def _rescue_language_async(row: Dict[str, Any], *,
                           device_translates: bool = False) -> bool:
    """Queue a second opinion on what language this utterance was in.

    Returns whether a rescue is really going to run, because the caller holds
    translation back when it is — and a translation that never fires because a
    queue was full would be worse than one fired on a stale label.

    Wrapped whole, like identification: this is called from the thread that
    just made the transcript durable, and capture is the floor (§8).
    """
    try:
        cfg = live_config.load()
        if not cfg.get("language_rescue"):
            return False
        text = str(row.get("text") or "").strip()
        if not text:
            return False
        from api import live_language
        if not live_language.available():
            return False
        return _lang_submit(
            _run_language_rescue,
            str(row.get("live_session_id") or ""),
            int(row.get("seq") or 0),
            int(row.get("ts_start_ms") or 0),
            int(row.get("ts_end_ms") or 0),
            str(row.get("device_id") or ""),
            str(row.get("lang") or ""),
            str(cfg.get("rescue_model") or ""),
            str(cfg.get("primary_language") or ""),
            device_translates)
    except Exception:
        logger.debug("live: language rescue could not be queued", exc_info=True)
        return False


def _lang_submit(fn, *args) -> bool:
    """Returns whether the job was actually accepted."""
    global _lang_pool, _lang_inflight
    with _lang_lock:
        if _lang_inflight >= _MAX_LANG_INFLIGHT:
            logger.debug("live: language rescue queue full; skipping one")
            return False
        if _lang_pool is None:
            from concurrent.futures import ThreadPoolExecutor
            _lang_pool = ThreadPoolExecutor(
                max_workers=_LANG_WORKERS, thread_name_prefix="live-lang")
        _lang_inflight += 1

    def _done(_fut) -> None:
        global _lang_inflight
        with _lang_lock:
            _lang_inflight -= 1

    try:
        _lang_pool.submit(fn, *args).add_done_callback(_done)
        return True
    except Exception:
        with _lang_lock:
            _lang_inflight -= 1
        logger.debug("live: language rescue could not be submitted",
                     exc_info=True)
        return False


def _republish_segment(live_session_id: str, seq: int) -> None:
    """Send one stored row out again, so every client replaces it in place.

    The same `seg` frame an utterance arrives on — clients key on `seq` and
    upsert. `segments_after` is the only single-row reader the store has;
    asking for one row from just before this seq is how the watchers do it too.
    """
    rows = live_store.segments_after(live_session_id, after_seq=seq - 1, limit=1)
    row = rows[0] if rows and int(rows[0].get("seq") or 0) == seq else None
    if row:
        publish(live_session_id, "seg", segment_frame(row))


def _run_language_rescue(live_session_id: str, seq: int, ts_start_ms: int,
                         ts_end_ms: int, device_id: str, declared_lang: str,
                         model_name: str, primary_language: str,
                         device_translates: bool = False) -> None:
    """Re-hear one utterance and, if it was another language, correct it.

    Every failure here is a log line and an unchanged segment: the phone's
    transcript is already on screen and already durable, so the worst outcome
    of this whole path is that it stays as it was.

    Translation is released in `finally` whatever happens, because the caller
    held it back for us. A rescue that fails must cost a correction, never the
    translation that was waiting on it. Unless the device translates its own
    lines: then nothing was held, Whisper's English pass is skipped, and the
    corrected row going back to the phone is what gets it translated.
    """
    from api import live_language

    corrected = {"stored": False}

    def _store_correction(found: Dict[str, Any]) -> bool:
        """Relabel the row and put it in front of every viewer, once."""
        if corrected["stored"]:
            return True
        row_text = _segment_text(live_session_id, seq)
        try:
            # `text` is absent when the language was clear but the words came
            # back mangled: relabel the row, keep what the device heard.
            live_store.set_transcription(
                live_session_id, seq,
                found.get("text") or str(row_text or ""), found["lang"])
        except Exception:
            logger.warning("live: could not store the corrected transcript "
                           "for %s#%s", live_session_id[:8] or "?", seq,
                           exc_info=True)
            return False
        corrected["stored"] = True
        logger.info("live: %s#%s was %s, not %s (%.2f) — transcript corrected",
                    live_session_id[:8] or "?", seq, found["lang"],
                    declared_lang or "unlabelled", found["confidence"])
        _republish_segment(live_session_id, seq)
        return True

    try:
        audio = pcm_for_range(live_session_id, ts_start_ms, ts_end_ms, device_id)
        if audio is None:
            return
        # The corrected line goes out as soon as it is heard, before Whisper
        # decodes its English: a phone translates it itself in a third of a
        # second, where waiting cost ~1.7 s of the wrong words on screen.
        found = live_language.rescue(
            audio[0], audio[1], declared_lang,
            model_name=model_name or live_language.DEFAULT_MODEL,
            translate_to="" if device_translates else primary_language,
            on_heard=_store_correction)
        if not found or not _store_correction(found):
            return
        if found.get("translation"):
            try:
                live_store.set_translation(live_session_id, seq,
                                           found["translation"])
            except Exception:
                logger.warning("live: could not store the rescue's translation "
                               "for %s#%s", live_session_id[:8] or "?", seq,
                               exc_info=True)
                return
            _republish_segment(live_session_id, seq)
    finally:
        # Now the language is settled, whichever way it went. If this segment
        # really was the primary language, the gate will skip it — which is the
        # whole point: an English line no longer gets an English "translation".
        if not device_translates:
            _notify_language_settled(live_session_id, seq)


# ── speaker identification (design §5.2, the authority lane) ───────────────

# One worker: identification runs beside the recorder, and serialising it keeps
# the order of decisions the same as the order of speech — which is what makes
# the pending-group promotion in `live_voiceprint` deterministic.
#
# It is not cheap. Measured on this server over real utterances: 107 ms to read
# and decode the Opus, 140 ms to embed, 29 ms to match — 276 ms mean and 467 ms
# worst, per utterance, on top of the upload. An earlier comment here claimed
# ~40 ms, which was never measured and is off by most of an order of magnitude.
# That number is the whole argument for doing this on the device one day: the
# phone holds the raw PCM already, so it skips both the upload and the decode.
_IDENT_WORKERS = 1
# A memory bound on the queue, NOT a rate limit. This was 4, which looked
# reasonable and was wrong: design §8's normal case is a phone whose socket
# drops about once a minute and then uploads its spool, so utterances arrive in
# bursts of dozens, and a cap of 4 meant everything after the fourth was
# declined and stayed permanently unlabelled — nothing retries a dropped job.
# Identification is ~40 ms of CPU per utterance, so a full queue drains in a
# couple of seconds on the single worker; the cap only has to stop an
# unbounded backlog from growing server memory.
_MAX_IDENT_INFLIGHT = 64

_ident_pool: Optional[Any] = None
_ident_inflight = 0
_ident_lock = threading.Lock()


def _ident_submit(fn, *args) -> bool:
    """Run `fn` off the capture thread, or decline. Never raises.

    Same shape as `live_watchers._submit`, and for the same reason: the caller
    is the thread appending segments, and the worst outcome available here is
    an unlabelled voice, not a stalled recorder.
    """
    global _ident_inflight, _ident_pool
    from concurrent.futures import ThreadPoolExecutor

    with _ident_lock:
        if _ident_inflight >= _MAX_IDENT_INFLIGHT:
            logger.debug("live: identification queue full (%d); this segment "
                         "stays provisional", _ident_inflight)
            return False
        if _ident_pool is None:
            _ident_pool = ThreadPoolExecutor(
                max_workers=_IDENT_WORKERS, thread_name_prefix="live-voiceprint")
        pool = _ident_pool
        _ident_inflight += 1

    def _run() -> None:
        global _ident_inflight
        try:
            fn(*args)
        except Exception as exc:
            _report_identification("failed", f"{type(exc).__name__}: {exc}")
            logger.warning("live: identification job failed", exc_info=True)
        finally:
            with _ident_lock:
                _ident_inflight -= 1

    try:
        pool.submit(_run)
        return True
    except Exception:
        with _ident_lock:
            _ident_inflight -= 1
        logger.warning("live: could not schedule identification", exc_info=True)
        return False


# Outcomes already announced at INFO. A fixed, small vocabulary, so this is
# bounded: each distinct reason surfaces once and then drops to debug.
_ident_reported: set = set()
_ident_report_lock = threading.Lock()


def _report_identification(outcome: str, detail: str = "") -> None:
    """Say, once per distinct outcome, what identification actually did.

    This exists because the first deployment of this feature was a SILENT
    no-op: `pcm_for_range` recognised only raw PCM, every real (Opus) recording
    returned None, the job exited before touching the model, and nothing was
    logged at any level — so a completely broken feature was indistinguishable
    from a working one in the journal. An outcome line per reason is the
    difference between "diagnose in one minute" and "diagnose from a database
    dump".
    """
    with _ident_report_lock:
        first = outcome not in _ident_reported
        if first:
            _ident_reported.add(outcome)
    message = "live: speaker identification %s%s"
    suffix = f" — {detail}" if detail else ""
    if first:
        logger.info(message, outcome, suffix)
    else:
        logger.debug(message, outcome, suffix)


def reset_identification_reports_for_tests() -> None:
    with _ident_report_lock:
        _ident_reported.clear()


def _session_codecs(live_session_id: str) -> str:
    """The codec labels stored for a session, for a skip line that can be acted on."""
    seen = []
    try:
        with _writers_lock:
            seen += [w.profile["stored"] for key, w in _writers.items()
                     if key[0] == live_session_id]
        seen += [str(row.get("codec") or "")
                 for row in live_store.audio_chunks(live_session_id)]
    except Exception:
        logger.debug("live: could not list codecs", exc_info=True)
    return ", ".join(sorted({c for c in seen if c})) or "no audio stored"


def drain_identification(timeout: float = 5.0) -> bool:
    """Wait for queued identification to finish. True if the queue emptied.

    Exists for the test suite: an identification job resolves STATE_DIR when it
    runs, not when it was queued, so one outliving its test would open a
    connection against whatever STATE_DIR points at by then — the real one.
    """
    deadline = time.time() + max(0.0, timeout)
    while time.time() < deadline:
        with _ident_lock:
            if _ident_inflight <= 0:
                return True
        time.sleep(0.01)
    with _ident_lock:
        return _ident_inflight <= 0


def device_voiceprint(raw: Any) -> Optional[List[float]]:
    """A device's voiceprint off the wire, or None when it is not one.

    Exactly the model's dimension, every value finite, renormalised to unit
    length — `identify` compares by dot product, and a device rounding its
    floats for the wire must not drift the scale. Anything else is ignored
    rather than refused: the utterance is still identified the old way.
    """
    from api.live_voiceprint import EMBED_DIM
    if not isinstance(raw, list) or len(raw) != EMBED_DIM:
        return None
    try:
        vec = [float(v) for v in raw]
    except (TypeError, ValueError):
        return None
    if not all(math.isfinite(v) for v in vec):
        return None
    norm = math.sqrt(sum(v * v for v in vec))
    if not norm:
        return None
    return [v / norm for v in vec]


def _identify_async(row: Dict[str, Any],
                    voiceprint: Optional[List[float]] = None,
                    grouped: bool = False) -> None:
    """Queue identification for a freshly appended segment.

    `grouped`: a speech engine labelled this line's speaker and the engine's
    labels split the speakers (`_run_group_identification`).

    Wrapped whole: this is called from the thread that just made the transcript
    durable, and design §8 is unambiguous that nothing optional may stop it.
    """
    try:
        if grouped:
            from api import live_voiceprint
            if not live_voiceprint.can_try():
                _report_identification("skipped: no usable embedder")
                return
            _ident_submit(_run_group_identification, str(row.get("live_session_id") or ""),
                          int(row.get("seq") or 0), int(row.get("ts_start_ms") or 0),
                          int(row.get("ts_end_ms") or 0), str(row.get("device_id") or ""),
                          dict(row))
            return
        if row.get("speaker_id"):
            # Already attributed — an edge device whose voiceprints the
            # interlock trusts, or a re-ingested segment. Identifying it again
            # would fight the device for the label.
            _report_identification(
                "skipped: the capturing device already attributed this segment")
            return
        from api import live_voiceprint
        # A device's voiceprint needs no model here: matching is arithmetic
        # over the stored voices.
        if voiceprint is None and not live_voiceprint.can_try():
            _report_identification(
                "skipped: no usable embedder",
                "install the extra (pip install 'jarviscopilot[live-voiceprint]') "
                "or check the log above for why the model would not load")
            return
        _ident_submit(_run_identification, str(row.get("live_session_id") or ""),
                      int(row.get("seq") or 0),
                      int(row.get("ts_start_ms") or 0),
                      int(row.get("ts_end_ms") or 0),
                      str(row.get("device_id") or ""),
                      dict(row), voiceprint)
    except Exception:
        logger.debug("live: identification could not be queued", exc_info=True)


def _run_identification(live_session_id: str, seq: int, ts_start_ms: int,
                        ts_end_ms: int, device_id: str,
                        row: Dict[str, Any],
                        voiceprint: Optional[List[float]] = None) -> None:
    """Embed this utterance's audio, decide whose voice it is, tell the clients.

    Runs on the identification pool, so every failure mode here is a log line
    and an unlabelled segment. With the device's own `voiceprint` it goes
    straight to the match: no audio read back, no Opus decode, no embedding —
    107 ms + 140 ms of the 276 ms mean this cost per line on the server.
    """
    from api import live_voiceprint

    if voiceprint is not None:
        _decide_identity(live_session_id, seq, row, voiceprint, source="device")
        return
    audio = pcm_for_range(live_session_id, ts_start_ms, ts_end_ms, device_id)
    if audio is None:
        _report_identification(
            "skipped: no readable audio covering this segment",
            f"segment {ts_start_ms}-{ts_end_ms}ms, stored codecs: "
            f"{_session_codecs(live_session_id)}")
        return
    vec = live_voiceprint.embed(audio[0], audio[1])
    if vec is None:
        _report_identification(
            "skipped: the embedder produced nothing",
            f"{len(audio[0]) // 2} samples at {audio[1]} Hz — too short to "
            "carry a voice, or the model did not load (see the log above)")
        return
    # Seeding "me" from stored voice turns (§5.4) needs the model loaded, which
    # it now demonstrably is, and it belongs on this thread rather than the
    # recorder's. At most once per process.
    live_voiceprint.enrol_me_once()
    _decide_identity(live_session_id, seq, row, vec, source="server")


# ── one speaker per engine label (`live.speaker_split: engine`) ─────────────
#
# A speech engine that labels speakers already knows which lines inside its
# stream are one person — Soniox split every trial clip right, where one line's
# voiceprint is wrong about one time in eight (bench 2026-09-24). So a label is
# a group: its lines share one speaker, named from the voiceprint of all its
# audio pooled (each line weighted by its length), a new voice is minted once
# and only from 3 s of audio or more, and a line teaches the voice its group was
# given rather than whatever it would have matched alone. Labels are unique per
# engine stream (`<engine>:<lane>-<stream>:<label>`, api/live_speech.py), so a
# group never spans two streams.

_GROUP_MIN_EMBED_MS = 1000   # shorter lines join their group but add no voiceprint
_MAX_GROUPS = 256
_MAX_GROUP_SEQS = 500
_groups: "OrderedDict[Tuple[str, str], Dict[str, Any]]" = OrderedDict()
_groups_lock = threading.Lock()


def _group_embed(live_session_id: str, ts_start_ms: int, ts_end_ms: int,
                 device_id: str) -> Optional[List[float]]:
    """One line's voiceprint from its stored audio, or None."""
    from api import live_voiceprint
    audio = pcm_for_range(live_session_id, ts_start_ms, ts_end_ms, device_id)
    if audio is None:
        return None
    vec = live_voiceprint.embed(audio[0], audio[1])
    if vec is not None:
        live_voiceprint.enrol_me_once()
    return vec


def _group_for(key: Tuple[str, str]) -> Dict[str, Any]:
    """Caller holds `_groups_lock`."""
    group = _groups.get(key)
    if group is None:
        group = {"sum": None, "ms": 0, "minted": False, "seqs": [],
                 "speaker_id": "", "label_state": "", "decision": None}
        _groups[key] = group
        while len(_groups) > _MAX_GROUPS:
            _groups.popitem(last=False)
    else:
        _groups.move_to_end(key)
    return group


def _row_at(live_session_id: str, seq: int) -> Optional[Dict[str, Any]]:
    rows = live_store.segments_after(live_session_id, after_seq=seq - 1, limit=1)
    return rows[0] if rows and int(rows[0].get("seq") or 0) == seq else None


def _run_group_identification(live_session_id: str, seq: int, ts_start_ms: int,
                              ts_end_ms: int, device_id: str,
                              row: Dict[str, Any]) -> None:
    """Name this line's engine label from all the audio heard under it."""
    from api import live_voiceprint

    span = max(0, int(ts_end_ms) - int(ts_start_ms))
    vec = (_group_embed(live_session_id, ts_start_ms, ts_end_ms, device_id)
           if span >= _GROUP_MIN_EMBED_MS else None)
    key = (live_session_id, str(row.get("local_label") or ""))
    # One group job at a time: two lines of one label deciding at once could
    # each mint a voice, or apply their answers out of order.
    with _groups_lock:
        group = _group_for(key)
        group["seqs"].append(int(seq))
        del group["seqs"][:-_MAX_GROUP_SEQS]
        decision = None
        if vec is not None:
            weighted = [x * span for x in vec]
            group["sum"] = (weighted if group["sum"] is None
                            else [a + b for a, b in zip(group["sum"], weighted)])
            group["ms"] += span
            norm = math.sqrt(sum(x * x for x in group["sum"])) or 1.0
            pooled = [x / norm for x in group["sum"]]
            decision = live_voiceprint.identify(pooled, live_session_id=live_session_id,
                                                seq=seq, learn=False)
            if (decision is None and not group["minted"] and not group["speaker_id"]
                    and group["ms"] >= _LEARN_MIN_MS):
                decision = live_voiceprint.identify(pooled, live_session_id=live_session_id,
                                                    seq=seq, learn=True)
                group["minted"] = bool(decision and decision.get("new_speaker"))
        if decision and decision.get("speaker_id"):
            speaker = str(decision["speaker_id"])
            state = str(decision.get("label_state") or live_store.LABEL_PROVISIONAL)
            confirmed = state == live_store.LABEL_CONFIRMED
            if (confirmed and vec is not None and span >= _LEARN_MIN_MS
                    and not decision.get("new_speaker")):
                try:
                    live_store.add_embedding(speaker, vec, live_voiceprint.model_id(),
                                             f"{live_session_id}#{int(seq)}")
                except Exception:
                    logger.debug("live: could not keep the line's voiceprint", exc_info=True)
            changed = (speaker, state) != (group["speaker_id"], group["label_state"])
            group["speaker_id"], group["label_state"] = speaker, state
            group["decision"] = dict(decision, promoted=[], merged_from=None)
            targets = list(group["seqs"]) if changed else [int(seq)]
        elif group["decision"]:
            decision, targets = group["decision"], [int(seq)]
        else:
            _report_identification("skipped: not enough of this voice yet",
                                   f"{group['ms']} ms heard under {key[1]}")
            return
        for target in targets:
            target_row = row if target == int(seq) else _row_at(live_session_id, target)
            if target_row is not None:
                _apply_identification(live_session_id, target, target_row,
                                      decision if target == int(seq) else group["decision"])
    _report_identification(
        "succeeded", f"voice {group['speaker_id'][:8]}, {group['label_state']}, "
                     f"{group['ms']} ms pooled under {key[1]}, {len(targets)} line(s)")


def _decide_identity(live_session_id: str, seq: int, row: Dict[str, Any],
                     vec: List[float], *, source: str) -> None:
    """Match one voiceprint against the stored voices and apply the answer."""
    from api import live_voiceprint

    # A line under three seconds is too little voice to learn from: it can be
    # matched to a known voice, but it teaches none and mints none.
    span = int(row.get("ts_end_ms") or 0) - int(row.get("ts_start_ms") or 0)
    decision = live_voiceprint.identify(vec, live_session_id=live_session_id,
                                        seq=seq, learn=span <= 0 or span >= _LEARN_MIN_MS)
    if not decision:
        _report_identification("skipped: the embedding produced no decision")
        return
    _apply_identification(live_session_id, seq, row, decision)
    _report_identification(
        "succeeded",
        f"voice {str(decision.get('speaker_id') or '')[:8]}, "
        f"{decision.get('label_state')}, score {decision.get('score')}"
        f"{', newly minted' if decision.get('new_speaker') else ''}"
        f", {source} voiceprint")


def _apply_identification(live_session_id: str, seq: int, row: Dict[str, Any],
                          decision: Dict[str, Any]) -> None:
    """Write the decision to the store and fan out what clients need to relabel.

    The frame order matters and is set by what the shipped clients do with it:

    1. the segment's own ``seg`` frame, re-published with the resolved
       ``speaker_id``/``speaker_conf``/``label_state``. Both clients upsert a
       segment by ``seq``, so this is how the chip appears at all — and it is
       the ONLY frame a still-provisional decision sends, because a
       ``speaker{op:"confirm"}`` marks rows confirmed unconditionally and would
       overstate a middling match.
    2. on a confirmed decision, ``speaker{op:"confirm"}`` naming every seq this
       decision settles: the new one plus any that were being held
       provisionally for this voice.
    3. on a merge, a global ``speaker{op:"merge"}`` — a voice is not scoped to
       one transcript.
    """
    speaker_id = str(decision.get("speaker_id") or "")
    if not speaker_id:
        return
    label_state = str(decision.get("label_state")
                      or live_store.LABEL_PROVISIONAL)
    score = float(decision.get("score") or 0.0)
    confirmed = label_state == live_store.LABEL_CONFIRMED
    # A freshly minted voice has no similarity to report: `score` then holds
    # how UNLIKE the nearest known voice it was, which is not a confidence in
    # this label and read as "4% sure" in the UI's percentage badge. The column
    # is nullable and both clients omit the badge for null, which is the honest
    # rendering — the label is certain, the comparison is meaningless.
    conf: Optional[float] = None if decision.get("new_speaker") else score
    promoted = [int(q) for sid, q in (decision.get("promoted") or [])
                if str(sid) == live_session_id and int(q) != int(seq)]

    try:
        live_store.assign_speaker(live_session_id, seq, speaker_id,
                                  conf=conf, label_state=label_state)
        for other in promoted:
            live_store.assign_speaker(live_session_id, other, speaker_id,
                                      conf=conf,
                                      label_state=live_store.LABEL_CONFIRMED)
    except Exception:
        logger.warning("live: could not store the speaker for %s#%s",
                       live_session_id[:8] or "?", seq, exc_info=True)
        return

    updated = dict(row)
    updated.update({"speaker_id": speaker_id, "speaker_conf": conf,
                    "label_state": label_state})
    publish(live_session_id, "seg", segment_frame(updated))

    speaker = None
    try:
        speaker = live_store.get_speaker(speaker_id)
    except Exception:
        logger.debug("live: could not read the speaker row", exc_info=True)

    if confirmed:
        publish(live_session_id, "speaker", {
            "op": "confirm",
            "live_session_id": live_session_id,
            "speaker_id": speaker_id,
            # `seqs` is what the web client reads to pin specific rows; iOS
            # settles every row already carrying this speaker_id, which the
            # `seg` frames above have just given it.
            "seqs": sorted(set(promoted + [int(seq)])),
            "speaker_conf": conf,
            "label_state": live_store.LABEL_CONFIRMED,
            "new_speaker": bool(decision.get("new_speaker")),
            "kind": (speaker or {}).get("kind") or "other",
            "name": (speaker or {}).get("name"),
        })

    merged_from = decision.get("merged_from")
    if merged_from:
        # Every spelling the shipped clients read: the web store takes
        # `from_id`/`into_id`, and iOS takes the survivor from
        # `speaker_id`/`into` and the folded ids from `from`.
        _publish_speaker_op({
            "op": "merge",
            "speaker_id": speaker_id,
            "into": speaker_id,
            "into_id": speaker_id,
            "from": [str(merged_from)],
            "from_id": str(merged_from),
            "name": (speaker or {}).get("name"),
        })


# ── sessions and the paired chat (design §4) ───────────────────────────────


def _default_title() -> str:
    return time.strftime("Live · %Y-%m-%d %H:%M")


def _chat_header_text(live_session_id: str, title: str, device_id: str,
                      source_label: str, started_at: float) -> str:
    """Two lines a person wants: name, when, which mic.

    It used to carry the device uuid, the transcript id and a paragraph
    explaining that the transcript was deliberately elsewhere — developer
    prose in a surface the user reads, and false once the transcript moved
    into the chat. The chat->recording mapping lives in
    `live_session.chat_session_id` and `source_tag="live"`, which is what
    machine readers key on anyway.
    """
    when = time.strftime("%d %b at %H:%M", time.localtime(started_at or time.time()))
    mic = (source_label or "").strip()
    second = f"Started {when}" + (f" · {mic}" if mic else "")
    return f"**Live session** — {title}\n{second}"


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
        # Whether this device's voiceprints are comparable with the stored ones
        # (`embeddings_trusted`). Only then is an `emb` on its `seg` used.
        self.embeds = False
        # What this device can PRESENT (design §13.1). Filled from hello.caps;
        # a device that never declares one keeps the legacy shape, so the phone
        # that shipped before this existed is unaffected.
        self.out: Dict[str, Any] = live_deliver.device_out(None)
        # `reply_mode: spoken` on a device with no voice is a setting that
        # silently did nothing. Said once, not on every note.
        self._said_speech_missing = False
        self.ready = False
        self.closed = False
        # Accumulating partials, keyed by the track a device is streaming, so a
        # two-mic device cannot interleave two sentences into one. Ordered so the
        # bound below can drop the oldest unfinished one.
        # A mic label that arrived before hello (see on_text).
        self._pending_source: str = ""
        self._partials: "OrderedDict[str, Dict[str, Any]]" = OrderedDict()
        # Non-None only while a resume replay is in flight (see on_bus_event).
        self._replay_buffer: Optional[List[Dict[str, Any]]] = None
        self._replay_lock = threading.Lock()
        self._last_audio_seq = -1
        # A server speech engine hearing this device's audio (api/live_speech.py),
        # or None on the edge lane. `_caps_stt` is what the device said it can do
        # itself, which decides whether an engine failure can hand it the edge back.
        self.engine_lane = None
        self.engine_label = ""
        self._caps_stt = ""
        # When a device that cannot transcribe lost its engine, when to look again.
        self._engine_recheck_at = 0.0

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
        if event not in ("seg", "speaker", "insight", "speak", "state", "partial"):
            return
        if event == "insight":
            # A watcher emits ONE intent; the form is this device's own (§13.2).
            # Rendering here rather than at the publisher is what lets a device
            # that wants synthesised audio pay for its own synthesis on its own
            # fan-out thread instead of holding up everyone else's frame.
            for frame in self._delivery_frames(data or {}):
                self._emit(frame)
            return
        frame = dict(data or {})
        frame["t"] = event
        self._emit(frame)

    def _delivery_frames(self, intent: Dict[str, Any]) -> List[Dict[str, Any]]:
        """One intent, in the forms this device declared. Never raises."""
        try:
            mode = str(live_config.load().get("reply_mode") or "text")
        except Exception:
            mode = "text"
        try:
            rendered = live_deliver.render(
                intent, self.out, reply_mode=mode,
                say_speech_missing=not self._said_speech_missing)
        except Exception:
            # A note is not worth a dead socket, and a device that cannot be
            # rendered for must not stop the ones that can (§13.4).
            logger.warning("live: could not render a note for %s",
                           self.device_id or "?", exc_info=True)
            return []
        for frame in rendered:
            if frame.get("spoken_unavailable"):
                self._said_speech_missing = True
        return rendered

    def _emit(self, frame: Dict[str, Any]) -> None:
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
            if kind == "source":
                # The client reports its mic as soon as the socket opens, which
                # races the hello/ready round trip. Erroring put "send hello
                # first" over the phone's controls for a frame that carries no
                # urgency at all, so hold it and apply it once the session
                # exists. Ordering the client's sends is the better fix; this
                # keeps a harmless race from looking like a failure.
                self._pending_source = str(
                    msg.get("source_label") or msg.get("label") or "").strip()
                return
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
            lane, self.engine_lane = self.engine_lane, None
            if lane is not None:
                # The last line the engine is still hearing belongs to this session.
                # Detached first: a slow last reply is not the engine failing.
                lane.finish()
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
        self._write_audio(payload, ts_ms, seq=seq)

    def close(self) -> None:
        self.closed = True
        lane, self.engine_lane = self.engine_lane, None
        if lane is not None:
            lane.close()

    # ── handshake ──

    def _relane(self, msg: Dict[str, Any]) -> None:
        """Apply a mid-session capability change and re-announce the lane.

        No new session, no new paired chat, no replay: the client keeps its
        cursor and only its declared capabilities change.
        """
        caps = msg.get("caps") if isinstance(msg.get("caps"), dict) else {}
        self.can_speak = bool(caps.get("speak"))
        self.out = live_deliver.device_out(caps)
        codec = str(caps.get("codec") or "").strip()
        if codec:
            self.codec = codec
        self.lane = assign_lane(caps)
        self.embeds = embeddings_trusted(caps)
        self._caps_stt = str(caps.get("stt") or "").strip()
        self._choose_engine()
        logger.info("live: %s re-declared caps, lane now %s",
                    self.live_session_id, self.lane)
        self._send_ready(relane=True)

    def _send_ready(self, seq: Optional[int] = None, **extra: Any) -> None:
        if seq is None:
            seq = int((live_store.get_session(self.live_session_id)
                       or {}).get("last_seq") or 0)
        frame: Dict[str, Any] = {
            "t": "ready",
            "live_session_id": self.live_session_id,
            "chat_session_id": self.chat_session_id,
            "seq": seq,
            "lane": self.lane,
            "server_caps": server_caps(),
        }
        if self.engine_label:
            # Who is hearing this device when the lane is the server's.
            frame["engine"] = self.engine_label
        frame.update(extra)
        self.send(frame)

    # ── a server speech engine (api/live_speech.py) ──

    def _choose_engine(self) -> None:
        """Put this device on a server engine's lane when one is configured."""
        from api import live_speech
        # None while a failed engine is backing off, or when none is configured.
        # A device that cannot transcribe takes any engine that can run: on
        # "On the phone" it would otherwise store audio and show no words.
        engine = None
        if not live_speech.engine_blocked():
            engine = live_speech.live_engine()
            if engine is None and self._caps_stt != "on_device":
                engine = live_speech.any_live_engine()
        if engine is None:
            if self.engine_lane is not None:
                self.engine_lane.close()
            self.engine_lane, self.engine_label = None, ""
            return
        self.lane = LANE_SERVER
        self.engine_label = str(getattr(engine, "label", "") or engine.name)
        if self.engine_lane is None:
            self.engine_lane = live_speech.EngineLane(self, engine)

    def fallback_to_edge(self, reason: str) -> None:
        """The engine failed (no key, out of credit, outage): say so, hand the edge back."""
        lane, self.engine_lane = self.engine_lane, None
        if lane is None:
            return  # several streams can report one failure
        lane.close()
        label, self.engine_label = self.engine_label or "The speech engine", ""
        logger.warning("live: %s stopped on %s (%s)", label, self.live_session_id[:8] or "?", reason)
        self.send({"t": "state", "warning": "speech_engine",
                   "live_session_id": self.live_session_id,
                   "message": f"{label} stopped transcribing ({reason})."})
        if self._caps_stt == "on_device":
            self.lane = LANE_EDGE
            self._send_ready(relane=True)

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
        self.out = live_deliver.device_out(caps)
        self.lane = assign_lane(caps)
        self.embeds = embeddings_trusted(caps)
        self._caps_stt = str(caps.get("stt") or "").strip()
        self._choose_engine()

        resume = msg.get("resume") if isinstance(msg.get("resume"), dict) else {}
        want_sid = str(resume.get("live_session_id") or "").strip()
        after_seq = _as_int(resume.get("after_seq"), 0)

        row = live_store.get_session(want_sid) if want_sid else None
        # A full session is not resumed: the client always asks to continue the
        # last one (it cannot know the budget), and the server decides. `ready`
        # carries the id it actually bound, which is how the client learns a
        # rollover happened and resets its cursor.
        if row is not None and session_is_full(want_sid):
            logger.info("live: %s reached the rollover budget; starting a new "
                        "session", want_sid)
            row = None
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
        if self._pending_source:
            live_store.set_source_label(self.live_session_id,
                                        self._pending_source[:120])
            self._pending_source = ""
        self._send_ready(last_seq)
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
        if self.engine_lane is not None:
            # A server engine is this device's transcriber; the device's own lines
            # (sent before `ready` said so, or spooled) would be the same speech twice.
            return
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
                local_label=local_label, device_id=self.device_id,
                voiceprint=(device_voiceprint(msg.get("emb"))
                            if self.embeds else None),
                device_translates=str(msg.get("translate") or "") == "device")
        except KeyError:
            self.error("no_session", "live session no longer exists")
        except Exception:
            self._store_unavailable("utterance", exc=True)

    def _on_text_batch(self, msg: Dict[str, Any]) -> None:
        if self.engine_lane is not None:
            return  # as in _on_seg: the engine writes this device's lines
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
        spooled = []
        for chunk in chunks:
            if not isinstance(chunk, dict):
                continue
            payload = _decode_b64(chunk.get("data"))
            if payload is None:
                self.error("bad_audio", "chunk data must be base64")
                continue
            ts_ms = _as_int(chunk.get("ts_ms"), 0)
            result = self._write_audio(payload, ts_ms, codec=codec, rate=rate,
                                       warn=False, live=False)
            dropped += int((result or {}).get("dropped_bytes") or 0)
            if payload and not (result or {}).get("refused"):
                spooled.append((payload, to_offset_ms(self.live_session_id, ts_ms or None)))
        if dropped:
            self._warn_dropped(dropped)
        if spooled and self.engine_lane is not None:
            # Held while offline, so older than what the live stream is hearing:
            # heard on its own stream, at its own times.
            from api import live_speech
            live_speech.transcribe_spool(self.live_session_id, self.device_id, spooled,
                                         codec, rate)

    def _write_audio(self, payload: bytes, ts_ms: int, codec: str = "",
                     rate: int = 0, warn: bool = True,
                     live: bool = True, seq: Optional[int] = None) -> Dict[str, Any]:
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
        lane = self.engine_lane
        if live and lane is None:
            lane = self._engine_again()
        if live and lane is not None:
            lane.feed(payload, to_offset_ms(self.live_session_id, ts_ms or None),
                      codec or self.codec, rate or self.rate, seq=seq)
        return result

    def _engine_again(self):
        """A device that cannot transcribe lost its engine: take it back once the
        backoff has passed. A device that can was handed the edge lane instead, and
        gets the engine back on its next hello."""
        if self.lane != LANE_SERVER or self._caps_stt == "on_device":
            return None
        now = time.monotonic()
        if now < self._engine_recheck_at:
            return None
        self._engine_recheck_at = now + _ENGINE_RECHECK_SECONDS
        self._choose_engine()
        if self.engine_lane is not None:
            self._send_ready(relane=True)
        return self.engine_lane

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


class _Assembler:
    """Whole messages out of wsproto's events.

    wsproto hands a message over as it arrives: a frame split across two socket
    reads, or a message the client fragmented, comes out as several
    `TextMessage`/`BytesMessage` events, and only the last has
    `message_finished`. Treating each event as a message worked while every
    frame was small; a `seg` carrying a 256-value voiceprint is ~3 KB, straddled
    a read, and was parsed in halves — "frame was not JSON", and the line was
    lost.
    """

    def __init__(self) -> None:
        self._text: List[str] = []
        self._bytes = bytearray()

    def text(self, event) -> Optional[str]:
        self._text.append(event.data or "")
        if not getattr(event, "message_finished", True):
            return None
        whole, self._text = "".join(self._text), []
        return whole

    def binary(self, event) -> Optional[bytes]:
        self._bytes.extend(event.data or b"")
        if not getattr(event, "message_finished", True):
            return None
        whole, self._bytes = bytes(self._bytes), bytearray()
        return whole


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
    assembler = _Assembler()

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
                    payload = assembler.binary(event)
                    if payload is not None:
                        live.on_binary(payload)
                elif isinstance(event, TextMessage):
                    message = assembler.text(event)
                    if message is not None:
                        live.on_text(message or "{}")
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
    if path == "/api/live/digests":
        # The rolling-window summaries (§6) had no route at all, so nothing
        # could show a session's rollups. Separate from the transcript because
        # a digest is the COARSE layer of the coarse→fine retrieval the design
        # describes: you read digests to find the window, then pull the exact
        # segments. A client rebuilding a transcript wants /api/live/transcript.
        sid = (parse_qs(parsed.query).get("live_session_id", [""])[0] or "").strip()
        if not sid:
            bad(handler, "live_session_id required")
            return True
        if live_store.get_session(sid) is None:
            bad(handler, "live session not found", 404)
            return True
        j(handler, {"live_session_id": sid,
                    "digests": live_store.digests_for_session(sid)})
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
        # Every spelling, because the two shipped clients read different keys:
        # the web store takes `from_id`/`into_id`, and iOS takes the survivor
        # from `speaker_id`/`into` and the folded ids from `from` — so a frame
        # carrying only the first pair decoded on iOS as an empty rename.
        _publish_speaker_op({"op": "merge", "from_id": from_id,
                             "into_id": into_id, "segments_moved": moved,
                             "speaker_id": into_id, "into": into_id,
                             "from": [from_id]})
        j(handler, {"ok": True, "segments_moved": moved,
                    "speaker": live_store.get_speaker(into_id)})
        return True
    if path == "/api/live/delete":
        return _live_delete(handler, body)
    if path == "/api/live/factcheck":
        return _live_watcher_call(handler, body, "run_fact_check")
    if path == "/api/live/translate":
        return _live_watcher_call(handler, body, "run_translate")
    if path == "/api/live/translation":
        return _live_store_translation(handler, body)
    if path == "/api/live/config":
        # POST is accepted alongside PUT: several shipped clients cannot send a
        # PUT, and a settings write must not depend on which verb they have.
        return _live_config_write(handler, body)
    return False


def handle_live_put(handler, parsed, body) -> bool:
    if parsed.path == "/api/live/config":
        return _live_config_write(handler, body if isinstance(body, dict) else {})
    return False


def _live_store_translation(handler, body) -> bool:
    """Keep a translation a DEVICE produced.

    The phone translates on-device because that is the only way it lands in the
    same breath as the words (`LiveTranslator`), and the result has to outlive
    the app: otherwise it is gone when the screen closes and never reaches the
    web or any other device watching the same conversation.

    The server may also translate the same row — whichever finishes first
    writes, and a later answer overwrites it. That is deliberate: both fill the
    same field, and letting the first win would mean a worse translation could
    never be corrected.
    """
    sid = _require_session(handler, body)
    if sid is None:
        return True
    try:
        seq = int((body or {}).get("seq"))
    except (TypeError, ValueError):
        bad(handler, "seq must be an integer")
        return True
    translation = str((body or {}).get("translation") or "").strip()
    if not translation:
        bad(handler, "translation must not be empty")
        return True
    try:
        live_store.set_translation(sid, seq, translation)
    except Exception:
        logger.warning("live: could not store a device translation for %s#%s",
                       sid[:8] or "?", seq, exc_info=True)
        bad(handler, "could not store that translation", 500)
        return True
    # Every other viewer of this conversation sees it too.
    _publish_translation_frame(sid, seq, translation, str((body or {}).get("target") or ""))
    j(handler, {"ok": True, "seq": seq})
    return True


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
    # Insights ride WITH the segments rather than behind a second endpoint, so
    # one request rebuilds a transcript complete with its notes: the client
    # already has to walk `segments` in `seq` order, and each note carries the
    # `seq_from`/`seq_to` it covers, so interleaving is a merge rather than a
    # second round-trip that can arrive out of order. Purely additive — the
    # existing keys are untouched, so the web and iOS clients that read
    # `segments` today are unaffected.
    insights = []
    try:
        insights = live_store.insights_for_session(sid, after_seq, limit=limit)
    except Exception:
        # A transcript without its notes still beats a 500.
        logger.warning("live: could not read insights for %s", sid[:8] or "?",
                       exc_info=True)
    j(handler, {"live_session_id": sid, "session": session,
                "segments": segments,
                "insights": [_insight_frame(note) for note in insights],
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
    if accepted and not refused:
        # On a server speech engine's lane, audio spooled while offline still
        # has to be heard (api/live_speech.py); a no-op on the edge lane.
        try:
            from api import live_speech
            live_speech.transcribe_spool(
                sid, device_id,
                [(payload, to_offset_ms(sid, _as_int(ts_ms, 0) or None))
                 for payload, ts_ms in payloads[:accepted]], codec, rate)
        except Exception:
            logger.warning("live: spooled audio was stored but could not be transcribed",
                           exc_info=True)
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


def _fact_retraction(*, live_session_id: str = "",
                     speaker_id: str = "") -> Dict[str, Any]:
    """Retract the memory entries a Live deletion owes, as reportable counts.

    Never raises. The watcher layer is optional by construction (§8) and
    MEMORY.md lives outside this store entirely, so neither being unreachable
    may stop a deletion the user asked for.

    But it is never silent either. A fact extracted by the ambient monitor is
    injected into the system prompt of every future agent, and until this
    existed no Live delete path touched one — so a swallowed retraction here is
    precisely the over-promise this code was added to end. The reason travels
    back in the delete's own response.
    """
    try:
        from api.live_watchers import retract_facts
        return dict(retract_facts(live_session_id=live_session_id,
                                  speaker_id=speaker_id) or {})
    except Exception as exc:
        logger.warning("live: retracting remembered facts failed "
                       "(session %s, voice %s)",
                       live_session_id[:8] or "-", speaker_id[:8] or "-",
                       exc_info=True)
        return {"facts_retraction_failed":
                f"{type(exc).__name__}: {exc}"[:200]}


def _merge_fact_retraction(result: Dict[str, Any],
                           counts: Dict[str, Any]) -> Dict[str, Any]:
    """Fold retraction counts into a delete response, honestly."""
    result.update(counts)
    if counts.get("facts_retraction_failed"):
        # The same posture as the paired-chat failure below: the rows are gone,
        # but part of what the delete promised did not happen, and a bare 200
        # would read as "all of it did".
        result["ok"] = False
    return result


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
    # The last thing this recording left behind. The ambient monitor may have
    # written durable facts derived from it into MEMORY.md, and those outlive
    # every row and file the lines above remove. Session scope matches on the
    # recording, so it also catches the `voices:unknown` entries no
    # speaker-scoped retraction can reach.
    return _merge_fact_retraction(
        result, _fact_retraction(live_session_id=live_session_id))


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
        # Retract FIRST. `_speaker_session_ids` reads the very `live_segment`
        # rows `forget_speaker` is about to delete, and they are the only record
        # of which sessions this voice was heard in — afterwards a
        # `voices:unknown` fact could not even be counted as unattributable.
        # Retraction cannot fail the forget (see _fact_retraction), and erring
        # this way over-retracts at worst, which is the safe direction for a
        # privacy deletion.
        facts = _fact_retraction(speaker_id=target)
        j(handler, _merge_fact_retraction(
            dict(live_store.forget_speaker(target)), facts))
        return True
    if kind == "speaker_audio":
        # No retraction here, on purpose: this action deletes RECORDINGS, not
        # the record of what was said. It leaves the transcript standing ("the
        # words are still true once the recording is gone"), so taking a
        # derived memory entry with it would delete more than was asked for.
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
        # Each session retracts its own facts inside _delete_one_session; the
        # day answer is the sum, so "delete this day" reports one honest total
        # instead of burying a per-session failure in a 200.
        facts = {"facts_retracted": 0, "facts_retraction_staged": 0,
                 "facts_unattributable": 0}
        notes = []
        for sid in sessions:
            one = _delete_one_session(sid)
            freed += int(one.get("freed_bytes") or 0)
            if one.get("chat_deleted"):
                chats_deleted += 1
            if one.get("warning"):
                failures.append(one["warning"])
            for key in facts:
                facts[key] += int(one.get(key) or 0)
            if one.get("facts_retraction_failed"):
                failures.append(one["facts_retraction_failed"])
            if one.get("facts_note"):
                notes.append(one["facts_note"])
        out = {"day": target, "sessions_deleted": len(sessions),
               "freed_bytes": freed, "chats_deleted": chats_deleted}
        out.update(facts)
        if notes:
            # Deduplicated: every session on a staged-writes profile produces
            # the same sentence, and N copies of it is noise, not detail.
            out["facts_note"] = "; ".join(dict.fromkeys(notes))
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
    # A conversation-level fact-check has no single seq: the user checks the
    # recent stretch, not one line. Rejecting seq<=0 made that unreachable.
    if seq <= 0 and func_name != "run_fact_check":
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

    # Translations are not held to the two-at-a-time fact-check ceiling. The
    # phone asks for one automatically for every line in a language it has no
    # pack for, so fast talk in such a language sent three at once, the third
    # was refused, and that line was never translated. They go to the watcher
    # pool's bounded queue instead (2 workers, 32 waiting) and are refused only
    # when THAT is full — the client retries those.
    counted = func_name != "run_translate"
    if counted:
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
            if counted:
                with _watcher_inflight_lock:
                    _watcher_inflight -= 1

    submitted = False
    submit = getattr(live_watchers, "_submit", None)
    if callable(submit):
        submitted = bool(submit(_job))
    if callable(submit) and not submitted and not counted:
        # The translation queue is full: busy, not broken, and bounded — a
        # thread of its own here would make the queue's bound meaningless.
        j(handler, {"ok": False, "error": "translations are queued up; "
                                          "try again in a moment"},
          status=429)
        return True
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
        if counted:
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
