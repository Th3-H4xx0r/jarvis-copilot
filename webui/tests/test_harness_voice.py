import inspect

import api.voice as voice
from api.voice import _takes_harness_path, _voice_turn_options


def test_harness_id_takes_the_harness_path():
    assert _takes_harness_path("router", explicit_override=False) is True


def test_harness_id_wins_over_an_old_override():
    assert _takes_harness_path("router", explicit_override=True) is True


def test_no_override_uses_the_voice_default_harness():
    assert _takes_harness_path("", explicit_override=False) is True


def test_old_client_override_keeps_the_old_path():
    assert _takes_harness_path("", explicit_override=True) is False


def test_single_with_a_picked_model_keeps_the_explicit_path():
    assert _takes_harness_path("single", explicit_override=True) is False


def test_bridge_passes_harness_id_to_the_turn():
    assert "harness_id" in inspect.signature(voice._run_agent_turn_via_chat).parameters


def _options(**kw):
    base = dict(session_id="s1", heard_before_interrupt=None, client="", carplay=False,
                unsure=(), origin=None, harness_id=None, explicit_model=None)
    base.update(kw)
    args = [base.pop(k) for k in ("session_id", "heard_before_interrupt", "client", "carplay",
                                  "unsure", "origin")]
    return _voice_turn_options(*args, **base)


def test_a_spoken_turn_is_a_voice_turn_without_reasoning():
    turn = _options(harness_id="router")
    assert turn.surface == "voice" and turn.harness_id == "router"
    assert turn.reasoning_off is True and turn.explicit_model is None


def test_old_client_explicit_pick_runs_as_that_model():
    turn = _options(explicit_model=("gpt-5.5", "openai-codex"))
    assert turn.explicit_model == ("gpt-5.5", "openai-codex") and turn.harness_id is None


def test_the_voice_rules_ride_the_turn_and_end_tags_are_cleaned():
    turn = _options()
    assert turn.context.startswith(voice._VOICE_REPLY_DIRECTIVE.rstrip())
    messages = [{"role": "assistant", "content": "Okay. [end]"}]
    turn.clean_messages(messages)
    assert "[end]" not in messages[0]["content"]
