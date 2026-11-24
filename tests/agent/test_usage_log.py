"""Model calls that no session records (review forks, one-shots, auxiliary
calls) still land in message_usage, tagged by source, so Costs counts them."""
import sqlite3
from types import SimpleNamespace

import pytest

from agent import usage_log
from agent.usage_pricing import CanonicalUsage
from jarviscopilot_constants import get_hermes_home


@pytest.fixture(autouse=True)
def _fresh_db(monkeypatch):
    monkeypatch.setattr(usage_log, "_DB", None)
    monkeypatch.setattr(usage_log, "_DB_PATH", None)


def _rows():
    con = sqlite3.connect(str(get_hermes_home() / "state.db"))
    try:
        return con.execute(
            "SELECT session_id, model, provider, input_tokens, output_tokens, cache_read_tokens, "
            "cache_write_tokens, composition_json FROM message_usage").fetchall()
    finally:
        con.close()


def test_record_writes_row():
    usage_log.record("review", model="claude-sonnet-5-5", provider="anthropic-api",
                     usage=CanonicalUsage(input_tokens=1, output_tokens=2, cache_read_tokens=3,
                                          cache_write_tokens=4))
    assert _rows() == [("usage:review", "claude-sonnet-5-5", "anthropic-api", 1, 2, 3, 4,
                                '{"source": "review"}')]


def test_record_never_raises(monkeypatch):
    def boom():
        raise OSError("disk full")
    monkeypatch.setattr(usage_log, "_db", boom)
    usage_log.record("review", model="m", provider="p", usage=CanonicalUsage(input_tokens=1))


def test_agent_without_db_records():
    agent = SimpleNamespace(_usage_source=None, platform="cron", model="claude-haiku-5-5",
                            provider="anthropic-api")
    usage_log.record_for_agent(agent, CanonicalUsage(output_tokens=7), 0.5)
    agent._usage_source = "one_shot:imessage_memory"
    usage_log.record_for_agent(agent, CanonicalUsage(output_tokens=8), 0.5)
    sids = [r[0] for r in _rows()]
    assert sids == ["usage:agent:cron", "usage:one_shot:imessage_memory"]


def test_call_llm_records_aux(monkeypatch):
    import agent.auxiliary_client as aux
    seen = []
    monkeypatch.setattr(usage_log, "record", lambda source, **kw: seen.append((source, kw)))
    response = SimpleNamespace(
        choices=[SimpleNamespace(message=SimpleNamespace(content="Title"), finish_reason="stop")],
        usage=SimpleNamespace(input_tokens=12, output_tokens=3, cache_read_input_tokens=0,
                              cache_creation_input_tokens=0))
    client = SimpleNamespace(base_url="https://api.anthropic.com",
                             chat=SimpleNamespace(completions=SimpleNamespace(create=lambda **kw: response)))

    def attempts(**kw):
        got = yield client, {"model": "claude-haiku-5-5", "messages": []}
        return got

    monkeypatch.setattr(aux, "_llm_call_attempts", attempts)
    monkeypatch.setattr(aux, "_validate_llm_response", lambda r, task: r)
    out = aux.call_llm("title_generation", messages=[{"role": "user", "content": "x"}])
    assert out is response
    assert seen and seen[0][0] == "aux:title_generation"
    assert seen[0][1]["model"] == "claude-haiku-5-5" and seen[0][1]["provider"] == "anthropic-api"
    assert seen[0][1]["usage"].input_tokens == 12 and seen[0][1]["usage"].output_tokens == 3
