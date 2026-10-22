"""The one memory-model setting (default Haiku 5.5 on the API key) and its completer."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import api.memory_map as mm  # noqa: E402


@pytest.fixture(autouse=True)
def _home(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    import api.imessage_memory as im
    monkeypatch.setattr(im, "_store", None)
    from plugins.memory.jarvis_memory import external
    external._handles.clear()
    yield


def test_default_map_agent_is_haiku_on_api_key():
    assert mm.get_agent() == {"model": "claude-haiku-5-5", "provider": "anthropic-api"}
    ref, label = mm.resolve_map_model()
    assert ref == "@anthropic-api:claude-haiku-5-5" and "claude-haiku-5-5" in label


def test_set_agent_validates_and_round_trips():
    assert mm.set_agent({"model": ""}) is False
    assert mm.set_agent("nope") is False
    assert mm.set_agent({"harness_id": "h1"}) is True
    assert mm.get_agent() == {"harness_id": "h1"}
    assert mm.set_agent(None) is True          # Same as Default
    assert mm.get_agent() is None


def test_imessage_choice_migrates_once():
    import api.imessage_memory as im
    im.store().update_settings(agent={"model": "gpt-5.5", "provider": "openai"})
    mm.migrate_imessage_choice()
    assert mm.get_agent() == {"model": "gpt-5.5", "provider": "openai"}
    im.store().update_settings(agent={"harness_id": "later"})
    mm.set_agent({"model": "claude-haiku-5-5", "provider": "anthropic-api"})
    mm.migrate_imessage_choice()
    assert mm.get_agent() == {"model": "claude-haiku-5-5", "provider": "anthropic-api"}


def test_complete_goes_through_one_shot(monkeypatch):
    import api.imessage_memory_writer as w
    calls = []
    monkeypatch.setattr(w, "_one_shot", lambda ref, prompt: calls.append((ref, prompt)) or "ok")
    assert mm.complete("hello", 300) == "ok"
    assert calls == [("@anthropic-api:claude-haiku-5-5", "hello")]


def test_install_registers_completer(monkeypatch):
    from plugins.memory.jarvis_memory import llm
    import api.imessage_memory_writer as w
    monkeypatch.setattr(w, "_one_shot", lambda ref, prompt: "done")
    monkeypatch.setattr(mm, "_register_brief_sources", lambda: None)
    mm.install()
    try:
        assert llm.complete("x") == "done"
    finally:
        llm.set_completer(None)


def test_imessage_writer_uses_memory_model(monkeypatch):
    import api.imessage_memory_writer as w
    mm.set_agent({"harness_id": "h9"})
    monkeypatch.setattr(w, "resolve_extraction_model", lambda agent: (f"ref:{agent}", "x"))
    assert w._memory_model()[0] == "ref:{'harness_id': 'h9'}"
