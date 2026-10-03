import inspect
from types import SimpleNamespace

import api.voice as voice
from api.voice import _voice_harness_markers


def test_harness_id_sets_markers():
    s = SimpleNamespace()
    assert _voice_harness_markers(s, "router", explicit_override=False) is True
    assert s._turn_surface == "voice" and s._turn_harness_id == "router"


def test_harness_id_wins_over_an_old_override():
    s = SimpleNamespace()
    assert _voice_harness_markers(s, "router", explicit_override=True) is True


def test_no_override_uses_voice_default():
    s = SimpleNamespace()
    assert _voice_harness_markers(s, "", explicit_override=False) is True
    assert s._turn_harness_id is None and s._turn_surface == "voice"


def test_old_client_override_keeps_old_path():
    s = SimpleNamespace()
    assert _voice_harness_markers(s, "", explicit_override=True) is False
    assert not hasattr(s, "_turn_harness_id")


def test_begin_turn_reads_harness_id_and_bridge_passes_it():
    src = inspect.getsource(voice)
    assert 'state["harness_id"] = (msg.get("harness_id") or "").strip()' in src
    assert "harness_id=state.get(\"harness_id\", \"\")" in src
    assert "harness_id" in inspect.signature(voice._run_agent_turn_via_chat).parameters
