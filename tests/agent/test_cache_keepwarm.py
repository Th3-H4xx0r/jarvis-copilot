"""Recently used Claude chats get a max_tokens:0 cache read before the hour runs out."""
from types import SimpleNamespace

import pytest

from agent import cache_keepwarm as kw


class _Client:
    def __init__(self):
        self.calls = []
        self.messages = SimpleNamespace(create=self._create)

    def _create(self, **body):
        self.calls.append(body)
        return SimpleNamespace(usage=SimpleNamespace(input_tokens=2, output_tokens=0,
                                                     cache_read_input_tokens=90000, cache_creation_input_tokens=0))


@pytest.fixture(autouse=True)
def _clean(monkeypatch):
    kw._entries.clear()
    monkeypatch.setattr(kw, "_ensure_thread", lambda: None)
    monkeypatch.setattr(kw, "should_keep_warm", lambda agent: True)


def _agent(sid="s1"):
    return SimpleNamespace(session_id=sid, _anthropic_client=None)


def test_refresh_after_interval_with_max_tokens_zero_and_no_stream(monkeypatch):
    c = _Client()
    monkeypatch.setattr(kw.time, "time", lambda: 1000.0)
    kw.remember(_agent(), {"model": "claude-sonnet-5-5", "max_tokens": 64000, "stream": True,
                           "messages": [{"role": "user", "content": "hi"}]}, client=c)
    assert kw.tick(1000.0 + kw.INTERVAL_S - 1) == 0
    assert kw.tick(1000.0 + kw.INTERVAL_S) == 1
    assert c.calls[0]["max_tokens"] == 0 and "stream" not in c.calls[0]
    assert c.calls[0]["messages"] == [{"role": "user", "content": "hi"}]


def test_chat_idle_past_window_is_dropped(monkeypatch):
    c = _Client()
    monkeypatch.setattr(kw.time, "time", lambda: 0.0)
    kw.remember(_agent(), {"model": "m", "messages": []}, client=c)
    assert kw.tick(kw.WARM_FOR_S + 1) == 0 and not kw._entries and not c.calls


def test_thinking_budget_requests_are_not_warmed():
    c = _Client()
    kw.remember(_agent(), {"model": "m", "thinking": {"type": "enabled", "budget_tokens": 8000}}, client=c)
    assert not kw._entries


def test_entries_are_bounded(monkeypatch):
    c = _Client()
    t = [0.0]
    monkeypatch.setattr(kw.time, "time", lambda: t[0])
    for i in range(kw.MAX_SESSIONS + 3):
        t[0] = float(i)
        kw.remember(_agent(f"s{i}"), {"model": "m"}, client=c)
    assert len(kw._entries) == kw.MAX_SESSIONS and "s0" not in kw._entries


def test_should_keep_warm_rules(monkeypatch):
    monkeypatch.undo()
    real = kw.should_keep_warm
    base = dict(api_mode="anthropic_messages", session_id="s", _session_db=object(), platform="webui",
                _cache_retention="long", base_url="https://api.anthropic.com", _anthropic_base_url=None)
    assert real(SimpleNamespace(**base)) is True
    assert real(SimpleNamespace(**{**base, "platform": "cron"})) is False
    assert real(SimpleNamespace(**{**base, "api_mode": "chat_completions"})) is False
    assert real(SimpleNamespace(**{**base, "_session_db": None})) is False
