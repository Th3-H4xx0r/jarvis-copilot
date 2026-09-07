"""`/api/voice/quality-turn` accepts already-transcribed TEXT and the caller's
model choice.

The Apple Watch dictates on-device, so it has the words already — there is no
audio to send. Without a text path it could not use the voice pipeline at all,
and a parallel chat call would miss the voice system prompt, the fast lane and
the user's chosen voice model. This is the same turn the phone runs."""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "webui"))

from api import voice


def _capture(monkeypatch):
    """Drive the handler far enough to see what the turn was asked to run."""
    seen = {}

    def _fake_turn(session_id, user_text, **kwargs):
        seen["session_id"] = session_id
        seen["text"] = user_text
        seen.update(kwargs)
        return iter(())

    monkeypatch.setattr(voice, "_run_agent_turn_via_chat", _fake_turn)
    return seen


class _Handler:
    def __init__(self):
        self.status = None
        self.written = b""
        self.wfile = self

    def send_response(self, status): self.status = status
    def send_header(self, *a, **k): pass
    def end_headers(self): pass
    def write(self, data): self.written += data
    def flush(self): pass


def test_text_is_accepted_instead_of_audio(monkeypatch):
    seen = _capture(monkeypatch)
    handler = _Handler()
    voice._voice_quality_turn(handler, {"text": "what's the weather",
                                        "session_id": "sess-1"})
    assert seen["text"] == "what's the weather"
    assert seen["session_id"] == "sess-1"
    assert b'"transcript"' in handler.written, "the caller still sees its own words back"


def test_the_model_choice_is_passed_to_the_shared_turn(monkeypatch):
    seen = _capture(monkeypatch)
    voice._voice_quality_turn(_Handler(), {
        "text": "hello", "session_id": "s",
        "model": "@ollama-cloud:gemma4:31b", "model_provider": "ollama-cloud",
    })
    assert seen.get("model_override") == "@ollama-cloud:gemma4:31b"
    assert seen.get("provider_override") == "ollama-cloud"


def test_audio_still_works_and_is_transcribed(monkeypatch):
    seen = _capture(monkeypatch)
    monkeypatch.setattr(voice, "_pcm_to_transcript", lambda b, sr: "spoken words")
    import base64
    voice._voice_quality_turn(_Handler(), {
        "audio_base64": base64.b64encode(b"x" * 2000).decode(),
        "session_id": "s",
    })
    assert seen["text"] == "spoken words"


def test_neither_text_nor_audio_is_an_error(monkeypatch):
    _capture(monkeypatch)
    handler = _Handler()
    result = []
    monkeypatch.setattr(voice, "j", lambda h, obj, status=200: result.append((obj, status)) or True)
    voice._voice_quality_turn(handler, {"session_id": "s"})
    assert result and result[0][1] == 400
