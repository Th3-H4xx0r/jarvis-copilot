"""browser_extract: one page → typed JSON from one call to the extraction model, so the
main model never reads the raw page."""
import json
from types import SimpleNamespace
from unittest.mock import patch

import pytest

import tools.browser_tool as bt

PAGE = "- heading Flights\n- row United 7:05 AM nonstop $139\n- row Southwest 9:10 AM 1 stop $119"


def _reply(text):
    return SimpleNamespace(choices=[SimpleNamespace(message=SimpleNamespace(content=text))])


@pytest.fixture
def page(monkeypatch):
    def fake(key, command, args=None, timeout=None, _engine_override=None):
        if command == "snapshot":
            return {"success": True, "data": {"snapshot": PAGE}}
        if command == "eval":
            return {"success": True, "data": {"result": "https://flights.example/results"}}
        return {"success": True, "data": {}}
    monkeypatch.setattr(bt, "_run_browser_command", fake)
    monkeypatch.setattr(bt, "_last_session_key", lambda tid: tid or "default")
    monkeypatch.setattr("agent.extract_model.resolve", lambda instruction, size: ("anthropic-api", "claude-haiku-5-5"))


SCHEMA = {"type": "object", "required": ["flights"],
          "properties": {"flights": {"type": "array"}}}


def test_returns_validated_json_with_its_source(page):
    calls = []

    def llm(**kw):
        calls.append(kw)
        return _reply('```json\n{"flights": [{"airline": "Southwest", "price": 119}]}\n```')

    with patch("agent.auxiliary_client.call_llm", llm):
        out = json.loads(bt.browser_extract("cheapest flights", schema=SCHEMA, task_id="t1"))
    assert out["success"] and out["data"]["flights"][0]["price"] == 119
    assert out["source_url"] == "https://flights.example/results" and "ms" in out
    assert calls[0]["provider"] == "anthropic-api" and calls[0]["model"] == "claude-haiku-5-5"
    assert "Southwest 9:10 AM" in calls[0]["messages"][-1]["content"]


def test_a_garbled_reply_is_retried_once(page):
    replies = iter(["sure! here you go", '{"flights": []}'])
    with patch("agent.auxiliary_client.call_llm", lambda **kw: _reply(next(replies))):
        out = json.loads(bt.browser_extract("flights", schema=SCHEMA, task_id="t2"))
    assert out["success"] and out["data"] == {"flights": []}


def test_two_bad_replies_give_a_clear_error_not_junk(page):
    with patch("agent.auxiliary_client.call_llm", lambda **kw: _reply('{"nope": 1}')):
        out = json.loads(bt.browser_extract("flights", schema=SCHEMA, task_id="t3"))
    assert not out["success"] and "flights" in out["error"]


def test_secrets_on_the_page_never_reach_the_model(monkeypatch, page):
    secret = "sk-ant-api03-" + "A" * 40
    monkeypatch.setattr(bt, "_run_browser_command",
                        lambda key, command, args=None, timeout=None, _engine_override=None:
                        {"success": True, "data": {"snapshot": f"- text key {secret}", "result": "https://x.example/"}})
    sent = []
    with patch("agent.auxiliary_client.call_llm", lambda **kw: sent.append(kw) or _reply('{"ok": true}')):
        bt.browser_extract("anything", task_id="t4")
    assert secret not in sent[0]["messages"][-1]["content"]


def test_no_page_yet_says_so(monkeypatch):
    monkeypatch.setattr(bt, "_run_browser_command",
                        lambda *a, **k: {"success": False, "error": "no browser session"})
    monkeypatch.setattr(bt, "_last_session_key", lambda tid: tid or "default")
    out = json.loads(bt.browser_extract("x", task_id="t5"))
    assert not out["success"] and out["error"]
