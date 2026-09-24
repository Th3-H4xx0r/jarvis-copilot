"""Soniox real-time speech-to-text (https://soniox.com/docs/stt/rt/real-time-transcription).

One WebSocket per stream: a JSON config first (the key rides only in it), then
binary audio, then an empty frame to finish; responses carry tokens until one
says `finished`. A writer thread sends, a reader thread receives, so `feed()`
never blocks the caller (a voice socket or a Live socket receive loop).

The key is never logged: errors are scrubbed of it, and the websockets logger
is held at WARNING by `jarvis_speech/__init__`.
"""
from __future__ import annotations

import json
import logging
import queue
import shutil
import subprocess
import threading
import time
from pathlib import Path
from typing import List, Optional

from jarvis_speech import config, keys, usage
from jarvis_speech.assemble import TokenAssembler
from jarvis_speech.clock import ClockMap
from jarvis_speech.registry import register_engine
from jarvis_speech.types import Segment

logger = logging.getLogger(__name__)

_URL = "wss://stt-rt.soniox.com/transcribe-websocket"
_CONNECT_TIMEOUT_S = 5
_KEEPALIVE_S = 10          # Soniox closes a stream that hears nothing for 20 s
# Audio sent and not a word back for this long: the connection is dead. Soniox
# answers about every second while it works, silence included (measured 2026-09-24:
# at most 1.1 s apart through a 60 s backlog), so a backlog never trips this.
_STALL_S = 30
_FILE_CHUNK = 32 * 1024
_SURFACE_OF = {"voice": "voice", "live": "live", "file": "upload"}
# Containers Soniox recognises with audio_format "auto"; anything else is decoded first.
_AUTO_SUFFIXES = {".aac", ".aiff", ".aif", ".amr", ".asf", ".flac", ".mp3", ".ogg", ".oga",
                  ".opus", ".wav", ".webm"}

# stt/concepts/supported-languages (2026-09-23): transcription + translation for all.
LANGUAGES = [{"code": code, "name": name} for code, name in (
    ("af", "Afrikaans"), ("sq", "Albanian"), ("ar", "Arabic"), ("az", "Azerbaijani"),
    ("eu", "Basque"), ("be", "Belarusian"), ("bn", "Bengali"), ("bs", "Bosnian"),
    ("bg", "Bulgarian"), ("ca", "Catalan"), ("zh", "Chinese"), ("hr", "Croatian"),
    ("cs", "Czech"), ("da", "Danish"), ("nl", "Dutch"), ("en", "English"), ("et", "Estonian"),
    ("fi", "Finnish"), ("fr", "French"), ("gl", "Galician"), ("de", "German"), ("el", "Greek"),
    ("gu", "Gujarati"), ("he", "Hebrew"), ("hi", "Hindi"), ("hu", "Hungarian"),
    ("id", "Indonesian"), ("it", "Italian"), ("ja", "Japanese"), ("kn", "Kannada"),
    ("kk", "Kazakh"), ("ko", "Korean"), ("lv", "Latvian"), ("lt", "Lithuanian"),
    ("mk", "Macedonian"), ("ms", "Malay"), ("ml", "Malayalam"), ("mr", "Marathi"),
    ("no", "Norwegian"), ("fa", "Persian"), ("pl", "Polish"), ("pt", "Portuguese"),
    ("pa", "Punjabi"), ("ro", "Romanian"), ("ru", "Russian"), ("sr", "Serbian"),
    ("sk", "Slovak"), ("sl", "Slovenian"), ("es", "Spanish"), ("sw", "Swahili"),
    ("sv", "Swedish"), ("tl", "Tagalog"), ("ta", "Tamil"), ("te", "Telugu"), ("th", "Thai"),
    ("tr", "Turkish"), ("uk", "Ukrainian"), ("ur", "Urdu"), ("vi", "Vietnamese"), ("cy", "Welsh"),
)]


def _scrub(text: str, key: str) -> str:
    return text.replace(key, "••••") if key else text


class _WebSocket:
    """The three calls a stream needs, over websockets' sync client."""

    def __init__(self, ws) -> None:
        self._ws = ws

    def send(self, data) -> None:
        self._ws.send(data)

    def recv(self, timeout: Optional[float] = None):
        from websockets.exceptions import ConnectionClosed
        try:
            return self._ws.recv(timeout=timeout)
        except ConnectionClosed:
            raise EOFError

    def close(self) -> None:
        try:
            self._ws.close()
        except Exception:
            pass


class _Collect:
    """Keeps every finished line for `finish()`; a sink that raises cannot kill the stream."""

    def __init__(self, sink) -> None:
        self._sink = sink
        self.segments: List[Segment] = []

    def _call(self, name: str, *args) -> None:
        method = getattr(self._sink, name, None)
        if method is None:
            return
        try:
            method(*args)
        except Exception:
            logger.warning("speech: soniox sink %s failed", name, exc_info=True)

    def on_partial(self, *args) -> None:
        self._call("on_partial", *args)

    def on_segment(self, segment: Segment) -> None:
        self.segments.append(segment)
        self._call("on_segment", segment)

    def on_translation(self, *args) -> None:
        self._call("on_translation", *args)

    def on_error(self, message: str) -> None:
        self._call("on_error", message)


_CONTEXT_TEXT_MAX = 600
_VOICE_CONTEXT = (
    {"key": "domain", "value": "Someone talking to their AI voice assistant, Jarvis, often from across a room"},
    {"key": "topics", "value": "emails, messages, reminders, timers, alarms, weather, the time, music, "
                               "lights, questions, jokes, poems, stories"},
)


class SonioxStream:
    def __init__(self, connect, sink, *, rate: int, translate_to: str, purpose: str,
                 idle_close_s: float, audio_format: str = "pcm_s16le", key: str = "",
                 context_text: str = "") -> None:
        self._connect = connect
        self._context_text = (context_text or "").strip()[-_CONTEXT_TEXT_MAX:]
        self._given_key = key  # a key being tried before it is saved (the Test button)
        self._collect = _Collect(sink)
        self._rate = max(1, int(rate or 16000))
        self._translate_to = translate_to or ""
        self._purpose = purpose
        self._idle_close_s = float(idle_close_s or 0)
        self._audio_format = audio_format
        self._timed = audio_format == "pcm_s16le"
        self._clock = ClockMap()
        self._assembler = TokenAssembler(self._collect, to_session=self._clock.to_session)
        # Unbounded on purpose: a file, a clip or an offline spool is fed faster than
        # real time and is already in memory; dropping any of it would return a
        # transcript with a hole in it and call it a success.
        self._queue: "queue.Queue" = queue.Queue()
        self._lock = threading.Lock()
        self._ending = False
        self._finish = threading.Event()
        self._done = threading.Event()
        self._ws = None
        self._key = ""
        self._opened_at: Optional[float] = None
        self._last_feed = time.monotonic()
        # When audio first went out after Soniox last said anything (None: all answered).
        self._unanswered_since: Optional[float] = None
        self.error = ""
        # The socket closed before Soniox said `finished`: the words so far are
        # kept, but they may not be all of them. Batch callers treat that as a
        # failure (a clip or a file has a complete answer to wait for).
        self.cut_off = False
        threading.Thread(target=self._write_loop, name=f"soniox-{purpose}-send", daemon=True).start()

    # ── the caller's side ──

    @property
    def done(self) -> bool:
        return self._done.is_set()

    def feed(self, pcm16: bytes, ts_ms: Optional[int] = None) -> bool:
        """Queue audio; False once the stream is ending (the caller opens a new one)."""
        with self._lock:
            if self._ending or self._done.is_set():
                return False
            self._last_feed = time.monotonic()
            self._queue.put_nowait((bytes(pcm16), ts_ms))
        return True

    def finish(self, timeout: float = 5.0) -> List[Segment]:
        with self._lock:
            self._ending = True
        self._finish.set()
        if not self._done.wait(timeout):
            self._fail("timed out waiting for Soniox")
            self._shutdown()
        return list(self._collect.segments)

    def close(self) -> None:
        with self._lock:
            self._ending = True
        self._done.set()
        self._shutdown()

    # ── threads ──

    def _write_loop(self) -> None:
        try:
            self._key = self._given_key or keys.soniox_key()
            if not self._key:
                raise RuntimeError("no SONIOX_API_KEY")
            self._ws = self._connect()
            if self._done.is_set():
                # Closed while the socket was opening: nobody will close it later.
                self._shutdown()
                return
            message = self._config_message()
            message["api_key"] = self._key
            self._ws.send(json.dumps(message))
            del message
            self._opened_at = time.monotonic()
            threading.Thread(target=self._read_loop, name=f"soniox-{self._purpose}-recv",
                             daemon=True).start()
            last_sent = time.monotonic()
            while not self._done.is_set():
                try:
                    pcm, ts_ms = self._queue.get(timeout=0.25)
                except queue.Empty:
                    pcm = None
                if pcm is not None:
                    self._send_audio(pcm, ts_ms)
                    last_sent = time.monotonic()
                    continue
                now = time.monotonic()
                idle = self._idle_close_s and now - self._last_feed >= self._idle_close_s
                if self._finish.is_set() or idle:
                    # An idle close is a finish too: a close without `finished`
                    # after it is the end of the stream, not a failure.
                    self._finish.set()
                    with self._lock:
                        self._ending = True
                    while True:  # anything queued before the stream started ending
                        try:
                            pcm, ts_ms = self._queue.get_nowait()
                        except queue.Empty:
                            break
                        self._send_audio(pcm, ts_ms)
                    # An empty TEXT frame ends the audio. An empty binary frame is
                    # zero bytes of audio: Soniox keeps waiting, and every stream
                    # ended in "timed out waiting for Soniox".
                    self._ws.send("")
                    return
                if now - last_sent >= _KEEPALIVE_S:
                    self._ws.send(json.dumps({"type": "keepalive"}))
                    last_sent = now
        except Exception as exc:
            # A send racing the reader's close after `finished` is not a failure.
            if not self._done.is_set():
                self._fail(f"{type(exc).__name__}: {exc}")
                self._shutdown()

    def _send_audio(self, pcm: bytes, ts_ms: Optional[int]) -> None:
        if self._timed:
            n_ms = len(pcm) / 2 * 1000 / self._rate  # exact: rounding drifts over hours
            silence_ms = self._clock.place(n_ms, ts_ms)
            if silence_ms:
                self._ws.send(b"\x00\x00" * (silence_ms * self._rate // 1000))
        self._ws.send(pcm)
        if self._unanswered_since is None:
            self._unanswered_since = time.monotonic()

    def _read_loop(self) -> None:
        try:
            while not self._done.is_set():
                try:
                    raw = self._ws.recv(timeout=1.0)
                except TimeoutError:
                    since = self._unanswered_since
                    if since is not None and time.monotonic() - since > _STALL_S:
                        self._fail("Soniox stopped answering")
                        break
                    continue
                except EOFError:
                    if not self._done.is_set() and not self._finish.is_set():
                        self._fail("Soniox closed the stream")
                    else:
                        self._assembler.flush()
                        self.cut_off = True
                    break
                self._unanswered_since = None
                response = json.loads(raw)
                if response.get("error_code") or response.get("error_type"):
                    self._assembler.consume(response)
                    self._fail(f"{response.get('error_type') or 'error'}: "
                               f"{response.get('error_message') or ''}", notify=False)
                    break
                self._assembler.consume(response)
                if response.get("finished"):
                    self._assembler.flush()
                    break
        except Exception as exc:
            self._fail(f"{type(exc).__name__}: {exc}")
        finally:
            if self._opened_at is not None:
                usage.add(_SURFACE_OF.get(self._purpose, self._purpose),
                          time.monotonic() - self._opened_at)
                self._opened_at = None
            self._done.set()
            self._shutdown()

    def _fail(self, message: str, notify: bool = True) -> None:
        if self.error:
            return
        self.error = _scrub(message.strip(), self._key or keys.soniox_key())
        logger.warning("speech: soniox %s stream failed: %s", self._purpose, self.error)
        if notify:
            self._collect.on_error(self.error)
        self._done.set()

    def _shutdown(self) -> None:
        ws, self._ws = self._ws, None
        if ws is not None:
            ws.close()

    def _config_message(self) -> dict:
        son = config.load()["soniox"]
        live = self._purpose == "live"
        # Voice too: Soniox hearing the end of an utterance ends the turn sooner
        # than the device's level-based silence wait.
        ends = live or self._purpose == "voice"
        message = {"model": son["model"], "audio_format": self._audio_format,
                   "enable_language_identification": bool(son["language_id"]),
                   "enable_speaker_diarization": bool(son["speaker_labels"]) if live else False,
                   "enable_endpoint_detection": ends,
                   "client_reference_id": f"jarvis-{self._purpose}"}
        if self._audio_format != "auto":
            message["sample_rate"] = self._rate
            message["num_channels"] = 1
        # A Voice turn with nothing to lean on drifted into other languages on
        # short, unclear audio; English is only a hint, other languages still pass.
        hints = list(son["language_hints"]) or (["en"] if self._purpose == "voice" else [])
        if hints:
            message["language_hints"] = hints
        if son["custom_words"]:
            message["context"] = {"terms": list(son["custom_words"])}
        if self._purpose == "voice":
            # What it is listening to, and what Jarvis just said (often what the user
            # is answering). On the Pod's far-field clips a neutral context like this
            # turned "Your permission means you know, who they call" into "Jarvis, can
            # you send me an email for the call?".
            context = {"general": list(_VOICE_CONTEXT),
                       "terms": ["Jarvis"] + [w for w in son["custom_words"] if w != "Jarvis"]}
            if self._context_text:
                context["text"] = self._context_text
            message["context"] = context
        if ends:
            message["endpoint_latency_adjustment_level"] = son["endpoint_latency_level"]
            message["endpoint_sensitivity"] = son["endpoint_sensitivity"]
            message["max_endpoint_delay_ms"] = son["max_endpoint_delay_ms"]
        if live:
            if self._translate_to:
                message["translation"] = {"type": "one_way", "target_language": self._translate_to}
        return message


class _Quiet:
    def on_partial(self, *a): pass
    def on_segment(self, segment): pass
    def on_translation(self, *a): pass
    def on_error(self, message): pass


class SonioxEngine:
    name = "soniox"
    label = "Soniox"
    streams = True

    def available(self):
        if not keys.soniox_key():
            return False, "no SONIOX_API_KEY"
        try:
            import websockets.sync.client  # noqa: F401
        except Exception:
            return False, "websockets not installed"
        return True, ""

    def _connect(self):
        from websockets.sync.client import connect
        # No library ping: Soniox reads audio at about real time, so a ping sent
        # behind a backlog (a file, a clip, a Live catch-up) waits behind it and the
        # library closed healthy streams mid-way. `_STALL_S` watches the link instead.
        return _WebSocket(connect(_URL, open_timeout=_CONNECT_TIMEOUT_S, close_timeout=2,
                                  max_size=2 ** 22, ping_interval=None))

    def open_stream(self, sink, *, rate: int, translate_to: str = "", purpose: str = "live",
                    idle_close_s: float = 0, context_text: str = "") -> SonioxStream:
        return SonioxStream(lambda: self._connect(), sink, rate=rate, translate_to=translate_to,
                            purpose=purpose, idle_close_s=idle_close_s, context_text=context_text)

    def transcribe_file(self, path: str) -> dict:
        suffix = Path(path).suffix.lower()
        try:
            if suffix in _AUTO_SUFFIXES:
                data, audio_format, seconds = Path(path).read_bytes(), "auto", None
            else:
                data = _decode_to_pcm(path)
                if data is None:
                    return {"success": False, "transcript": "", "error": "unsupported format"}
                audio_format, seconds = "pcm_s16le", len(data) / 32000.0
        except OSError as exc:
            return {"success": False, "transcript": "", "error": type(exc).__name__}
        if seconds is None:
            seconds = len(data) / 4000.0  # ~32 kbit/s compressed; only sizes the wait
        stream = SonioxStream(lambda: self._connect(), _Quiet(), rate=16000, translate_to="",
                              purpose="file", idle_close_s=0, audio_format=audio_format)
        for offset in range(0, len(data), _FILE_CHUNK):
            stream.feed(data[offset:offset + _FILE_CHUNK])
        segments = stream.finish(timeout=max(15.0, seconds + 10.0))
        if stream.error or stream.cut_off:
            return {"success": False, "transcript": "",
                    "error": stream.error or "Soniox stopped before it finished"}
        languages = [s.language for s in segments if s.language]
        return {"success": True, "transcript": " ".join(s.text for s in segments).strip(),
                "provider": "soniox",
                "language": max(set(languages), key=languages.count) if languages else "",
                "translation": ""}

    def check(self, key: str = ""):
        """One tiny session: does the key work? (What the settings Test button runs.)

        `key` tries a key that is not saved yet; without it, the saved key.
        """
        ok, reason = self.available()
        if not ok and not (key and reason == "no SONIOX_API_KEY"):
            return False, reason
        stream = SonioxStream(lambda: self._connect(), _Quiet(), rate=16000, translate_to="",
                              purpose="voice", idle_close_s=0, key=key)
        stream.feed(b"\x00\x00" * 3200)
        stream.finish(timeout=8.0)
        if stream.error:
            return False, stream.error
        return True, "Soniox answered"


def _decode_to_pcm(path: str) -> Optional[bytes]:
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        return None
    try:
        result = subprocess.run([ffmpeg, "-nostdin", "-loglevel", "error", "-i", path,
                                 "-f", "s16le", "-ac", "1", "-ar", "16000", "-"],
                                capture_output=True, timeout=120, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return result.stdout if result.returncode == 0 and result.stdout else None


register_engine("soniox", SonioxEngine)
