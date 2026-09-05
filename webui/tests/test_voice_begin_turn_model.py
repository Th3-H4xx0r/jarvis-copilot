"""Tests for per-turn model/provider + pre-supplied transcript on begin_turn.

Covers the on-device escalation path:
  * begin_turn carrying `model` / `model_provider` populates `state` so the
    bridge resolves THAT model for the turn (not just the session default);
  * begin_turn carrying `text` stores it as `state["pretranscript"]`, which
    makes _bridge_pipeline skip STT and consume (pop) it so it can't leak into
    the next turn.

Pure unit tests of `_handle_control_frame` with a fake state dict + fake
conn/sock — no agent, no socket I/O (begin_turn never touches the WS).
"""
import pathlib
import sys
import threading

_WEBUI_DIR = pathlib.Path(__file__).resolve().parent.parent
if str(_WEBUI_DIR) not in sys.path:
    sys.path.insert(0, str(_WEBUI_DIR))

from api.voice import _handle_control_frame  # noqa: E402


def _fresh_state():
    """A minimal voice `state` dict shaped like the recv-loop's real one —
    only the fields begin_turn touches."""
    return {
        "lock": threading.Lock(),
        "pcm_buf": bytearray(),
        "interrupt": False,
        "clarify_pending": False,
        "sample_rate": 16000,
        "session_id": "",
    }


class _DeadConn:
    """conn/sock fakes — begin_turn must not send anything, so any use blows up
    the test loudly."""
    def send(self, *a, **k):  # pragma: no cover - should never be called
        raise AssertionError("begin_turn must not touch the socket")


def test_begin_turn_populates_per_turn_model_and_provider():
    state = _fresh_state()
    _handle_control_frame(
        {"type": "begin_turn", "model": "gpt-5-codex", "model_provider": "openai-codex"},
        state, _DeadConn(), _DeadConn(),
    )
    assert state["model"] == "gpt-5-codex"
    assert state["model_provider"] == "openai-codex"


def test_begin_turn_ignores_empty_model_fields():
    state = _fresh_state()
    _handle_control_frame(
        {"type": "begin_turn", "model": "", "model_provider": "   "},
        state, _DeadConn(), _DeadConn(),
    )
    # Absent/empty fields must never create keys that clobber the session default.
    assert "model" not in state
    assert "model_provider" not in state


def test_begin_turn_stores_pretranscript_stripped():
    state = _fresh_state()
    _handle_control_frame(
        {"type": "begin_turn", "text": "  what's the weather  "},
        state, _DeadConn(), _DeadConn(),
    )
    assert state["pretranscript"] == "what's the weather"


def test_begin_turn_empty_text_sets_no_pretranscript():
    state = _fresh_state()
    _handle_control_frame(
        {"type": "begin_turn", "text": "   "},
        state, _DeadConn(), _DeadConn(),
    )
    assert "pretranscript" not in state


def test_begin_turn_still_reads_sample_rate_and_session_id():
    state = _fresh_state()
    _handle_control_frame(
        {"type": "begin_turn", "sample_rate": 24000, "session_id": "sess-123"},
        state, _DeadConn(), _DeadConn(),
    )
    assert state["sample_rate"] == 24000
    assert state["session_id"] == "sess-123"


# --- pretranscript skips STT in _bridge_pipeline -----------------------------

def test_bridge_pipeline_uses_pretranscript_and_skips_stt(monkeypatch):
    """When state has a pretranscript, _bridge_pipeline must NOT call STT, must
    use the supplied text as the transcript, and must POP it so the next turn
    starts clean."""
    from api import voice

    # If STT is reached, fail loudly — the whole point is to skip it.
    monkeypatch.setattr(
        voice, "_pcm_to_transcript",
        lambda *a, **k: (_ for _ in ()).throw(AssertionError("STT must be skipped")),
    )

    sent = []
    monkeypatch.setattr(voice, "_ws_send_text", lambda conn, sock, text: sent.append(text))

    captured = {}

    def _fake_stream_segments(conn, sock, state, gen, timing=None):
        # Drain the generator's first arg path: record the transcript the
        # pipeline resolved by inspecting what was sent + the gen is opaque, so
        # capture via the transcript frame instead.
        captured["reached_agent"] = True
        return True  # signal "fully handled" so _bridge_pipeline returns early

    monkeypatch.setattr(voice, "_stream_segments", _fake_stream_segments)
    monkeypatch.setattr(
        voice, "_run_agent_turn_via_chat",
        lambda sid, transcript, **kw: captured.setdefault("transcript", transcript) or iter(()),
    )

    state = _fresh_state()
    state["session_id"] = "sess-abc"
    state["pretranscript"] = "turn on the lights"
    # No real PCM — proves the audio path is bypassed.

    voice._bridge_pipeline(state, _DeadConn(), _DeadConn())

    assert captured.get("reached_agent") is True
    assert captured.get("transcript") == "turn on the lights"
    # Consumed so it can't leak into the next turn.
    assert "pretranscript" not in state
    # A transcript frame was still emitted to the client.
    assert any('"transcript"' in s and "turn on the lights" in s for s in sent)


def test_bridge_answer_clarify_uses_pretranscript_and_skips_stt(monkeypatch):
    """An on-device clarify answer arrives as text. _bridge_answer_clarify must
    use the pretranscript (skip STT), pop it so it can't leak, and resume the
    clarified turn."""
    from api import voice

    monkeypatch.setattr(
        voice, "_pcm_to_transcript",
        lambda *a, **k: (_ for _ in ()).throw(AssertionError("STT must be skipped")),
    )
    sent = []
    monkeypatch.setattr(voice, "_ws_send_text", lambda conn, sock, text: sent.append(text))

    captured = {}
    monkeypatch.setattr(voice, "_stream_segments",
                        lambda c, s, st, g, timing=None: captured.setdefault("reached", True) or True)
    monkeypatch.setattr(
        voice, "_run_agent_continuation_after_clarify",
        lambda sid, transcript: captured.setdefault("transcript", transcript) or iter(()),
    )

    state = _fresh_state()
    state["session_id"] = "sess-clr"
    state["clarify_pending"] = True
    state["pretranscript"] = "the one from SFO"

    voice._bridge_answer_clarify(state, _DeadConn(), _DeadConn())

    assert captured.get("transcript") == "the one from SFO"
    assert "pretranscript" not in state  # consumed, no leak
    assert state["clarify_pending"] is False
    assert any('"transcript"' in s and "the one from SFO" in s for s in sent)


def test_bridge_pipeline_passes_per_turn_model_override(monkeypatch):
    """A per-turn model/provider in state must be threaded into the agent call."""
    from api import voice

    monkeypatch.setattr(voice, "_ws_send_text", lambda conn, sock, text: None)
    monkeypatch.setattr(voice, "_stream_segments", lambda c, s, st, g, timing=None: True)

    seen = {}

    def _fake_run(sid, transcript, model_override="", provider_override="", lane=""):
        seen["model_override"] = model_override
        seen["provider_override"] = provider_override
        return iter(())

    monkeypatch.setattr(voice, "_run_agent_turn_via_chat", _fake_run)

    state = _fresh_state()
    state["session_id"] = "sess-xyz"
    state["pretranscript"] = "hello"  # skip STT, keep test pure
    state["model"] = "claude-opus-4"
    state["model_provider"] = "anthropic"

    voice._bridge_pipeline(state, _DeadConn(), _DeadConn())

    assert seen["model_override"] == "claude-opus-4"
    assert seen["provider_override"] == "anthropic"
