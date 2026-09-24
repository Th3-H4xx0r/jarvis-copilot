"""Live on a server speech engine (Soniox): the lane that actually transcribes.

One `EngineLane` per Live connection (one device). It decodes the device's audio
to 16 kHz PCM, opens the engine's stream on the first speech, reopens it after
the engine closes a quiet one (billing stops while nobody talks), and turns what
the engine hears into the same rows, frames and translations the edge lane
produces — so viewers, watchers and memory see no difference except who heard.

Speaker labels from an engine are only stable inside one stream, so each row
carries `<engine>:<lane>-<stream>:<label>` as its local label, and a short line
(< 3 s, too little audio for a voiceprint) takes the speaker already decided for
an earlier line with the same label instead of guessing from its own audio.

Everything here runs on the engine's threads or the socket thread and is wrapped:
a failure is a log line, never a dead socket (design §8: capture is the floor).
"""
from __future__ import annotations

import logging
import threading
import time
import uuid
from collections import OrderedDict
from typing import List, Optional, Tuple

logger = logging.getLogger(__name__)

_RATE = 16000
_PARTIAL_EVERY_S = 0.2
_SHORT_LINE_MS = 3000
_LABEL_MEMORY = 3
_FINISH_S = 2.0
_STORE_TRIES = 3
# The phone re-sends its last ~150 frames after a reconnect; a frame at most this
# far behind the newest one fed is a replay, further behind is an app restart.
_REPLAY_WINDOW = 300
# After an engine fails, how long before Live tries it again: growing, so a bad
# key or an empty balance does not bounce the phone every reconnect.
_BACKOFF_S = (30, 120, 600, 1800)

_state_lock = threading.Lock()
_fed_seq: "OrderedDict[Tuple[str, str], int]" = OrderedDict()
_backoff_until = 0.0
_failures = 0


def _now() -> float:
    return time.monotonic()


def reset_for_tests() -> None:
    global _backoff_until, _failures
    with _state_lock:
        _fed_seq.clear()
        _backoff_until = 0.0
        _failures = 0


def note_failure() -> None:
    global _backoff_until, _failures
    with _state_lock:
        _failures += 1
        _backoff_until = _now() + _BACKOFF_S[min(_failures, len(_BACKOFF_S)) - 1]


def note_success() -> None:
    global _backoff_until, _failures
    with _state_lock:
        _failures = 0
        _backoff_until = 0.0


def engine_blocked() -> bool:
    with _state_lock:
        return _now() < _backoff_until


def _fresh_frame(live_session_id: str, device_id: str, seq: Optional[int]) -> bool:
    """False for a frame an engine already heard (a reconnect replays the last few)."""
    if seq is None:
        return True
    key = (live_session_id, device_id)
    with _state_lock:
        last = _fed_seq.get(key)
        if last is not None and last - _REPLAY_WINDOW <= seq <= last:
            return False
        _fed_seq[key] = seq
        _fed_seq.move_to_end(key)
        while len(_fed_seq) > 256:
            _fed_seq.popitem(last=False)
        return True


def live_engine():
    """The streaming engine Live should use, or None for the edge lane (today).

    Callers also check `engine_blocked()`: an engine that just failed backs off.
    """
    try:
        import jarvis_speech
        engine = jarvis_speech.engine_for("live")
    except Exception:
        logger.debug("live: speech engine lookup failed", exc_info=True)
        return None
    return engine if engine is not None and getattr(engine, "streams", False) else None


def _translate_to() -> str:
    """`live.primary_language` as a bare language code ("en-US" → "en"), or "" for none.

    The setting is a locale on the phone and free text on the web; an engine
    wants the language itself, and a value it cannot read would fail every stream.
    """
    try:
        from api import live_config
        cfg = live_config.load()
        if not cfg.get("translate"):
            return ""
        base = str(cfg.get("primary_language") or "").strip().replace("_", "-").split("-")[0].lower()
        return base if 2 <= len(base) <= 3 and base.isalpha() else ""
    except Exception:
        return ""


def _quiet_close_s() -> float:
    try:
        from jarvis_speech import config
        return float(config.load()["soniox"]["live_quiet_close_s"])
    except Exception:
        return 60.0


class _Decoder:
    """The device's codec → 16 kHz mono PCM. Opus keeps state, so one per lane."""

    def __init__(self) -> None:
        self._opus = None

    def pcm(self, payload: bytes, codec: str, rate: int) -> bytes:
        name = str(codec or "").strip().lower()
        if name.startswith("opus"):
            if self._opus is None:
                from api.voice_opus import OpusDecoder
                self._opus = OpusDecoder(_RATE, 1)
            return self._opus.decode(payload)
        if name in ("", "pcm", "pcm16", "raw", "s16le", "pcm_s16le"):
            if rate and int(rate) != _RATE:
                from api.voice import _resample_pcm16_mono
                return _resample_pcm16_mono(payload, int(rate), _RATE)
            return payload
        return None  # a codec nothing here can decode: stored, but not transcribable


class EngineLane:
    def __init__(self, conn, engine, *, idle_close: bool = True) -> None:
        self._conn = conn
        self._engine = engine
        self._idle_close = idle_close
        self._decoder = _Decoder()
        self._lock = threading.Lock()
        self._stream = None
        self._stream_no = 0
        self._tag = uuid.uuid4().hex[:6]
        self._label_seqs: dict = {}
        self._closed = False
        self._gave_up = False

    @property
    def label(self) -> str:
        return str(getattr(self._engine, "label", "") or getattr(self._engine, "name", ""))

    def feed(self, payload: bytes, ts_ms: Optional[int], codec: str, rate: int,
             seq: Optional[int] = None) -> None:
        if not _fresh_frame(self._conn.live_session_id, self._conn.device_id, seq):
            return
        try:
            pcm = self._decoder.pcm(payload, codec, rate)
        except Exception:
            logger.warning("live: could not decode %s audio for the speech engine", codec,
                           exc_info=True)
            self._give_up(f"this device's {codec or 'audio'} could not be decoded")
            return
        if pcm is None:
            self._give_up(f"no way to decode {codec} audio")
            return
        if pcm:
            self.feed_pcm(pcm, ts_ms)

    def _give_up(self, reason: str) -> None:
        """Nothing will be heard on this lane: hand the device back, once."""
        if self._gave_up:
            return
        self._gave_up = True
        note_failure()
        try:
            self._conn.fallback_to_edge(reason)
        except Exception:
            logger.warning("live: speech engine fallback failed", exc_info=True)

    def feed_pcm(self, pcm: bytes, ts_ms: Optional[int]) -> None:
        with self._lock:
            if self._closed:
                return
            stream = self._stream
            if stream is not None and not stream.done and stream.feed(pcm, ts_ms):
                return
            stream = self._open()
            if stream is not None:
                stream.feed(pcm, ts_ms)
        if stream is None:
            # Outside the lock: the fallback detaches and closes this lane.
            self._give_up("the speech engine could not start")

    def finish(self, timeout: float = _FINISH_S) -> None:
        with self._lock:
            stream, self._stream = self._stream, None
        _finish(stream, timeout)

    def close(self) -> None:
        """The connection is going away: flush in the background so the pump never waits."""
        with self._lock:
            self._closed = True
            stream, self._stream = self._stream, None
        if stream is not None:
            threading.Thread(target=_finish, args=(stream, _FINISH_S),
                             name="live-speech-close", daemon=True).start()

    # ── internals ──

    def _open(self):
        """Caller holds the lock."""
        self._stream_no += 1
        translate_to = _translate_to()
        sink = _LaneSink(self, f"{self._engine.name}:{self._tag}-{self._stream_no}", translate_to)
        try:
            stream = self._engine.open_stream(
                sink, rate=_RATE, translate_to=translate_to, purpose="live",
                idle_close_s=_quiet_close_s() if self._idle_close else 0)
        except Exception:
            logger.warning("live: the speech engine could not open a stream", exc_info=True)
            stream = None
        self._stream = stream
        return stream

    def _speaker_for(self, label: str) -> str:
        from api import live_store
        sid = self._conn.live_session_id
        with self._lock:
            seqs = list(self._label_seqs.get(label, ()))
        for seq in reversed(seqs):
            rows = live_store.segments_after(sid, after_seq=seq - 1, limit=1)
            if rows and int(rows[0].get("seq") or 0) == seq and rows[0].get("speaker_id"):
                return str(rows[0]["speaker_id"])
        return ""

    def _remember(self, label: str, seq: int) -> None:
        with self._lock:
            seqs = self._label_seqs.setdefault(label, [])
            seqs.append(seq)
            del seqs[:-_LABEL_MEMORY]


def _finish(stream, timeout: float) -> None:
    if stream is None:
        return
    try:
        stream.finish(timeout=timeout)
    except Exception:
        logger.warning("live: finishing the speech stream failed", exc_info=True)


class _LaneSink:
    """What one engine stream reports, turned into Live rows and frames."""

    def __init__(self, lane: EngineLane, prefix: str, translate_to: str) -> None:
        self._lane = lane
        self._prefix = prefix
        self._translate_to = translate_to
        self._seq_by_key: dict = {}
        self._last_partial = 0.0

    @property
    def _sid(self) -> str:
        return self._lane._conn.live_session_id

    @property
    def _device(self) -> str:
        return self._lane._conn.device_id

    def on_partial(self, text: str, start_ms: int, speaker: str, language: str) -> None:
        now = time.monotonic()
        if now - self._last_partial < _PARTIAL_EVERY_S:
            return
        self._last_partial = now
        try:
            from api import live_ws
            live_ws.publish(self._sid, "partial", {
                "live_session_id": self._sid, "device_id": self._device, "text": text,
                "start_ms": int(start_ms), "speaker": speaker, "lang": language})
        except Exception:
            logger.debug("live: could not publish words in progress", exc_info=True)

    def on_segment(self, segment) -> None:
        from api import live_ws
        label = f"{self._prefix}:{segment.speaker}" if segment.speaker else ""
        inherited = ""
        if label and segment.end_ms - segment.start_ms < _SHORT_LINE_MS:
            try:
                inherited = self._lane._speaker_for(label)
            except Exception:
                logger.debug("live: speaker lookup failed", exc_info=True)
        # The words exist only in the engine's reply: a busy store ("database is
        # locked" is expected here) gets a few tries before the line is lost.
        row = None
        for attempt in range(_STORE_TRIES):
            try:
                row = live_ws.append_and_publish(
                    self._sid, ts_start_ms=segment.start_ms,
                    ts_end_ms=max(segment.end_ms, segment.start_ms + 1), text=segment.text,
                    lang=segment.language, local_label=label, speaker_id=inherited,
                    device_id=self._device, transcribed_by=self._lane._engine.name,
                    device_translates=bool(self._translate_to))
                break
            except Exception:
                if attempt == _STORE_TRIES - 1:
                    logger.warning("live: could not store a line the speech engine heard on %s",
                                   self._sid[:8] or "?", exc_info=True)
                    unavailable = getattr(self._lane._conn, "_store_unavailable", None)
                    if unavailable is not None:
                        unavailable("a line the speech engine heard")
                    return
                time.sleep(0.2 * (attempt + 1))
        try:
            seq = int(row.get("seq") or 0)
            note_success()
            self._seq_by_key[segment.key] = seq
            if label:
                self._lane._remember(label, seq)
            if segment.translation:
                live_ws.publish_translation(self._sid, seq, segment.translation, self._translate_to)
        except Exception:
            logger.warning("live: could not store a line the speech engine heard on %s",
                           self._sid[:8] or "?", exc_info=True)

    def on_translation(self, key: int, text: str) -> None:
        seq = self._seq_by_key.get(key)
        if not seq or not text:
            return
        try:
            from api import live_ws
            live_ws.publish_translation(self._sid, seq, text, self._translate_to)
        except Exception:
            logger.warning("live: could not store a translation on %s", self._sid[:8] or "?",
                           exc_info=True)

    def on_error(self, message: str) -> None:
        conn = self._lane._conn
        if getattr(conn, "engine_lane", self._lane) is not self._lane:
            # A lane already detached (the recording ended, the socket dropped):
            # its last stream running late is not the engine failing now.
            logger.info("live: a finished speech stream reported: %s", message)
            return
        note_failure()
        try:
            conn.fallback_to_edge(message)
        except Exception:
            logger.warning("live: speech engine fallback failed", exc_info=True)


class _SpoolConn:
    """Stands in for a socket when spooled audio arrives with no live connection."""

    def __init__(self, live_session_id: str, device_id: str) -> None:
        self.live_session_id = live_session_id
        self.device_id = device_id

    def fallback_to_edge(self, reason: str) -> None:
        logger.warning("live: speech engine failed on spooled audio for %s (%s)",
                       self.live_session_id[:8] or "?", reason)


def transcribe_spool(live_session_id: str, device_id: str,
                     chunks: List[Tuple[bytes, Optional[int]]], codec: str,
                     rate: int) -> Optional[threading.Thread]:
    """Audio the phone held while offline, heard at its own timestamps, off-thread."""
    engine = None if engine_blocked() else live_engine()
    if engine is None or not chunks:
        return None

    def run() -> None:
        lane = EngineLane(_SpoolConn(live_session_id, device_id), engine, idle_close=False)
        seconds = 0.0
        for payload, ts_ms in chunks:
            try:
                pcm = lane._decoder.pcm(payload, codec, rate)
            except Exception:
                continue
            if pcm:
                seconds += len(pcm) / (2.0 * _RATE)
                lane.feed_pcm(pcm, ts_ms)
        lane.finish(timeout=seconds + 10.0)

    thread = threading.Thread(target=run, name="live-speech-spool", daemon=True)
    thread.start()
    return thread
