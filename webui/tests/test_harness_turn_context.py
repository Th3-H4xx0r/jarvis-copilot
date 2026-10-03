import inspect

import api.streaming as st
from api.streaming import _collect_turn_context


def test_turn_context_does_not_touch_system_prompt():
    a = _collect_turn_context("", "VOICE RULES\n[interrupted: heard 'x']", "speaking: phone", "")
    b = _collect_turn_context("", "VOICE RULES", "speaking: mac", "")
    assert a != b and "VOICE RULES" in a and "speaking: phone" in a
    assert _collect_turn_context("", "", "", "") == ""
    src = inspect.getsource(st)
    assert '+ "\\n\\n" + str(_voice_directive)).strip()' not in src
    assert '+ "\\n\\n" + str(_origin_directive)).strip()' not in src


def test_voice_branch_does_not_load_every_tool():
    src = inspect.getsource(st)
    voice_block = src[src.index("_voice_turn_low_reasoning"):src.index("A chat turn's sender device")]
    assert "load_all_deferred" not in voice_block
    assert "apply_lazy_partition" not in src[src.index("strip_end_tags((result"):src.index("if cancel_event.is_set():", src.index("strip_end_tags((result"))]


def test_log_ttft_emits_json_span(caplog):
    import json
    import logging
    import time
    from api.streaming import _log_ttft
    caplog.set_level(logging.INFO)
    _log_ttft("s1", time.monotonic() - 0.25)
    rec = [json.loads(r.getMessage()) for r in caplog.records if '"ttft_ms"' in r.getMessage()][0]
    assert rec["turn_id"] == "s1" and rec["ms"] >= 200 and rec["surface"] == "chat"
