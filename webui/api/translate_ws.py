"""Live translation for the glasses: ``/api/translate/ws`` (Soniox) and
``/api/translate/text`` (Jarvis's own model).

The phone picks where a sentence gets translated. On-device needs nothing here.
"Soniox" streams the glasses' microphone to this socket: one JSON ``start``
frame, then 16 kHz mono PCM16 as binary frames, then ``stop``. The server runs a
Soniox real-time stream that transcribes and translates at once, and sends
back::

    {"type": "ready"}
    {"type": "partial", "text": "...", "language": "es"}     # the line being heard
    {"type": "line", "key": 3, "text": "...", "translation": "...", "language": "es"}
    {"type": "translation", "key": 3, "text": "..."}          # a line's translation, late
    {"type": "error", "message": "..."}
    {"type": "done"}

"Jarvis" transcribes on the phone and posts each finished sentence to
``/api/translate/text``, which asks the auxiliary LLM for the translation.
Nothing here talks to INMO.
"""
from __future__ import annotations

import json
import logging
import threading
import traceback
from typing import Any, Callable, Dict, Optional

logger = logging.getLogger(__name__)

_PATH = "/api/translate/ws"
_RECV_CHUNK = 65536
_MAX_FRAME_BYTES = 1 << 20
_RATE = 16000

# Names read better to the model than bare codes.
_NAMES = {
    "en": "English", "es": "Spanish", "fr": "French", "de": "German", "it": "Italian",
    "pt": "Portuguese", "zh": "Chinese (Simplified)", "ja": "Japanese", "ko": "Korean",
    "hi": "Hindi", "ar": "Arabic", "ru": "Russian", "nl": "Dutch", "tr": "Turkish",
    "vi": "Vietnamese", "th": "Thai", "id": "Indonesian", "pl": "Polish", "uk": "Ukrainian",
}


def language_name(code: str) -> str:
    base = (code or "").split("-")[0].lower()
    return _NAMES.get(base, code or "the target language")


def _code(value: Any) -> str:
    """A BCP-47-ish language code, or "" — never anything else into a prompt."""
    text = str(value or "").strip()
    if not text or len(text) > 16 or not all(c.isalnum() or c == "-" for c in text):
        return ""
    return text


# ── one sentence through Jarvis's model ──

def translate_text(text: str, source: str, target: str,
                   call: Optional[Callable[..., Any]] = None) -> str:
    text = (text or "").strip()
    target = _code(target)
    if not text or not target:
        return ""
    source = _code(source)
    if call is None:
        from agent.auxiliary_client import call_llm as call
    from_part = f" from {language_name(source)}" if source else ""
    messages = [
        {"role": "system", "content": (
            f"You translate live speech{from_part} into {language_name(target)}. "
            "Reply with only the translation of the user's text: no quotes, notes or "
            "explanations. Keep names as they are; keep it natural and as short as the original.")},
        {"role": "user", "content": text[:2000]},
    ]
    response = call(task="translation", messages=messages, max_tokens=400, temperature=0.2, timeout=20.0)
    from agent.auxiliary_client import extract_content_or_reasoning
    return (extract_content_or_reasoning(response) or "").strip().strip('"').strip()


def handle_text(handler, body: Dict[str, Any]) -> None:
    from api.helpers import j, bad
    text = str(body.get("text") or "")
    if not text.strip():
        return bad(handler, "text is required")
    if not _code(body.get("target")):
        return bad(handler, "target language is required")
    try:
        translation = translate_text(text, str(body.get("source") or ""), str(body.get("target") or ""))
    except Exception as exc:
        logger.warning("translate: text failed: %s", exc)
        return j(handler, {"error": f"translation failed: {type(exc).__name__}"}, status=502)
    return j(handler, {"translation": translation})


# ── the Soniox socket ──

class _Sink:
    """Soniox stream events → JSON frames for the phone."""

    def __init__(self, send: Callable[[Dict[str, Any]], bool]) -> None:
        self._send = send

    def on_partial(self, text, start_ms, speaker, language) -> None:
        self._send({"type": "partial", "text": text, "language": language})

    def on_segment(self, segment) -> None:
        self._send({"type": "line", "key": segment.key, "text": segment.text,
                    "translation": segment.translation, "language": segment.language})

    def on_translation(self, key, text) -> None:
        self._send({"type": "translation", "key": key, "text": text})

    def on_error(self, message) -> None:
        self._send({"type": "error", "message": message})


def start_stream(frame: Dict[str, Any], sink, engine=None):
    """Opens the Soniox stream a ``start`` frame asks for; (stream, error)."""
    target = _code(frame.get("target"))
    if not target:
        return None, "target language is required"
    source = _code(frame.get("source"))
    if engine is None:
        from jarvis_speech import registry
        engine = registry.get("soniox")
    if engine is None:
        return None, "Soniox isn't set up on the server"
    ok, why = engine.available()
    if not ok:
        return None, f"Soniox unavailable: {why}"
    hints = [h.split("-")[0] for h in (source, target) if h]
    stream = engine.open_stream(sink, rate=_RATE, translate_to=target.split("-")[0],
                                purpose="translate", language_hints=hints)
    return stream, ""


def _reconstruct_http_request(handler) -> bytes:
    lines = [f"{handler.command} {handler.path} HTTP/1.1"]
    for k, v in handler.headers.items():
        lines.append(f"{k}: {v}")
    lines += ["", ""]
    return "\r\n".join(lines).encode("latin-1")


def handle_websocket(handler, parsed) -> bool:
    """Claims /api/translate/ws. True iff this handler took the request."""
    if parsed.path != _PATH:
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
    try:
        sock.settimeout(None)
    except Exception:
        pass
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
    if accepted:
        _run(conn, sock)
    return True


def _run(conn, sock) -> None:
    from wsproto.events import TextMessage, BytesMessage, CloseConnection, Ping, Pong
    state = {"closed": False, "text": "", "bytes": b""}
    lock = threading.Lock()
    stream = None

    def send(frame: Dict[str, Any]) -> bool:
        with lock:
            if state["closed"]:
                return False
            try:
                sock.sendall(conn.send(TextMessage(data=json.dumps(frame))))
                return True
            except Exception:
                state["closed"] = True
                return False

    def finish() -> None:
        nonlocal stream
        if stream is not None:
            current, stream = stream, None
            try:
                current.finish(timeout=5.0)
            except Exception:
                current.close()

    try:
        while not state["closed"]:
            try:
                data = sock.recv(_RECV_CHUNK)
            except (ConnectionResetError, BrokenPipeError, ConnectionAbortedError, TimeoutError, OSError):
                break
            if not data:
                break
            conn.receive_data(data)
            for event in conn.events():
                if isinstance(event, TextMessage):
                    state["text"] += event.data or ""
                    if not getattr(event, "message_finished", True):
                        continue
                    raw, state["text"] = state["text"], ""
                    try:
                        frame = json.loads(raw)
                    except ValueError:
                        continue
                    kind = frame.get("type")
                    if kind == "start":
                        finish()
                        stream, error = start_stream(frame, _Sink(send))
                        send({"type": "error", "message": error} if error else {"type": "ready"})
                    elif kind == "stop":
                        finish()
                        send({"type": "done"})
                elif isinstance(event, BytesMessage):
                    state["bytes"] += event.data or b""
                    if len(state["bytes"]) > _MAX_FRAME_BYTES:
                        state["bytes"] = b""
                        continue
                    if not getattr(event, "message_finished", True):
                        continue
                    pcm, state["bytes"] = state["bytes"], b""
                    if stream is not None and not stream.feed(pcm):
                        send({"type": "error", "message": stream.error or "the Soniox stream ended"})
                        stream = None
                elif isinstance(event, Ping):
                    with lock:
                        try:
                            sock.sendall(conn.send(Pong(event.payload)))
                        except Exception:
                            state["closed"] = True
                elif isinstance(event, CloseConnection):
                    with lock:
                        try:
                            sock.sendall(conn.send(event.response()))
                        except Exception:
                            pass
                    state["closed"] = True
                    break
    except Exception:
        logger.warning("translate WS error: %s", traceback.format_exc())
    finally:
        if stream is not None:
            stream.close()
        state["closed"] = True
        try:
            sock.close()
        except Exception:
            pass
