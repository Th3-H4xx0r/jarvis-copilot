"""Tests for per-message token insights (composition + persistence)."""

import json
import types

from agent.message_insights import compute_message_composition


class _Usage:
    input_tokens = 1200
    output_tokens = 40
    cache_read_tokens = 1100
    cache_write_tokens = 0
    reasoning_tokens = 0


def _agent():
    a = types.SimpleNamespace()
    a._prompt_sections = {"identity": 4000, "behavioral_guidance": 2000,
                          "lazy_manifest": 1200, "memory": 400}
    a.tools = [{"type": "function", "function": {"name": "terminal",
               "description": "run a command", "parameters": {"type": "object"}}}]
    return a


def test_composition_has_sections_and_totals():
    api_messages = [
        {"role": "system", "content": "SYS"},
        {"role": "user", "content": "earlier question"},
        {"role": "assistant", "content": "earlier answer"},
        {"role": "user", "content": "hi"},
    ]
    comp = compute_message_composition(_agent(), api_messages, _Usage(), latency_s=1.5)
    s = comp["sections"]
    # system sub-sections (chars/4)
    assert s["identity"] == 1000 and s["behavioral_guidance"] == 500
    assert s["lazy_manifest"] == 300 and s["memory"] == 100
    # tool schemas + conversation split
    assert s["tool_schemas"] > 0
    assert s["user_message"] > 0
    assert s["conversation_history"] > 0
    # exact API totals preserved
    assert comp["in_total"] == 1200 and comp["out_total"] == 40
    assert comp["cache_read"] == 1100 and comp["latency_s"] == 1.5
    assert comp["estimated_in"] == sum(s.values())


def test_composition_no_history_when_only_user():
    api_messages = [{"role": "system", "content": "SYS"}, {"role": "user", "content": "hi"}]
    comp = compute_message_composition(_agent(), api_messages, _Usage())
    assert "conversation_history" not in comp["sections"]
    assert comp["sections"]["user_message"] > 0


def test_composition_handles_missing_sections():
    a = types.SimpleNamespace()  # no _prompt_sections, no tools
    comp = compute_message_composition(a, [{"role": "user", "content": "hi"}], _Usage())
    assert comp["sections"]["user_message"] > 0
    assert comp["in_total"] == 1200


def test_persistence_round_trip(tmp_path):
    from jarviscopilot_state import SessionDB
    db = SessionDB(db_path=tmp_path / "state.db")
    comp = {"sections": {"identity": 1000, "tool_schemas": 500}, "in_total": 1500}
    db.record_message_usage(
        session_id="sess1", turn=1, timestamp=1718000000.0,
        model="claude-opus-4-8", provider="anthropic",
        input_tokens=1500, output_tokens=42, cache_read_tokens=1400,
        latency_s=1.2, composition_json=json.dumps(comp),
    )
    db.record_message_usage(
        session_id="sess1", turn=2, timestamp=1718000100.0,
        input_tokens=1600, output_tokens=20, composition_json=json.dumps(comp),
    )
    db.record_message_usage(session_id="other", turn=1, timestamp=1718000200.0,
                            input_tokens=99, composition_json="{}")

    rows = db.get_message_usage("sess1")
    assert len(rows) == 2
    # newest-first
    assert rows[0]["turn"] == 2 and rows[1]["turn"] == 1
    assert rows[1]["input_tokens"] == 1500 and rows[1]["model"] == "claude-opus-4-8"
    # composition_json parsed into composition dict
    assert rows[1]["composition"]["sections"]["identity"] == 1000
    assert "composition_json" not in rows[1]
    # scoping
    assert all(r["session_id"] == "sess1" for r in rows)


def test_get_message_usage_empty_for_unknown_session(tmp_path):
    from jarviscopilot_state import SessionDB
    db = SessionDB(db_path=tmp_path / "state.db")
    assert db.get_message_usage("nope") == []
