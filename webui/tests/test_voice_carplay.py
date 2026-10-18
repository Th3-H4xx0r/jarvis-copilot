"""CarPlay voice turns: the phone says so on begin_turn ("carplay": true) and the
turn's directive tells the model he is driving — directions on the car, apps
and calls open on the car's screen after the reply, texts through the Mac.

The note rides the per-call voice directive (session._voice_turn_directive →
agent._turn_user_context), never the cached system prompt. Without the flag
nothing changes.
"""
import pathlib
import sys
import threading
import types

import pytest

_WEBUI_DIR = pathlib.Path(__file__).resolve().parent.parent
if str(_WEBUI_DIR) not in sys.path:
    sys.path.insert(0, str(_WEBUI_DIR))

import api.voice as voice  # noqa: E402


def _fresh_state():
    return {
        "lock": threading.Lock(),
        "pcm_buf": bytearray(),
        "interrupt": False,
        "clarify_pending": False,
        "sample_rate": 16000,
        "session_id": "",
    }


def _frame(state, kind, **fields):
    voice._handle_control_frame({"type": kind, **fields}, state, None, None)


# ── begin_turn carries the flag for the turn ───────────────────────────────


def test_begin_turn_with_carplay_marks_the_turn():
    state = _fresh_state()
    _frame(state, "begin_turn", carplay=True)
    assert state["carplay"] is True


def test_begin_turn_without_the_flag_is_not_carplay():
    state = _fresh_state()
    _frame(state, "begin_turn")
    assert not state.get("carplay")


def test_a_later_begin_turn_without_the_flag_clears_it():
    state = _fresh_state()
    _frame(state, "begin_turn", carplay=True)
    _frame(state, "begin_turn")
    assert not state.get("carplay")


def test_end_turn_can_update_the_flag_mid_session(monkeypatch):
    # A phone that sends begin_turn once per socket may still say on end_turn
    # that CarPlay connected or went away; an end_turn without the key keeps it.
    monkeypatch.setattr(voice, "_run_turn_body", lambda state, conn, sock: None)
    state = _fresh_state()
    _frame(state, "begin_turn")
    _frame(state, "end_turn", carplay=True)
    state["turn_thread"].join(timeout=2)
    assert state["carplay"] is True
    _frame(state, "end_turn")
    state["turn_thread"].join(timeout=2)
    assert state["carplay"] is True
    _frame(state, "end_turn", carplay=False)
    state["turn_thread"].join(timeout=2)
    assert state["carplay"] is False


# ── the directive ──────────────────────────────────────────────────────────


def test_the_directive_has_the_carplay_note_only_on_carplay():
    plain = voice._voice_turn_directive(None)
    car = voice._voice_turn_directive(None, carplay=True)
    assert "CarPlay" not in plain
    assert car.startswith(plain.rstrip())
    assert "CarPlay" in car
    for tool in ("device_car_directions", "device_open_app", "device_messages_send", "device_send_sms"):
        assert tool in car, tool
    assert "unlock" in car


def test_the_carplay_note_sends_music_straight_to_spotify_play():
    # In the car the model opened Spotify itself, then checked the state and the
    # device list (only the MacBook) and gave up: play opens Spotify on its own.
    car = voice._voice_turn_directive(None, carplay=True)
    assert "spotify_playback play" in car
    assert "don't call device_open_app or check the state/devices first" in car


def test_the_carplay_note_never_texts_by_controlling_the_mac():
    # When device_messages_send failed, the model clicked through Messages on the
    # Mac with ui_look/ui_do — slow; he wants it never.
    car = voice._voice_turn_directive(None, carplay=True)
    assert "never text by controlling the Mac's screen" in car
    assert "ui_look/ui_do" in car
    assert "tell him why in one sentence" in car


def test_the_carplay_note_keeps_the_other_notes():
    car = voice._voice_turn_directive("Turn left on", carplay=True)
    assert "Turn left on" in car and "CarPlay" in car


def test_the_pipeline_passes_the_flag_to_the_turn(monkeypatch):
    captured = {}
    monkeypatch.setattr(voice, "_ws_send_text", lambda conn, sock, text: True)
    monkeypatch.setattr(voice, "_stream_segments", lambda conn, sock, state, gen, timing=None: True)
    monkeypatch.setattr(
        voice, "_run_agent_turn_via_chat",
        lambda sid, transcript, **kw: captured.update(kw) or iter(()),
    )
    state = _fresh_state()
    _frame(state, "begin_turn", session_id="sess-car", carplay=True, text="play some music")
    voice._bridge_pipeline(state, None, None)
    assert captured.get("carplay") is True


@pytest.mark.parametrize("carplay", [True, False])
def test_the_note_rides_the_per_call_directive(monkeypatch, carplay):
    """End to end through _run_agent_turn_via_chat: the note lands on the
    session's one-call voice directive (folded into the API-call user context),
    and only on a CarPlay turn."""
    from api import models, routes

    sess = types.SimpleNamespace(session_id="sess-car", model="m", model_provider="p",
                                 source_tag="voice", workspace="")
    monkeypatch.setattr(models, "get_session", lambda sid: sess)
    monkeypatch.setattr(routes, "_resolve_compatible_session_model_state", lambda m, p: ("m", "p", False))
    monkeypatch.setattr(routes, "_start_chat_stream_for_session",
                        lambda s, **kw: {"error": "stop after the directive", "_status": 500})
    monkeypatch.setattr(voice, "get_voice_lane_config", lambda: {})

    from api import turn_origin

    phone = {"device_id": "iphone-1", "name": "iPhone", "kind": "mobile-ios"}
    try:
        with pytest.raises(voice._VoiceAgentError):
            list(voice._run_agent_turn_via_chat("sess-car", "play some music", origin=phone, carplay=carplay))

        assert ("CarPlay" in sess._voice_turn_directive) is carplay
        assert sess._voice_turn_directive.startswith(voice._VOICE_REPLY_DIRECTIVE.rstrip())
        # Tools learn it too (a phone turn in the car vs. in his hand).
        assert turn_origin.is_carplay_session("sess-car") is carplay
        assert turn_origin.is_voice_session("sess-car")
    finally:
        turn_origin.note_turn("sess-car", None)


def test_voice_turns_ask_about_calls_and_texts_only_once():
    # The server asks before a call or message on a voice turn (agent/send_confirm.py), with a
    # card; a model that also asked first would ask him twice.
    rules = voice._voice_turn_directive(None)
    assert "straight away" in rules and "card" in rules


def test_the_server_asks_when_the_reply_did_not(monkeypatch):
    # 2026-10-18 16:38: the fast voice model answered "Sending that message to Shabd…" — no
    # question — so the bridge speaks the server's (agent/send_confirm.py) after the reply.
    from agent import send_confirm

    spoken, asked_with = [], []
    monkeypatch.setattr(voice, "_ws_send_text", lambda conn, sock, text: True)
    monkeypatch.setattr(voice, "_run_agent_turn_via_chat", lambda sid, transcript, **kw: iter(()))

    def _segments(conn, sock, state, gen, timing=None):
        voice._note_reply(state, "Sending that message to Shabd now.")
        return False

    monkeypatch.setattr(voice, "_stream_segments", _segments)
    monkeypatch.setattr(voice, "_stream_segment", lambda conn, sock, state, seg: spoken.append(seg["text"]) or True)
    monkeypatch.setattr(send_confirm, "ask_if_unasked",
                        lambda chat, reply: asked_with.append((chat, reply)) or "Should I send the text, sir?")
    state = _fresh_state()
    state["reply_text"] = "an earlier turn's words"
    _frame(state, "begin_turn", session_id="sess-car", text="text Shabd hello")
    voice._bridge_pipeline(state, None, None)
    assert asked_with == [("sess-car", "Sending that message to Shabd now.")]
    assert spoken == ["Should I send the text, sir?"]
