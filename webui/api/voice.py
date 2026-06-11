"""
Voice tab API — STT, TTS, Quality-mode one-shot, Realtime/S2S WebSocket bridge.

Endpoints:
- GET  /api/voice/status         — feature availability + active providers
- GET  /api/voice/voices         — list of TTS voices for the active provider
- POST /api/voice/synthesize     — text → MP3/Opus audio bytes (raw response)
- POST /api/voice/quality-turn   — base64 PCM in → {transcript, reply, audio_base64}
- GET  /api/voice/s2s/ws         — WebSocket bidirectional bridge mode

WS protocol (mirrors JarvisClaw's s2s.proto in spirit, JSON+binary over WS):
  Client → Server:
    Binary frame:  16-bit PCM @ 16 kHz mono (mic frames)
    Text  frame:   {"type":"begin_turn","sample_rate":16000}
                   {"type":"end_turn"}
                   {"type":"interrupt"}
  Server → Client:
    Text frame:    {"type":"ready","mode":"bridge"}
                   {"type":"transcript","text":"...","is_final":true}
                   {"type":"assistant_text","text":"..."}
                   {"type":"audio_meta","format":"pcm_s16le"|"mp3","sample_rate":24000}
                   {"type":"audio_end"}
                   {"type":"end_turn","reason":"..."}
    Binary frame:  16-bit PCM @ 24 kHz mono (or MP3 fallback)

Bridge mode (the only mode shipped today — no Moshi/Mini-Omni-2 sidecar):
    end_turn → STT (tools.transcription_tools)
             → LLM (one-shot via OpenAI-compatible client)
             → TTS (tools.tts_tool)
             → ffmpeg MP3 → 24 kHz PCM (if available)
             → stream PCM frames back to the client.
"""
import base64
import json
import os
import re
import sys
import tempfile
import threading
import time
import traceback
from pathlib import Path
from typing import Optional

from api.helpers import j


# ---------------------------------------------------------------------------
# JarvisCopilot core integration — voice.py lives at webui/api/voice.py; JarvisCopilot core
# lives one directory above webui/. We add it to sys.path lazily so importing
# this module doesn't pay the cost on every webui import.
# ---------------------------------------------------------------------------

def _hermes_root() -> Path:
    # webui/api/voice.py → webui/ → JarvisCopilot/ (JarvisCopilot root)
    return Path(__file__).resolve().parent.parent.parent


def _ensure_hermes_on_path() -> None:
    root = str(_hermes_root())
    if root not in sys.path:
        sys.path.insert(0, root)


def _try_import_stt():
    _ensure_hermes_on_path()
    try:
        from tools.transcription_tools import transcribe_audio  # type: ignore
        return transcribe_audio
    except Exception:
        return None


def _try_import_tts():
    _ensure_hermes_on_path()
    try:
        from tools.tts_tool import (  # type: ignore
            text_to_speech_tool,
            _load_tts_config,
            _get_provider,
        )
        return text_to_speech_tool, _load_tts_config, _get_provider
    except Exception:
        return None, None, None


# ---------------------------------------------------------------------------
# HTTP route dispatch
# ---------------------------------------------------------------------------

def handle_voice_get(handler, parsed) -> bool:
    if parsed.path == "/api/voice/status":
        return _voice_status(handler)
    if parsed.path == "/api/voice/session":
        return _voice_session(handler)
    if parsed.path == "/api/voice/voices":
        return _voice_voices(handler)
    if parsed.path == "/api/voice/engines":
        return _voice_engines(handler)
    return False


def handle_voice_post(handler, parsed, body) -> bool:
    if parsed.path == "/api/voice/synthesize":
        return _voice_synthesize(handler, body)
    if parsed.path == "/api/voice/quality-turn":
        return _voice_quality_turn(handler, body)
    if parsed.path == "/api/voice/personality-tts":
        return _voice_personality_tts(handler, body)
    if parsed.path == "/api/voice/engine":
        return _voice_set_engine(handler, body)
    if parsed.path == "/api/voice/provider-config":
        return _voice_provider_config(handler, body)
    return False


# ---------------------------------------------------------------------------
# /api/voice/status
# ---------------------------------------------------------------------------

def _voice_status(handler) -> bool:
    stt = _try_import_stt()
    tts_fn, load_cfg, get_provider = _try_import_tts()
    provider = ""
    if load_cfg and get_provider:
        try:
            provider = get_provider(load_cfg())
        except Exception:
            provider = ""
    import shutil as _shutil
    j(handler, {
        "stt_ok": bool(stt),
        "tts_ok": bool(tts_fn),
        "realtime_ok": bool(stt and tts_fn),
        "tts_provider": provider,
        "ffmpeg_ok": bool(_shutil.which("ffmpeg")),
    })
    return True


# ---------------------------------------------------------------------------
# /api/voice/session — the dedicated, persistent "Voice" chat
# ---------------------------------------------------------------------------

# Sessions created for voice carry this source_tag so we can find the one
# dedicated voice chat again (instead of hijacking the user's most-recent
# chat, which can be a coding/CLI/Telegram channel wired to another provider).
_VOICE_SOURCE_TAG = "voice"

# Serializes the scan-then-create in get_or_create_voice_session so two
# simultaneous GET /api/voice/session calls (two devices, a double-tap) can't
# both miss the scan and each create a duplicate "Voice" session.
_VOICE_SESSION_LOCK = threading.Lock()


def get_or_create_voice_session():
    """Return the persistent dedicated 'Voice' chat session, creating it once.

    Voice turns route here instead of whatever chat happens to be most recent —
    a coding/CLI/Telegram session can be wired to a provider+model combination
    (e.g. Codex with an empty model) that voice can't run, which is what made
    mobile voice silently fail. The session is marked source_tag='voice' and
    created with the user's resolved default model/provider. Returns the
    Session object; raises _VoiceAgentError if the store is unavailable.
    """
    _ensure_hermes_on_path()
    try:
        from api.models import (  # type: ignore
            Session, get_session, all_sessions, get_last_workspace,
            LOCK, SESSIONS, SESSIONS_MAX,
        )
        from api.routes import _resolve_compatible_session_model_state  # type: ignore
    except Exception as exc:
        raise _VoiceAgentError(f"webui session store unavailable: {exc}", status=500)
    import uuid as _uuid

    def _scan_existing():
        # Find the one dedicated voice chat (source_tag=="voice", not archived).
        try:
            for row in all_sessions():
                if isinstance(row, dict):
                    tag = row.get("source_tag")
                    archived = row.get("archived")
                    sid = row.get("session_id")
                else:
                    tag = getattr(row, "source_tag", None)
                    archived = getattr(row, "archived", False)
                    sid = getattr(row, "session_id", None)
                if tag == _VOICE_SOURCE_TAG and not archived and sid:
                    try:
                        return get_session(sid)
                    except KeyError:
                        continue
        except Exception:
            pass
        return None

    # Hold the lock across scan AND create so concurrent callers don't each
    # create a duplicate "Voice" session (a request that loses the race finds
    # the winner's session on its scan).
    with _VOICE_SESSION_LOCK:
        existing = _scan_existing()
        if existing is not None:
            return existing

        # Create a fresh dedicated voice session pinned to the resolved default
        # model/provider (keeps Codex; never forces Claude).
        try:
            eff_model, eff_provider, _ = _resolve_compatible_session_model_state(None, None)
        except Exception:
            eff_model, eff_provider = "", None
        try:
            ws = get_last_workspace() or str(Path.home())
        except Exception:
            ws = str(Path.home())
        s = Session(
            session_id=_uuid.uuid4().hex[:12],
            title="Voice",
            workspace=ws,
            model=eff_model or None,
            model_provider=eff_provider,
            source_tag=_VOICE_SOURCE_TAG,
        )
        with LOCK:
            SESSIONS[s.session_id] = s
            SESSIONS.move_to_end(s.session_id)
            while len(SESSIONS) > SESSIONS_MAX:
                SESSIONS.popitem(last=False)
        try:
            s.save()  # persist so we can find it again across restarts
        except Exception:
            pass
        return s


def _voice_session(handler) -> bool:
    # NOTE: j() returns None, so we must `return True` explicitly (like the
    # other voice GET handlers) — the dispatcher uses the truthy return to mark
    # the request as claimed.
    try:
        s = get_or_create_voice_session()
    except _VoiceAgentError as exc:
        j(handler, {"error": str(exc)}, status=exc.status)
        return True
    except Exception as exc:
        j(handler, {"error": str(exc)}, status=500)
        return True
    j(handler, {
        "session_id": s.session_id,
        "title": getattr(s, "title", "Voice"),
    })
    return True


# ---------------------------------------------------------------------------
# /api/voice/voices
# ---------------------------------------------------------------------------

# A small curated set of voice IDs per built-in provider. Full enumeration would
# require live API calls; this is enough to populate the picker for the common
# providers. Users can override the voice via tts.<provider>.voice in config.
_BUILTIN_VOICES = {
    # The active provider in ~/.jarviscopilot/config.yaml is read via
    # tools.tts_tool._get_provider — its canonical key for Edge TTS is "edge"
    # (not "edge-tts"). Other JarvisCopilot built-ins keep their short keys.
    "edge": [
        {"id": "en-US-AriaNeural",     "name": "Aria (en-US, female)"},
        {"id": "en-US-GuyNeural",      "name": "Guy (en-US, male)"},
        {"id": "en-US-JennyNeural",    "name": "Jenny (en-US, female)"},
        {"id": "en-US-AndrewNeural",   "name": "Andrew (en-US, male)"},
        {"id": "en-GB-RyanNeural",     "name": "Ryan (en-GB, male)"},
        {"id": "en-GB-SoniaNeural",    "name": "Sonia (en-GB, female)"},
    ],
    "openai": [
        {"id": "alloy",   "name": "Alloy"},
        {"id": "echo",    "name": "Echo"},
        {"id": "fable",   "name": "Fable"},
        {"id": "onyx",    "name": "Onyx"},
        {"id": "nova",    "name": "Nova"},
        {"id": "shimmer", "name": "Shimmer"},
    ],
    "elevenlabs": [
        {"id": "21m00Tcm4TlvDq8ikWAM", "name": "Rachel"},
        {"id": "AZnzlk1XvdvUeBnXmlld", "name": "Domi"},
        {"id": "EXAVITQu4vr4xnSDxMaL", "name": "Bella"},
        {"id": "TxGEqnHWrfWFTfGW9XjX", "name": "Josh"},
    ],
    "gemini": [
        {"id": "Aoede",     "name": "Aoede"},
        {"id": "Puck",      "name": "Puck"},
        {"id": "Charon",    "name": "Charon"},
        {"id": "Kore",      "name": "Kore"},
        {"id": "Fenrir",    "name": "Fenrir"},
    ],
    # Local neural TTS via piper-tts. Voice IDs here are short friendly names
    # that map to absolute ONNX paths under ~/.jarviscopilot/cache/piper-voices/
    # (handled in _voice_voices when surfacing the current selection).
    "piper": [
        {"id": "jarvis-high", "name": "JARVIS (en-GB, neural)"},
    ],
}


def _voice_voices(handler) -> bool:
    tts_fn, load_cfg, get_provider = _try_import_tts()
    provider = ""
    voices: list = []
    selected = ""
    if load_cfg and get_provider:
        try:
            cfg = load_cfg()
            provider = get_provider(cfg) or ""
            voices = list(_BUILTIN_VOICES.get(provider, []))
            # Surface the currently-configured voice so the dropdown can
            # pre-select it. For Piper the config stores an absolute ONNX
            # path; we collapse it back to the short ID the dropdown shows.
            section = cfg.get(provider) if isinstance(cfg, dict) else None
            cfg_voice = ""
            if isinstance(section, dict):
                cfg_voice = str(section.get("voice") or "").strip()
            if provider == "piper" and cfg_voice:
                stem = Path(cfg_voice).stem  # e.g. jarvis-high
                if any(v["id"] == stem for v in voices):
                    selected = stem
                elif voices:
                    # Path points at a voice we don't know — surface it as
                    # a custom entry so the dropdown still has something.
                    voices.append({"id": stem, "name": f"{stem} (custom)"})
                    selected = stem
            elif cfg_voice and any(v["id"] == cfg_voice for v in voices):
                selected = cfg_voice
        except Exception:
            pass
    j(handler, {"provider": provider, "voices": voices, "selected": selected})
    return True


# ---------------------------------------------------------------------------
# /api/voice/synthesize — text → audio bytes
# ---------------------------------------------------------------------------

def _voice_synthesize(handler, body) -> bool:
    text = ((body or {}).get("text") or "").strip()
    if not text:
        return j(handler, {"error": "text is required"}, status=400)
    # Fish Audio short-circuit — cloud REST, not a JarvisCopilot built-in.
    cfg = _read_hermes_config()
    tts_section = cfg.get("tts") if isinstance(cfg, dict) else None
    provider = ""
    if isinstance(tts_section, dict):
        provider = str(tts_section.get("provider") or "").strip()
    if provider == "fish-audio":
        try:
            audio = _synthesize_fish_audio(text, tts_cfg=tts_section or {})
        except _FishAudioError as exc:
            return j(handler, {"error": str(exc)}, status=400 if exc.config_issue else 502)
        if not audio:
            return j(handler, {"error": "Fish Audio returned no audio"}, status=502)
        try:
            handler.send_response(200)
            handler.send_header("Content-Type", "audio/wav")
            handler.send_header("Content-Length", str(len(audio)))
            handler.send_header("Cache-Control", "no-store")
            handler.end_headers()
            handler.wfile.write(audio)
        except Exception:
            pass
        return True
    tts_fn, _, _ = _try_import_tts()
    if not tts_fn:
        return j(handler, {"error": "TTS module unavailable"}, status=503)
    fmt = ((body or {}).get("format") or "mp3").lower()
    if fmt not in ("mp3", "wav", "ogg"):
        fmt = "mp3"
    out_path = _make_tempfile_path("webui-tts-", f".{fmt}")
    try:
        result_json = tts_fn(text=text, output_path=out_path)
        try:
            result = json.loads(result_json) if isinstance(result_json, str) else (result_json or {})
        except Exception:
            result = {}
        if not result.get("success"):
            msg = result.get("error") or "TTS failed"
            return j(handler, {"error": str(msg)}, status=500)
        file_path = result.get("file_path") or out_path
        if not Path(file_path).exists():
            return j(handler, {"error": "TTS produced no output"}, status=500)
        data = Path(file_path).read_bytes()
        suffix = Path(file_path).suffix.lstrip(".").lower()
        ctype = {
            "mp3": "audio/mpeg",
            "wav": "audio/wav",
            "ogg": "audio/ogg",
        }.get(suffix, "audio/mpeg")
        try:
            handler.send_response(200)
            handler.send_header("Content-Type", ctype)
            handler.send_header("Content-Length", str(len(data)))
            handler.send_header("Cache-Control", "no-store")
            handler.end_headers()
            handler.wfile.write(data)
        except Exception:
            pass
        return True
    finally:
        _cleanup_tempfile_siblings(out_path)


# ---------------------------------------------------------------------------
# /api/voice/quality-turn — single round-trip mic → reply audio
# ---------------------------------------------------------------------------

def _voice_quality_turn(handler, body) -> bool:
    """Quality-mode voice turn — STREAMS newline-delimited JSON events back
    to the client as the agent produces them, so each segment is spoken on
    arrival instead of after the whole turn finishes.

    Request:  { audio_base64, sample_rate=16000, session_id }

    Response: chunked `application/x-ndjson` stream where each line is one
    event:
        {"type":"transcript","text":"..."}
        {"type":"segment","kind":"text","text":"...","audio_base64":"..."}
        {"type":"segment","kind":"tool","name":"...","status":"started"}
        {"type":"segment","kind":"tool","name":"...","status":"completed"}
        {"type":"error","error":"..."}
        {"type":"done"}

    Each text segment is TTS-encoded inline before being written to the
    stream, so the client doesn't need a second round-trip for audio. Tool
    approvals are auto-granted via tools.approval.enable_session_yolo()
    for the duration of the turn — speaking the request is consent.
    """
    pcm_b64 = ((body or {}).get("audio_base64") or "")
    sr = int((body or {}).get("sample_rate") or 16000)
    session_id = ((body or {}).get("session_id") or "").strip()
    if not pcm_b64:
        return j(handler, {"error": "audio_base64 is required"}, status=400)
    if not session_id:
        return j(handler, {"error": "session_id is required"}, status=400)
    try:
        pcm_bytes = base64.b64decode(pcm_b64)
    except Exception:
        return j(handler, {"error": "invalid base64 audio"}, status=400)
    if len(pcm_bytes) < 1000:
        return j(handler, {"error": "audio too short"}, status=400)
    transcript = _pcm_to_transcript(pcm_bytes, sr)

    # Headers go out BEFORE we touch the agent so the browser sees the
    # streaming response start instantly (and reveals the transcript line
    # the moment STT returns, before the LLM has emitted anything).
    try:
        handler.send_response(200)
        handler.send_header("Content-Type", "application/x-ndjson; charset=utf-8")
        handler.send_header("Cache-Control", "no-store")
        handler.send_header("X-Accel-Buffering", "no")  # disable proxy buffering
        handler.send_header("Connection", "close")
        handler.end_headers()
    except Exception:
        return True

    def _emit(obj: dict) -> bool:
        try:
            line = json.dumps(obj, ensure_ascii=False).encode("utf-8") + b"\n"
            handler.wfile.write(line)
            handler.wfile.flush()
            return True
        except Exception:
            # Client disconnected mid-stream — stop the agent loop. Caught
            # by _is_client_disconnect in server.py at the outer layer too.
            return False

    _emit({"type": "transcript", "text": transcript or ""})
    if not transcript:
        _emit({"type": "done", "reason": "no_speech"})
        return True

    # Voice mode shows/speaks only the acknowledgement and the final answer — no
    # in-between step narration or per-tool activity. The text generator flushes
    # a segment at each tool boundary, so the shape is: ack (before the first
    # tool) → tools → final (after the last tool). We emit the FIRST text segment
    # immediately (the ack), drop tool segments, buffer any middle narration, and
    # emit only the LAST text segment (the final answer) at the end.
    def _emit_text(text: str) -> bool:
        # Split long answers (e.g. a full morning brief) into chunks: one giant
        # TTS call can time out or exceed the provider's input limit and return
        # NO audio (the "Speaking…" but silent bug). The client appends each
        # segment's text and plays its audio sequentially, so chunking keeps the
        # full transcript while making every chunk reliably synthesizable — and
        # speech starts on the first chunk instead of after the whole synth.
        for chunk in _split_for_speech(text):
            audio_b64 = _tts_to_base64(chunk)
            if not _emit({"type": "segment", "kind": "text", "text": chunk, "audio_base64": audio_b64}):
                return False
        return True

    try:
        for seg in _run_agent_turn_via_chat(session_id, transcript):
            if seg.get("kind") == "text":
                text = (seg.get("text") or "").strip()
                if not text:
                    continue
                # Emit/synthesize each sentence-sized segment as it streams, so
                # speech starts immediately and stays low-latency. The voice
                # directive keeps the model to an ack + the answer (no step
                # narration); tool segments are suppressed below either way.
                if not _emit_text(text):
                    return True
            # tool segments are intentionally suppressed in voice mode
    except _VoiceAgentError as exc:
        _emit({"type": "error", "error": str(exc), "status": exc.status})
    except Exception as exc:
        print("[webui] voice quality stream error: " + traceback.format_exc(), flush=True)
        _emit({"type": "error", "error": str(exc)})
    _emit({"type": "done"})
    return True


# ---------------------------------------------------------------------------
# In-process agent invocation (voice → chat agent bridge)
# ---------------------------------------------------------------------------

class _VoiceAgentError(Exception):
    """Raised when the voice → chat bridge can't dispatch a turn."""
    def __init__(self, message: str, *, status: int = 500):
        super().__init__(message)
        self.status = status


# Max wall-clock time to wait for the agent's response. Tool calls can be
# slow (browser launches, web searches, etc.), so this is generous.
_VOICE_TURN_TIMEOUT_SECONDS = 180.0

# Prepended to every voice transcript before it enters the (shared) chat
# pipeline. The chat session's system prompt is tuned for a rich text/markdown
# UI; for a spoken reply that's the wrong shape (long, markdown-laden, narrates
# its plan step by step). This per-turn directive tells the agent the reply
# will be read aloud so it answers tersely in plain speech. Only voice turns go
# through _run_agent_turn_via_chat, so this never affects the text chat tab.
_VOICE_REPLY_DIRECTIVE = (
    "[Voice mode — your reply is read aloud by text-to-speech. Use plain spoken "
    "language only: no markdown, asterisks, bullet points, numbered lists, headers, "
    "code blocks, emoji, or raw URLs — say names, numbers, and values in words and "
    "organize anything long as flowing spoken paragraphs, not lists. Give a brief "
    "spoken acknowledgement the moment you begin (for example, 'On it.'). For a "
    "simple question, just say the one- or two-sentence answer. For a request with "
    "several parts that each need a different tool (for example a morning brief — "
    "weather, then calendar, then news), work through them ONE AT A TIME: call a "
    "single tool, then IMMEDIATELY speak that part's result in a sentence or two "
    "before calling the next tool, so each part is heard the moment its data is "
    "ready instead of being saved up for the end. Do NOT call multiple tools at "
    "once / in parallel, and do NOT narrate tool names, your plan, or mechanics — "
    "just speak each part's result as it arrives. When the user wants the full "
    "detail (a briefing, summary, rundown, the news, a report, a morning brief), "
    "speak the COMPLETE answer at its natural length across those spoken parts — do "
    "not truncate or over-shorten it — while still obeying the plain-speech rules "
    "above.]\n\n"
)


def _run_agent_turn_via_chat(session_id: str, user_text: str):
    """GENERATOR. Push `user_text` into the user's active chat session and
    yield segments as they arrive on the SSE stream so callers can react
    incrementally (TTS+play as each text segment lands; show tool status
    the moment a tool starts).

    Yields dicts of either shape:
      {"kind": "text", "text": "..."}                    — assistant prose
      {"kind": "tool", "name": "...", "status": "started"|"completed"|"error",
       "preview": "..."}

    Text/tool boundaries are derived from the underlying chat stream:
      - `token` events accumulate into the current text buffer
      - `tool` / `tool_complete` events flush the buffer first, then emit
        the tool entry — that's what produces the ack → tool → confirm
        cadence the SOUL.md prompt asks the model to produce.

    Callers can do `list(...)` to materialize the old batched behavior or
    iterate directly for streaming.
    """
    import queue as _queue
    import time as _time
    _ensure_hermes_on_path()
    try:
        from api.models import get_session  # type: ignore
        from api.routes import (  # type: ignore
            _start_chat_stream_for_session,
            _resolve_compatible_session_model_state,
        )
        from api.config import STREAMS, STREAMS_LOCK  # type: ignore
    except Exception as exc:
        raise _VoiceAgentError(f"webui chat bridge unavailable: {exc}", status=500)
    # get_session RAISES KeyError on a miss (it never returns falsy), so the old
    # `if not s` guard was dead code: a missing/unresolvable session id (a stale
    # id, or a coding/CLI/Telegram channel id) escaped as a raw KeyError that the
    # realtime WS swallowed into a silent end_turn (the "thinking → listening,
    # nothing spoken" bug). Resolve-or-error explicitly instead.
    try:
        s = get_session(session_id)
    except KeyError:
        raise _VoiceAgentError(f"session {session_id!r} not found", status=404)

    # Auto-approve tools for this voice session. Speaking the request is the
    # consent gesture; we don't want a popup in the chat tab interrupting the
    # voice flow.
    try:
        from tools.approval import enable_session_yolo  # type: ignore
        enable_session_yolo(session_id)
    except Exception:
        pass

    # Resolve the session's model/provider exactly like every normal chat turn
    # does (routes._resolve_compatible_session_model_state). The voice bridge
    # used to pass the session's RAW model straight through — but a voice turn
    # can land on a session created with an empty model (model="") and a Codex
    # provider, and Codex's preflight rejects an empty model
    # ("Codex Responses request 'model' must be a non-empty string"). Resolving
    # here substitutes the user's configured default model (their Codex model)
    # and normalizes a stale cross-provider model, killing that crash for both
    # web and mobile voice. Codex stays the provider — this never forces Claude.
    try:
        eff_model, eff_provider, was_normalized = _resolve_compatible_session_model_state(
            getattr(s, "model", None),
            getattr(s, "model_provider", None),
        )
    except Exception:
        eff_model = getattr(s, "model", None) or ""
        eff_provider = getattr(s, "model_provider", None)
        was_normalized = False
    if not (eff_model or "").strip():
        # No usable model anywhere (config model.default empty AND no env
        # override). Don't hand an empty model to the provider — Codex's
        # preflight rejects it with a cryptic error. Fail clearly so the bridge
        # speaks a clean apology instead of crashing on an empty model.
        raise _VoiceAgentError("no model is configured for voice", status=503)
    try:
        response = _start_chat_stream_for_session(
            s,
            msg=_VOICE_REPLY_DIRECTIVE + user_text,
            workspace=getattr(s, "workspace", None) or "",
            model=eff_model,
            model_provider=eff_provider,
            normalized_model=was_normalized,
        )
    except Exception as exc:
        raise _VoiceAgentError(f"failed to start chat turn: {exc}", status=500)
    if isinstance(response, dict) and response.get("error"):
        status_code = int(response.get("_status") or 500)
        raise _VoiceAgentError(str(response.get("error")), status=status_code)
    stream_id = (response or {}).get("stream_id") if isinstance(response, dict) else None
    if not stream_id:
        raise _VoiceAgentError("chat turn did not return a stream_id", status=500)

    with STREAMS_LOCK:
        channel = STREAMS.get(stream_id)
    if channel is None:
        raise _VoiceAgentError("stream channel disappeared before subscribe", status=500)
    subscriber = channel.subscribe()

    # Tracks the most recent tool-started segment we yielded so that a
    # later tool_complete event can be paired up. We can't mutate a value
    # already yielded to the caller; instead we yield a fresh
    # {"kind": "tool", "status": "completed", ...} entry referencing the
    # same tool name. Clients dedup on (name + status).
    last_tool_name = ""
    current_text: list = []
    # The FIRST spoken segment of a turn flushes as soon as one complete
    # sentence exists (min_len=0) so the opening clause/ack is heard in ~1s
    # (near-instant feel). After that we batch to ~110 chars to avoid many
    # tiny TTS calls mid-answer. See _take_complete_sentences.
    first_text_emitted = False
    deadline = _time.monotonic() + _VOICE_TURN_TIMEOUT_SECONDS

    try:
        while _time.monotonic() < deadline:
            try:
                event = subscriber.get(timeout=1.0)
            except _queue.Empty:
                # No event in the last second — check if the stream channel
                # is gone (agent crashed without emitting done).
                with STREAMS_LOCK:
                    still_alive = stream_id in STREAMS
                if not still_alive:
                    break
                continue
            if not isinstance(event, tuple) or len(event) != 2:
                continue
            event_type, data = event
            if event_type == "token":
                if isinstance(data, dict):
                    current_text.append(str(data.get("text") or ""))
                    # Stream by sentence: emit completed sentence(s) as soon as
                    # they're written so the client can synthesize + speak them
                    # immediately, rather than waiting for the whole answer. The
                    # first segment uses min_len=0 (flush on the first sentence
                    # terminator) for a near-instant ack; later segments batch.
                    _joined = "".join(current_text)
                    _min_len = 0 if not first_text_emitted else 110
                    _emit_now, _remainder = _take_complete_sentences(_joined, min_len=_min_len)
                    if _emit_now:
                        current_text = [_remainder] if _remainder else []
                        first_text_emitted = True
                        yield {"kind": "text", "text": _emit_now}
            elif event_type == "tool":
                # Flush any in-progress text segment first — that's what
                # gives us the "ack before tool" cadence.
                if current_text:
                    text = "".join(current_text).strip()
                    current_text.clear()
                    if text:
                        first_text_emitted = True
                        yield {"kind": "text", "text": text}
                name = ""
                preview = ""
                if isinstance(data, dict):
                    name = str(data.get("name") or data.get("tool") or "")
                    preview = str(data.get("preview") or "")
                last_tool_name = name
                yield {
                    "kind": "tool",
                    "name": name,
                    "status": "started",
                    "preview": preview,
                }
            elif event_type == "tool_complete":
                name = ""
                is_error = False
                if isinstance(data, dict):
                    name = str(data.get("name") or "") or last_tool_name
                    is_error = bool(data.get("is_error"))
                yield {
                    "kind": "tool",
                    "name": name,
                    "status": "error" if is_error else "completed",
                }
            elif event_type == "done":
                # Flush remaining text before terminating.
                if current_text:
                    text = "".join(current_text).strip()
                    current_text.clear()
                    if text:
                        yield {"kind": "text", "text": text}
                return
            # reasoning / metering / clarify / approval — ignored. clarify
            # and approval rarely fire under yolo; reasoning is not voiced.
    finally:
        try:
            channel.unsubscribe(subscriber)
        except Exception:
            pass

    # Deadline hit without a done event — flush whatever we have so the
    # caller still gets the final text segment.
    if current_text:
        text = "".join(current_text).strip()
        if text:
            yield {"kind": "text", "text": text}


# ---------------------------------------------------------------------------
# Shared pipeline helpers
# ---------------------------------------------------------------------------

def _pcm_to_transcript(pcm_bytes: bytes, sample_rate: int) -> str:
    transcribe = _try_import_stt()
    if not transcribe:
        return ""
    wav_bytes = _pcm_to_wav(pcm_bytes, sample_rate=sample_rate)
    with tempfile.NamedTemporaryFile(prefix="webui-voice-", suffix=".wav", delete=False) as tmp:
        tmp_path = tmp.name
        tmp.write(wav_bytes)
    try:
        result = transcribe(tmp_path)
        if isinstance(result, dict) and result.get("success"):
            transcript = str(result.get("transcript") or "").strip()
            # Drop whisper hallucinations (silence/noise artifacts like
            # "Thank you for watching" or repetition loops) so a phantom
            # transcript never triggers an agent turn — matters most for the
            # short, noisy Apple-Watch relay clips.
            try:
                from agent.voice_hallucination import is_hallucinated_output
                if transcript and is_hallucinated_output(transcript, mode="conversation"):
                    transcript = ""
            except Exception:
                pass
            return transcript
        return ""
    finally:
        try:
            Path(tmp_path).unlink(missing_ok=True)
        except Exception:
            pass


def _pcm_to_wav(pcm_bytes: bytes, sample_rate: int = 16000,
                channels: int = 1, sample_width: int = 2) -> bytes:
    import io
    import wave
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(sample_width)
        w.setframerate(sample_rate)
        w.writeframes(pcm_bytes)
    return buf.getvalue()


def _generate_reply(transcript: str) -> str:
    """One-shot LLM call routed through JarvisCopilot's auxiliary_client.

    JarvisCopilot core (agent.auxiliary_client.call_llm) knows how to talk to every
    provider JarvisCopilot supports — including OpenAI Codex (which uses the
    Responses API + OAuth tokens stored in ~/.jarviscopilot/auth.json's credential
    pool, NOT a static api_key in config.yaml). Delegating to it means the
    voice tab automatically picks up whichever provider the user has
    configured via `jarviscopilot model` / `jarviscopilot auth add` without re-implementing
    the Codex/Responses/Cloudflare-header plumbing here.

    Falls back to an "I heard: ..." acknowledgement only when the LLM call
    raises — so the user gets *some* audio reply rather than silence when
    auth is misconfigured.
    """
    if not transcript:
        return ""
    _ensure_hermes_on_path()
    cfg = _hermes_config()
    model_cfg = cfg.get("model") or {}
    provider = (model_cfg.get("provider") or "").strip()
    model = (
        model_cfg.get("default")
        or model_cfg.get("name")
        or os.environ.get("OPENAI_MODEL")
        or ""
    ).strip()
    try:
        from agent.auxiliary_client import call_llm  # type: ignore
        response = call_llm(
            provider=provider or None,
            model=model or None,
            messages=[
                {"role": "system", "content": "You are a concise voice assistant. Reply in one or two short sentences."},
                {"role": "user", "content": transcript},
            ],
            max_tokens=300,
            timeout=45.0,
        )
        reply = (response.choices[0].message.content or "").strip()
        if reply:
            return reply
    except Exception:
        print("[webui] voice LLM call failed: " + traceback.format_exc(), flush=True)
    return f"I heard: {transcript}"


def _hermes_config() -> dict:
    try:
        import yaml
        cfg_path = Path.home() / ".jarviscopilot" / "config.yaml"
        if not cfg_path.exists():
            return {}
        with open(cfg_path, "r", encoding="utf-8") as f:
            return yaml.safe_load(f) or {}
    except Exception:
        return {}


# Markdown / symbol patterns that TTS otherwise reads aloud literally
# ("asterisk asterisk", "pound", "backtick"). Voice-only: callers send the
# original (markdown) text to the client for display before synthesizing,
# so stripping here changes only what is *spoken*, never the chat or the
# on-screen transcript.
_SPK_FENCE = re.compile(r"```[\s\S]*?```")
_SPK_IMG = re.compile(r"!\[([^\]]*)\]\([^)]*\)")
_SPK_LINK = re.compile(r"\[([^\]]+)\]\([^)]*\)")
_SPK_INLINE_CODE = re.compile(r"`([^`]+)`")
_SPK_HEADER = re.compile(r"^\s{0,3}#{1,6}\s*", re.MULTILINE)
_SPK_QUOTE = re.compile(r"^\s{0,3}>\s?", re.MULTILINE)
_SPK_BULLET = re.compile(r"^\s{0,3}[-*+]\s+", re.MULTILINE)
_SPK_EMPHASIS = re.compile(r"\*\*|\*|__|_|~~|`")
_SPK_MULTI_NL = re.compile(r"\n{3,}")


def _speakable(text: str) -> str:
    """Strip markdown/symbols so TTS speaks clean prose.

    Removes code fences, link/image syntax (keeping the visible text),
    headers, blockquote/list markers, and emphasis characters (``**``,
    ``*``, ``_``, ``~~``, ``` ` ```). Conservative — leaves ordinary
    punctuation intact.
    """
    if not text:
        return text
    s = _SPK_FENCE.sub(" ", text)
    s = _SPK_IMG.sub(r"\1", s)
    s = _SPK_LINK.sub(r"\1", s)
    s = _SPK_INLINE_CODE.sub(r"\1", s)
    s = _SPK_HEADER.sub("", s)
    s = _SPK_QUOTE.sub("", s)
    s = _SPK_BULLET.sub("", s)
    s = _SPK_EMPHASIS.sub("", s)
    s = s.replace("•", " ").replace("→", " to ")
    s = _SPK_MULTI_NL.sub("\n\n", s)
    return s.strip()


import re as _re_voice
_SENTENCE_END = _re_voice.compile(r"[.!?](?:[\"')\]]+)?(?:\s|$)")


def _take_complete_sentences(buf: str, min_len: int = 110):
    """Return (text_to_speak_or_None, remainder).

    Emits everything up to the last sentence terminator once the buffer holds at
    least `min_len` chars, so voice can synthesize/speak a sentence group as it
    streams (low latency) instead of waiting for the whole answer. Below min_len
    we keep accumulating to avoid lots of tiny TTS calls.
    """
    if len(buf) < min_len:
        return None, buf
    matches = list(_SENTENCE_END.finditer(buf))
    if not matches:
        return None, buf
    cut = matches[-1].end()
    head = buf[:cut].strip()
    return (head or None), buf[cut:]


def _split_for_speech(text: str, target: int = 480, hard: int = 900) -> list:
    """Split long spoken text into chunks each synthesizable quickly/reliably.

    Prefers paragraph boundaries (so the client's join keeps the layout), then
    groups sentences to ~target chars, hard-splitting any monster sentence. A
    short text returns as a single chunk.
    """
    import re as _re
    text = (text or "").strip()
    if not text:
        return []
    if len(text) <= hard:
        return [text]
    out: list = []
    for para in _re.split(r"\n\s*\n", text):
        para = para.strip()
        if not para:
            continue
        if len(para) <= hard:
            out.append(para)
            continue
        cur = ""
        for s in _re.split(r"(?<=[.!?])\s+", para):
            s = s.strip()
            if not s:
                continue
            if cur and len(cur) + 1 + len(s) > target:
                out.append(cur)
                cur = s
            else:
                cur = (cur + " " + s).strip() if cur else s
            while len(cur) > hard:  # a single very long sentence
                out.append(cur[:hard])
                cur = cur[hard:].strip()
        if cur:
            out.append(cur)
    return out or [text]


def _tts_to_base64(text: str) -> str:
    if not text:
        return ""
    # Speak clean prose, not raw markdown ("asterisk asterisk").
    text = _speakable(text)
    if not text:
        return ""
    # Fish Audio is a cloud REST API, not a JarvisCopilot built-in. Special-case
    # before the JarvisCopilot path so it doesn't disappear when JarvisCopilot can't
    # resolve "fish-audio" as a provider.
    cfg = _read_hermes_config()
    provider = ""
    try:
        tts_section = cfg.get("tts") if isinstance(cfg, dict) else None
        if isinstance(tts_section, dict):
            provider = str(tts_section.get("provider") or "").strip()
    except Exception:
        pass
    if provider == "fish-audio":
        try:
            audio = _synthesize_fish_audio(text, tts_cfg=cfg.get("tts") or {})
            return base64.b64encode(audio).decode("ascii") if audio else ""
        except Exception:
            print("[webui] fish-audio TTS failed: " + traceback.format_exc(), flush=True)
            return ""
    tts_fn, _, _ = _try_import_tts()
    if not tts_fn:
        return ""
    out_path = _make_tempfile_path("webui-tts-", ".mp3")
    try:
        result_json = tts_fn(text=text, output_path=out_path)
        try:
            result = json.loads(result_json) if isinstance(result_json, str) else (result_json or {})
        except Exception:
            return ""
        if not result.get("success"):
            return ""
        fp = result.get("file_path") or out_path
        if not Path(fp).exists():
            return ""
        return base64.b64encode(Path(fp).read_bytes()).decode("ascii")
    finally:
        # Clean up any temp file the TTS layer may have produced under the
        # reserved path or a sibling with a different suffix (Piper writes
        # .wav then renames; Edge writes .mp3 directly).
        _cleanup_tempfile_siblings(out_path)


def _make_tempfile_path(prefix: str, suffix: str) -> str:
    """Reserve a unique temp filepath without leaving an empty file behind.

    `tempfile.NamedTemporaryFile(delete=False)` creates the file (0 bytes),
    which then collides with JarvisCopilot's Piper renamer on Windows:
        OSError [WinError 183]: Cannot create a file when that file already
        exists: '<tmp>.wav' -> '<tmp>.mp3'
    os.rename on Windows refuses to overwrite. mkstemp + immediate unlink
    gives us a guaranteed-unique path with no file at it, so the rename
    succeeds regardless of which extension the TTS engine ultimately
    produces.
    """
    fd, path = tempfile.mkstemp(prefix=prefix, suffix=suffix)
    try:
        os.close(fd)
    except Exception:
        pass
    try:
        os.unlink(path)
    except Exception:
        pass
    return path


def _cleanup_tempfile_siblings(path: str) -> None:
    """Best-effort remove `path` and any sibling that shares its stem.

    Edge TTS writes the path we gave it. Piper writes a .wav next to it then
    renames to our extension. ElevenLabs and OpenAI may produce .ogg/.opus
    depending on format. After we read the bytes we want all of them gone.
    """
    try:
        p = Path(path)
    except Exception:
        return
    try:
        p.unlink(missing_ok=True)
    except Exception:
        pass
    try:
        parent = p.parent
        stem = p.stem
        for sib in parent.glob(f"{stem}.*"):
            try:
                sib.unlink(missing_ok=True)
            except Exception:
                pass
    except Exception:
        pass


# ---------------------------------------------------------------------------
# WebSocket — /api/voice/s2s/ws (bridge mode)
# ---------------------------------------------------------------------------

def handle_websocket(handler, parsed) -> bool:
    """Detect WS upgrade, perform handshake via wsproto, run bridge pump.

    Returns True iff this handler claimed the request (path matched).
    """
    if parsed.path != "/api/voice/s2s/ws":
        return False
    try:
        from wsproto import WSConnection, ConnectionType
        from wsproto.events import Request, AcceptConnection
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
    # Long-lived connection: drop the read timeout so blocking recv()s don't
    # cycle the socket out from under us. Each thread owns one socket so the
    # timeout change is request-local.
    try:
        sock.settimeout(None)
    except Exception:
        pass
    conn = WSConnection(ConnectionType.SERVER)
    raw_request = _reconstruct_http_request(handler)
    conn.receive_data(raw_request)
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
    _run_voice_ws(conn, sock)
    return True


def _reconstruct_http_request(handler) -> bytes:
    """Synthesize the raw HTTP request bytes from the BaseHTTPRequestHandler
    state. The handler has already consumed the request line + headers from
    the wire by the time do_GET runs; wsproto's SERVER state machine needs
    them to issue an AcceptConnection response.
    """
    lines = [f"{handler.command} {handler.path} HTTP/1.1"]
    for k, v in handler.headers.items():
        lines.append(f"{k}: {v}")
    lines.append("")
    lines.append("")
    return ("\r\n".join(lines)).encode("latin-1")


# Bound the per-turn mic buffer to keep memory predictable. 4 MB at 16kHz mono
# S16 ≈ 128 seconds, well past any reasonable single utterance.
_WS_BUFFER_LIMIT_BYTES = 4 * 1024 * 1024
_WS_RECV_CHUNK = 8192


def _run_voice_ws(conn, sock) -> None:
    """Bridge-mode S2S pump loop. Blocks until the client disconnects.

    The state dict carries per-connection turn state. Only one synchronous
    end_turn handler runs at a time (it's invoked inline from the recv loop)
    so we don't need locking for ordering — the lock just guards the mic
    buffer against simultaneous appends while the handler is reading it.
    """
    from wsproto.events import (
        TextMessage, BytesMessage, CloseConnection, Ping, Pong,
    )
    state = {
        "pcm_buf": bytearray(),
        "sample_rate": 16000,
        "lock": threading.Lock(),
        "interrupt": False,
        "closed": False,
    }
    _ws_send_text(conn, sock, json.dumps({"type": "ready", "mode": "bridge"}))
    try:
        while not state["closed"]:
            try:
                data = sock.recv(_WS_RECV_CHUNK)
            except (ConnectionResetError, BrokenPipeError, ConnectionAbortedError, TimeoutError, OSError):
                break
            if not data:
                break
            conn.receive_data(data)
            for event in conn.events():
                if isinstance(event, BytesMessage):
                    payload = event.data or b""
                    with state["lock"]:
                        if len(state["pcm_buf"]) + len(payload) <= _WS_BUFFER_LIMIT_BYTES:
                            state["pcm_buf"].extend(payload)
                elif isinstance(event, TextMessage):
                    try:
                        msg = json.loads(event.data or "{}")
                    except Exception:
                        msg = {}
                    _handle_control_frame(msg, state, conn, sock)
                elif isinstance(event, Ping):
                    try:
                        sock.sendall(conn.send(Pong(event.payload)))
                    except Exception:
                        state["closed"] = True
                elif isinstance(event, CloseConnection):
                    try:
                        sock.sendall(conn.send(event.response()))
                    except Exception:
                        pass
                    state["closed"] = True
                    break
    except Exception:
        print("[webui] voice WS error: " + traceback.format_exc(), flush=True)
    finally:
        try:
            sock.close()
        except Exception:
            pass


def _handle_control_frame(msg: dict, state: dict, conn, sock) -> None:
    t = (msg.get("type") or "").lower()
    if t == "begin_turn":
        with state["lock"]:
            state["pcm_buf"].clear()
            state["interrupt"] = False
        sr = int(msg.get("sample_rate") or 0)
        if sr > 0:
            state["sample_rate"] = sr
        sid = (msg.get("session_id") or "").strip()
        if sid:
            state["session_id"] = sid
    elif t == "interrupt":
        state["interrupt"] = True
    elif t == "end_turn":
        try:
            _bridge_pipeline(state, conn, sock)
        except Exception:
            print("[webui] bridge pipeline error: " + traceback.format_exc(), flush=True)
            _ws_send_text(conn, sock, json.dumps({"type": "end_turn", "reason": "error"}))


def _bridge_pipeline(state: dict, conn, sock) -> None:
    """Realtime bridge pipeline. Mirrors Quality mode: routes through the
    active chat session so realtime mode also gets tools and segmented
    ack → tool → confirm responses. The client receives the same event
    types (assistant_text, audio_meta, audio_end, tool, end_turn) but
    they may repeat N times — one set per segment — instead of just
    once per turn.
    """
    with state["lock"]:
        pcm = bytes(state["pcm_buf"])
        sr = state["sample_rate"]
        sid = (state.get("session_id") or "").strip()
        state["pcm_buf"].clear()
    if len(pcm) < 1000:
        _ws_send_text(conn, sock, json.dumps({"type": "end_turn", "reason": "empty"}))
        return
    transcript = _pcm_to_transcript(pcm, sr)
    if not transcript:
        _ws_send_text(conn, sock, json.dumps({"type": "end_turn", "reason": "no_speech"}))
        return
    _ws_send_text(conn, sock, json.dumps({"type": "transcript", "text": transcript, "is_final": True}))
    if state["interrupt"]:
        _ws_send_text(conn, sock, json.dumps({"type": "end_turn", "reason": "interrupt"}))
        return

    # If the client provided a session_id, iterate the chat-agent
    # generator and stream each segment over the WS as soon as it lands.
    # The generator yields tool/text events in order; we synthesize TTS
    # for each text segment inline so the client hears it immediately
    # rather than after the whole turn finishes.
    def _synth_audio(text: str):
        """Synthesize one text segment → ('pcm', pcm24k) | ('mp3', bytes) | None.

        Pure (no socket I/O), so it can run on a worker thread in the prefetch
        pipeline below — that's what lets segment N+1 synthesize while segment
        N is still streaming, instead of compute→speak→compute serially.

        Retries transient TTS failures: a long reply (e.g. a morning brief)
        fires many rapid TTS calls and the engine (Edge TTS by default)
        occasionally drops one. Silently skipping it left the segment's text on
        screen with NO audio — playback stalled and the karaoke froze mid-reply
        even though more text kept streaming. Retry a couple of times first.
        """
        mp3_b64 = ""
        for _attempt in range(3):
            mp3_b64 = _tts_to_base64(text)
            if mp3_b64:
                break
            time.sleep(0.4)  # brief backoff before retrying a dropped synth
        if not mp3_b64:
            return None
        audio_bytes = base64.b64decode(mp3_b64)
        pcm24k = _mp3_to_pcm24k(audio_bytes)
        if pcm24k is None:
            return ("mp3", audio_bytes)
        return ("pcm", pcm24k)

    def _send_audio(audio) -> bool:
        """Stream a synthesized ('pcm'|'mp3', bytes) result over the WS in
        order. Returns False to abort (interrupt / socket dead)."""
        if not audio:
            return True
        fmt, data = audio
        if fmt == "mp3":
            if state["interrupt"]:
                return False
            _ws_send_text(conn, sock, json.dumps({"type": "audio_meta", "format": "mp3", "sample_rate": 0}))
            if not _ws_send_bytes(conn, sock, data):
                return False
            _ws_send_text(conn, sock, json.dumps({"type": "audio_end"}))
            return True
        _ws_send_text(conn, sock, json.dumps({"type": "audio_meta", "format": "pcm_s16le", "sample_rate": 24000}))
        FRAME = 3840
        for i in range(0, len(data), FRAME):
            if state["interrupt"]:
                return False
            if not _ws_send_bytes(conn, sock, data[i:i + FRAME]):
                return False
        _ws_send_text(conn, sock, json.dumps({"type": "audio_end"}))
        return True

    def _stream_segment(seg: dict) -> bool:
        """Inline (non-pipelined) send of one segment. Used for the spoken
        apology messages and the no-session fallback reply. Returns True to
        continue, False to abort."""
        if state["interrupt"]:
            return False
        kind = seg.get("kind")
        if kind == "tool":
            _ws_send_text(conn, sock, json.dumps({
                "type": "tool",
                "name": seg.get("name", ""),
                "status": seg.get("status", "started"),
            }))
            return True
        if kind != "text":
            return True
        text = (seg.get("text") or "").strip()
        if not text:
            return True
        _ws_send_text(conn, sock, json.dumps({"type": "assistant_text", "text": text}))
        if state["interrupt"]:
            return False
        return _send_audio(_synth_audio(text))

    if sid:
        import collections as _collections
        from concurrent.futures import ThreadPoolExecutor
        # Prefetch pipeline: synthesize upcoming text segments in the background
        # so TTS+ffmpeg of segment N+1 overlaps streaming of segment N (instead
        # of the old serial compute→speak→compute). ALL socket writes stay on
        # THIS recv thread — the workers only run pure TTS — so frame ordering
        # is unchanged: per item we send assistant_text, then its audio, in
        # generation order.
        executor = ThreadPoolExecutor(max_workers=2)
        buf = _collections.deque()
        gen = _run_agent_turn_via_chat(sid, transcript)
        gen_exhausted = False
        any_emitted = False
        _PREFETCH = 3

        def _refill():
            nonlocal gen_exhausted, any_emitted
            while len(buf) < _PREFETCH and not gen_exhausted:
                try:
                    seg = next(gen)  # _VoiceAgentError propagates → outer handler
                except StopIteration:
                    gen_exhausted = True
                    break
                any_emitted = True
                k = seg.get("kind")
                if k == "text":
                    t = (seg.get("text") or "").strip()
                    if t:
                        buf.append({"kind": "text", "text": t,
                                    "future": executor.submit(_synth_audio, t)})
                elif k == "tool":
                    buf.append({"kind": "tool", "name": seg.get("name", ""),
                                "status": seg.get("status", "started")})

        try:
            _refill()
            while buf:
                if state["interrupt"]:
                    break
                item = buf.popleft()
                _refill()  # keep synthesis running ahead while we send this one
                if item["kind"] == "tool":
                    _ws_send_text(conn, sock, json.dumps({
                        "type": "tool", "name": item["name"], "status": item["status"],
                    }))
                    continue
                _ws_send_text(conn, sock, json.dumps({"type": "assistant_text", "text": item["text"]}))
                if state["interrupt"]:
                    break
                try:
                    audio = item["future"].result()
                except Exception:
                    audio = None
                if not _send_audio(audio):
                    break
            if not any_emitted and not state["interrupt"]:
                # The agent produced nothing. Never fall back to a SILENT
                # end_turn — the mobile client ignores end_turn `reason`, so a
                # silent no_reply presented as "thinking → listening, nothing
                # spoken". Speak a short apology so the user always gets audio.
                _stream_segment({"kind": "text", "text": "Sorry, I didn't catch a reply that time. Please try again."})
                _ws_send_text(conn, sock, json.dumps({"type": "end_turn", "reason": "no_reply"}))
                return
        except _VoiceAgentError as exc:
            # Log the real detail; SPEAK a clean message (don't read a raw
            # exception/session id aloud).
            print(f"[webui] voice realtime agent error: {exc}", flush=True)
            if not state["interrupt"]:
                _stream_segment({"kind": "text", "text": "Sorry, I ran into a problem handling that. Please try again."})
        except Exception:
            print("[webui] voice realtime pipeline error: " + traceback.format_exc(), flush=True)
            if not state["interrupt"]:
                _stream_segment({"kind": "text", "text": "Sorry, something went wrong on my end. Please try again."})
        finally:
            # Cancel any not-yet-started synth futures so an interrupted / early
            # exited turn doesn't burn TTS+ffmpeg work nobody will hear.
            for _it in buf:
                _f = _it.get("future")
                if _f is not None:
                    _f.cancel()
            executor.shutdown(wait=False)
    else:
        reply = _generate_reply(transcript)
        if reply:
            _stream_segment({"kind": "text", "text": reply})

    _ws_send_text(conn, sock, json.dumps({"type": "end_turn"}))


def _ws_send_text(conn, sock, text: str) -> bool:
    from wsproto.events import TextMessage
    try:
        sock.sendall(conn.send(TextMessage(data=text)))
        return True
    except Exception:
        return False


def _ws_send_bytes(conn, sock, data: bytes) -> bool:
    from wsproto.events import BytesMessage
    try:
        sock.sendall(conn.send(BytesMessage(data=data)))
        return True
    except Exception:
        return False


def _mp3_to_pcm24k(mp3_bytes: bytes):
    """Convert MP3 → 24 kHz mono 16-bit PCM via ffmpeg. Returns None if ffmpeg
    is not on PATH or conversion fails — caller falls back to shipping MP3."""
    import shutil
    import subprocess
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        return None
    try:
        proc = subprocess.run(
            [ffmpeg, "-loglevel", "quiet", "-i", "pipe:0",
             "-f", "s16le", "-ar", "24000", "-ac", "1", "pipe:1"],
            input=mp3_bytes, capture_output=True, timeout=30,
        )
        if proc.returncode != 0:
            return None
        return proc.stdout
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Piper JARVIS voice — personality-driven TTS swap
# ---------------------------------------------------------------------------
#
# When the user selects the "jarvis-mcu" personality in webui settings, the
# voice tab (and any other TTS surface that reads ~/.jarviscopilot/config.yaml)
# switches to Piper's British "jarvis" voice from jgkawell/jarvis on
# HuggingFace. The tuning constants below are lifted from JarvisClaw's
# tts-sidecar (services/tts-sidecar/server.py) so the audio character
# matches its predecessor.

_JARVIS_PIPER_HF_REPO = "jgkawell/jarvis"
_JARVIS_PIPER_QUALITY = "high"  # "high" (~114 MB) or "medium" (~63 MB)
_JARVIS_PIPER_LENGTH_SCALE = 1.04
_JARVIS_PIPER_NOISE_SCALE = 0.45
# JarvisCopilot's Piper integration calls the parameter `noise_w_scale`; piper-tts'
# native API calls it `noise_w`. JarvisCopilot converts in _generate_piper_tts.
_JARVIS_PIPER_NOISE_W_SCALE = 0.55


def _piper_voices_dir() -> Path:
    """Where JarvisCopilot caches Piper voice files. Mirrors
    tools.tts_tool._get_piper_voices_dir() so a single cache works for both
    code paths."""
    d = Path.home() / ".jarviscopilot" / "cache" / "piper-voices"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _ensure_piper_jarvis_voice() -> Path:
    """Download the JARVIS Piper voice (`jgkawell/jarvis`) into the JarvisCopilot
    Piper cache on first call. Returns the absolute path to the .onnx file.

    Idempotent — if both .onnx and .onnx.json are present and non-empty,
    returns immediately. Atomically writes via .tmp + replace so a partial
    download never poisons the cache for the next run.
    """
    quality = _JARVIS_PIPER_QUALITY
    cache = _piper_voices_dir()
    onnx_path = cache / f"jarvis-{quality}.onnx"
    json_path = cache / f"jarvis-{quality}.onnx.json"

    def _ok(p: Path) -> bool:
        try:
            return p.exists() and p.stat().st_size > 0
        except Exception:
            return False

    if _ok(onnx_path) and _ok(json_path):
        return onnx_path

    base = (
        f"https://huggingface.co/{_JARVIS_PIPER_HF_REPO}/resolve/main/"
        f"en/en_GB/jarvis/{quality}"
    )
    try:
        import httpx  # type: ignore
    except Exception as exc:
        raise RuntimeError(f"httpx required to download Piper voice: {exc}")

    for target, suffix in ((onnx_path, ""), (json_path, ".json")):
        if _ok(target):
            continue
        url = f"{base}/jarvis-{quality}.onnx{suffix}"
        tmp = target.with_suffix(target.suffix + ".tmp")
        try:
            with httpx.stream("GET", url, follow_redirects=True, timeout=600.0) as r:
                r.raise_for_status()
                with tmp.open("wb") as f:
                    for chunk in r.iter_bytes(1 << 20):  # 1 MiB chunks
                        if chunk:
                            f.write(chunk)
            if tmp.stat().st_size == 0:
                raise RuntimeError(f"downloaded {url} but got 0 bytes")
            tmp.replace(target)
        except Exception:
            try:
                tmp.unlink(missing_ok=True)
            except Exception:
                pass
            raise

    return onnx_path


def _hermes_config_path() -> Path:
    """Path to the ACTIVE profile's config.yaml (what the agent actually reads).

    Was hardcoded to ~/.jarviscopilot, so voice-engine/provider writes could land
    in the wrong file under a non-default profile and never take effect — hence
    'doesn't persist'. Use the profile-aware home like the rest of the webui."""
    try:
        from api.profiles import get_active_hermes_home  # type: ignore
        return get_active_hermes_home() / "config.yaml"
    except Exception:
        return Path.home() / ".jarviscopilot" / "config.yaml"


def _read_hermes_config() -> dict:
    """Read the active profile's config.yaml — returns {} on failure."""
    try:
        import yaml  # type: ignore
        cfg_path = _hermes_config_path()
        if not cfg_path.exists():
            return {}
        with cfg_path.open("r", encoding="utf-8-sig") as f:
            return yaml.safe_load(f) or {}
    except Exception:
        return {}


def _write_hermes_config(cfg: dict) -> None:
    """Write the active profile's config.yaml atomically, then reload the cached
    config so the change takes effect immediately (no restart). Preserves key
    order via sort_keys=False so the user's manual layout isn't reshuffled."""
    import yaml  # type: ignore
    cfg_path = _hermes_config_path()
    cfg_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = cfg_path.with_suffix(cfg_path.suffix + ".tmp")
    with tmp_path.open("w", encoding="utf-8") as f:
        yaml.safe_dump(cfg, f, sort_keys=False, allow_unicode=True)
    tmp_path.replace(cfg_path)
    try:
        from api.config import reload_config  # type: ignore
        reload_config()
    except Exception:
        pass


def _voice_personality_tts(handler, body) -> bool:
    """POST { name: str | "" } → ensures the Piper JARVIS model is
    downloaded (when name == "jarvis-mcu") and updates config.yaml's tts
    section so subsequent TTS calls (voice tab + CLI + gateway) use the
    matching voice. An empty name reverts TTS to JarvisCopilot's default (edge).

    Returns: { provider: str, voice: str|null, downloaded: bool }
    """
    name = ((body or {}).get("name") or "").strip()
    cfg = _read_hermes_config()
    tts = cfg.get("tts")
    tts = dict(tts) if isinstance(tts, dict) else {}
    downloaded = False
    voice_path: Optional[str] = None

    try:
        if name == "jarvis-mcu":
            onnx_path = _ensure_piper_jarvis_voice()
            downloaded = True
            voice_path = str(onnx_path)
            tts["provider"] = "piper"
            piper_cfg = tts.get("piper")
            piper_cfg = dict(piper_cfg) if isinstance(piper_cfg, dict) else {}
            piper_cfg["voice"] = voice_path
            piper_cfg["length_scale"] = _JARVIS_PIPER_LENGTH_SCALE
            piper_cfg["noise_scale"] = _JARVIS_PIPER_NOISE_SCALE
            piper_cfg["noise_w_scale"] = _JARVIS_PIPER_NOISE_W_SCALE
            tts["piper"] = piper_cfg
        else:
            # Revert to JarvisCopilot's default TTS engine (Edge TTS — free, neural,
            # ships in [edge-tts] extra which the launch script installs).
            tts["provider"] = "edge"
        cfg["tts"] = tts
        _write_hermes_config(cfg)
    except Exception as exc:
        return j(handler, {"error": f"failed to apply personality TTS: {exc}"}, status=500)

    return j(handler, {
        "provider": tts.get("provider"),
        "voice": voice_path,
        "downloaded": downloaded,
    })


# ---------------------------------------------------------------------------
# Fish Audio TTS (cloud REST)
# ---------------------------------------------------------------------------
#
# Fish is a hosted neural TTS engine that takes a reference_id (the "voice
# ID" the user pastes from fish.audio/m/<id>/) and emits WAV/PCM audio. We
# implement it as a special-case in this file rather than wiring through
# JarvisCopilot core because JarvisCopilot's tts_tool has no Fish provider (the
# "command provider" escape hatch wouldn't give us the streaming + voice-
# id ergonomics this UI needs).
#
# Inspired by JarvisClaw's services/forge/src/voice/fish_audio.rs — same
# request shape, same tolerant URL-style voice-id parsing, same model
# override via ?version=<model> in the pasted ID.

_FISH_AUDIO_DEFAULT_ENDPOINT = "https://api.fish.audio"
_FISH_AUDIO_DEFAULT_MODEL = "s2-pro"
_FISH_AUDIO_API_KEY_ENV_VARS = ("FISH_AUDIO_API_KEY", "FISH_API_KEY")


class _FishAudioError(Exception):
    def __init__(self, message: str, *, config_issue: bool = False):
        super().__init__(message)
        # Config issues (missing key, bad voice id) should NOT silently fall
        # back to another engine; transient issues (5xx, 429, network) can.
        self.config_issue = config_issue


def _fish_audio_api_key(cfg_tts: dict) -> str:
    """Resolve the Fish Audio API key. Config wins over env vars so power
    users can override per-profile; otherwise we walk the env-var list in
    order."""
    section = cfg_tts.get("fish-audio") if isinstance(cfg_tts, dict) else None
    if isinstance(section, dict):
        key = str(section.get("api_key") or "").strip()
        if key:
            return key
    for var in _FISH_AUDIO_API_KEY_ENV_VARS:
        v = os.environ.get(var)
        if v and v.strip():
            return v.strip()
    return ""


def _parse_fish_voice_id(raw: str) -> tuple:
    """Tolerant parse of a Fish voice ID. Accepts:
        - bare hex IDs:                       "612b878b…fdfe"
        - URL-query form:                     "612b878b…fdfe?version=s2-pro"
        - URL-fragment with ampersand:        "612b878b…fdfe&version=s2-pro"
        - full URL:  "https://fish.audio/m/612b…/?version=s2-pro"

    Returns (clean_id, model_override_or_None).
    """
    if not raw:
        return "", None
    s = raw.strip()
    # Strip protocol + domain if the user pasted a full URL.
    for prefix in ("https://fish.audio/m/", "http://fish.audio/m/", "fish.audio/m/"):
        if s.startswith(prefix):
            s = s[len(prefix):]
            break
    # Split off query/fragment params (we accept either ? or &).
    head, sep, tail = s.partition("?")
    if not sep:
        head, sep, tail = s.partition("&")
    head = head.strip().strip("/")
    model_override = None
    if sep and tail:
        # Find a version= or model= key in the params and use its value.
        for chunk in tail.split("&"):
            k, _, v = chunk.partition("=")
            if k.strip().lower() in ("version", "model") and v.strip():
                model_override = v.strip()
                break
    return head, model_override


def _synthesize_fish_audio(text: str, *, tts_cfg: dict) -> bytes:
    """POST `text` to Fish Audio's /v1/tts, return raw WAV bytes (with the
    44-byte RIFF header intact). The client (webui/static/voice.js) decodes
    via WebAudio.decodeAudioData which handles WAV natively.

    Raises _FishAudioError with config_issue=True for misconfigurations
    (missing key, missing voice id, 401/403/404), False for transient
    issues (5xx, network).
    """
    section = tts_cfg.get("fish-audio") if isinstance(tts_cfg, dict) else None
    section = section if isinstance(section, dict) else {}
    voice_id_raw = str(section.get("voice_id") or "").strip()
    model_cfg = str(section.get("model") or _FISH_AUDIO_DEFAULT_MODEL).strip() or _FISH_AUDIO_DEFAULT_MODEL
    endpoint = str(section.get("endpoint") or _FISH_AUDIO_DEFAULT_ENDPOINT).strip().rstrip("/")
    api_key = _fish_audio_api_key(tts_cfg)

    if not api_key:
        raise _FishAudioError(
            "Fish Audio API key not configured. Add it in Settings -> Voice -> Fish Audio.",
            config_issue=True,
        )
    voice_id, model_override = _parse_fish_voice_id(voice_id_raw)
    if not voice_id:
        raise _FishAudioError(
            "Fish Audio voice ID not configured. Paste a voice ID from fish.audio/m/<id> in Settings.",
            config_issue=True,
        )
    model = model_override or model_cfg

    try:
        import httpx  # type: ignore
    except Exception as exc:
        raise _FishAudioError(f"httpx required for Fish Audio: {exc}", config_issue=True)

    url = f"{endpoint}/v1/tts"
    body = {
        "text": text,
        "reference_id": voice_id,
        "format": "wav",
        "sample_rate": 24000,
        "chunk_length": 200,
        "normalize": True,
        "model": model,
    }
    headers = {
        "Authorization": f"Bearer {api_key}",
        # Fish accepts the model selector in both header and body across
        # API versions; sending in both is harmless and avoids a branch.
        "model": model,
        "Content-Type": "application/json",
        "Accept": "audio/wav",
    }
    try:
        with httpx.Client(timeout=60.0) as client:
            r = client.post(url, json=body, headers=headers)
    except httpx.TimeoutException as exc:
        raise _FishAudioError(f"Fish Audio network timeout: {exc}", config_issue=False)
    except httpx.HTTPError as exc:
        raise _FishAudioError(f"Fish Audio network error: {exc}", config_issue=False)

    if r.status_code in (401, 403):
        raise _FishAudioError(f"Fish Audio rejected the API key ({r.status_code}). Re-check it in Settings.", config_issue=True)
    if r.status_code == 404:
        raise _FishAudioError(f"Fish Audio voice {voice_id!r} not found. Verify the voice ID in Settings.", config_issue=True)
    if r.status_code == 400:
        body_snip = (r.text or "")[:200]
        # Treat 400 referencing a bad voice/reference as config; other 400s
        # also point at config (bad model name, bad payload), not transient.
        raise _FishAudioError(f"Fish Audio rejected the request: {body_snip}", config_issue=True)
    if r.status_code >= 500 or r.status_code == 429:
        body_snip = (r.text or "")[:200]
        raise _FishAudioError(f"Fish Audio upstream error ({r.status_code}): {body_snip}", config_issue=False)
    if not r.is_success:
        body_snip = (r.text or "")[:200]
        raise _FishAudioError(f"Fish Audio unexpected status {r.status_code}: {body_snip}", config_issue=False)
    audio = r.content
    if not audio or len(audio) < 1000:
        raise _FishAudioError("Fish Audio returned an empty body", config_issue=False)
    return audio


# ---------------------------------------------------------------------------
# Voice engine list + switch + per-provider config
# ---------------------------------------------------------------------------

# Static catalog of TTS engines exposed in the webui Voice tab. The
# `requires_key` flag drives whether the Settings UI shows an API-key
# field. `voice_kind` describes how the voice slot is configured:
#   - "preset"  : a fixed-name voice ID from _BUILTIN_VOICES
#   - "model"   : a local model file (Piper)
#   - "custom"  : a user-supplied free-form ID (Fish Audio)
_VOICE_ENGINE_CATALOG = [
    {"id": "edge",        "name": "Edge TTS",       "requires_key": False, "voice_kind": "preset"},
    {"id": "openai",      "name": "OpenAI",          "requires_key": True,  "voice_kind": "preset", "env_key": "OPENAI_API_KEY"},
    {"id": "elevenlabs",  "name": "ElevenLabs",      "requires_key": True,  "voice_kind": "preset", "env_key": "ELEVENLABS_API_KEY"},
    {"id": "gemini",      "name": "Google Gemini",   "requires_key": True,  "voice_kind": "preset", "env_key": "GEMINI_API_KEY"},
    {"id": "piper",       "name": "Piper (local)",   "requires_key": False, "voice_kind": "preset"},
    {"id": "fish-audio",  "name": "Fish Audio",      "requires_key": True,  "voice_kind": "custom",
     "env_key": "FISH_AUDIO_API_KEY", "voice_id_hint": "Paste from fish.audio/m/<id>"},
]


def _voice_engines(handler) -> bool:
    """GET /api/voice/engines — list of TTS engines with status:
       { id, name, requires_key, voice_kind, configured, active }
    """
    cfg = _read_hermes_config()
    tts_section = cfg.get("tts") if isinstance(cfg, dict) else None
    tts_section = tts_section if isinstance(tts_section, dict) else {}
    active = str(tts_section.get("provider") or "").strip()

    enabled_set = _enabled_engines_from_cfg(cfg)
    result = []
    for entry in _VOICE_ENGINE_CATALOG:
        eid = entry["id"]
        if eid not in enabled_set:
            continue
        item = dict(entry)
        item["active"] = (eid == active)
        item["configured"] = _engine_is_configured(eid, tts_section, entry)
        # Pull through the current API key (masked) + custom voice id for the
        # Settings UI to render without an extra round-trip.
        section = tts_section.get(eid) if isinstance(tts_section, dict) else None
        section = section if isinstance(section, dict) else {}
        api_key = str(section.get("api_key") or "")
        if not api_key and entry.get("env_key"):
            api_key = os.environ.get(entry["env_key"]) or ""
        item["has_api_key"] = bool(api_key)
        item["api_key_masked"] = _mask_key(api_key)
        if entry.get("voice_kind") == "custom":
            item["voice_id"] = str(section.get("voice_id") or "")
            item["model"] = str(section.get("model") or "")
            item["endpoint"] = str(section.get("endpoint") or "")
        return_voices = _BUILTIN_VOICES.get(eid, [])
        item["voices"] = list(return_voices)
        result.append(item)
    j(handler, {"engines": result, "active": active})
    return True


def _enabled_engines_from_cfg(cfg: dict) -> set:
    """Return the set of engine IDs the user has enabled in
    webui.voice.enabled_engines. Default = all known engines.
    """
    default = {e["id"] for e in _VOICE_ENGINE_CATALOG}
    try:
        webui = cfg.get("webui") if isinstance(cfg, dict) else None
        if isinstance(webui, dict):
            voice = webui.get("voice")
            if isinstance(voice, dict):
                raw = voice.get("enabled_engines")
                if isinstance(raw, list) and raw:
                    return {str(x).strip() for x in raw if x}
    except Exception:
        pass
    return default


def _engine_is_configured(engine_id: str, tts_section: dict, catalog_entry: dict) -> bool:
    """True if the engine can run end-to-end with current settings.
    For key-based engines: needs the API key (in config or env).
    For Fish Audio: also needs voice_id.
    For Piper: needs a voice path (the JARVIS personality wiring sets this).
    For Edge / Gemini-without-key / etc.: always True.
    """
    if catalog_entry.get("requires_key"):
        section = tts_section.get(engine_id) if isinstance(tts_section, dict) else None
        section = section if isinstance(section, dict) else {}
        api_key = str(section.get("api_key") or "").strip()
        env_var = catalog_entry.get("env_key")
        if not api_key and env_var:
            api_key = (os.environ.get(env_var) or "").strip()
        if not api_key:
            return False
    if catalog_entry.get("voice_kind") == "custom":
        section = tts_section.get(engine_id) if isinstance(tts_section, dict) else None
        section = section if isinstance(section, dict) else {}
        if not str(section.get("voice_id") or "").strip():
            return False
    return True


def _mask_key(api_key: str) -> str:
    if not api_key:
        return ""
    s = api_key.strip()
    if len(s) <= 8:
        return "*" * len(s)
    return s[:4] + "…" + s[-4:]


def _voice_set_engine(handler, body) -> bool:
    """POST /api/voice/engine { name: str } — switches tts.provider in
    config.yaml and returns the new state. Refuses to switch to an
    engine that's not in the catalog.
    """
    name = ((body or {}).get("name") or "").strip()
    if not name:
        return j(handler, {"error": "name is required"}, status=400)
    if not any(e["id"] == name for e in _VOICE_ENGINE_CATALOG):
        return j(handler, {"error": f"unknown engine {name!r}"}, status=400)
    cfg = _read_hermes_config()
    tts = cfg.get("tts")
    tts = dict(tts) if isinstance(tts, dict) else {}
    tts["provider"] = name
    cfg["tts"] = tts
    try:
        _write_hermes_config(cfg)
    except Exception as exc:
        return j(handler, {"error": f"failed to save config: {exc}"}, status=500)
    return j(handler, {"provider": name, "ok": True})


def _voice_provider_config(handler, body) -> bool:
    """POST /api/voice/provider-config { engine, api_key?, voice_id?, model?,
    endpoint?, enabled? } — patches per-engine settings into config.yaml.

    Only the supplied fields are touched; unset fields are left as-is.
    Sending api_key="" explicitly clears it.
    """
    body = body or {}
    engine = (body.get("engine") or "").strip()
    if not engine:
        return j(handler, {"error": "engine is required"}, status=400)
    catalog_entry = next((e for e in _VOICE_ENGINE_CATALOG if e["id"] == engine), None)
    if not catalog_entry:
        return j(handler, {"error": f"unknown engine {engine!r}"}, status=400)
    cfg = _read_hermes_config()
    tts = cfg.get("tts")
    tts = dict(tts) if isinstance(tts, dict) else {}
    section = tts.get(engine)
    section = dict(section) if isinstance(section, dict) else {}
    # Selective patch — only update keys the body actually contains, so a
    # caller can save just the API key without clobbering voice_id, etc.
    for field in ("api_key", "voice_id", "model", "endpoint"):
        if field in body:
            val = body.get(field)
            if val is None:
                section.pop(field, None)
            else:
                section[field] = str(val)
    tts[engine] = section
    cfg["tts"] = tts
    # `enabled` flag flips an entry into / out of webui.voice.enabled_engines.
    if "enabled" in body:
        webui = cfg.get("webui")
        webui = dict(webui) if isinstance(webui, dict) else {}
        voice = webui.get("voice")
        voice = dict(voice) if isinstance(voice, dict) else {}
        # Default list = the full catalog when nothing has been set yet.
        current = list(voice.get("enabled_engines") or [e["id"] for e in _VOICE_ENGINE_CATALOG])
        if body.get("enabled"):
            if engine not in current:
                current.append(engine)
        else:
            current = [c for c in current if c != engine]
        voice["enabled_engines"] = current
        webui["voice"] = voice
        cfg["webui"] = webui
    try:
        _write_hermes_config(cfg)
    except Exception as exc:
        return j(handler, {"error": f"failed to save config: {exc}"}, status=500)
    return j(handler, {"ok": True, "engine": engine})

