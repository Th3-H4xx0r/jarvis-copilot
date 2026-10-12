"""web_search falls back to the free engine when the paid one fails.

With Parallel as the search backend, a used-up credit balance, a refused key or
an outage must not leave Jarvis without search: the same call retries on the
free DuckDuckGo provider (ddgs) and says so. Fakes only — no network."""
from __future__ import annotations

import json
from typing import Any, Dict

import pytest

from agent.web_search_provider import WebSearchProvider


class Fake(WebSearchProvider):
    def __init__(self, name: str, reply: Dict[str, Any], available: bool = True) -> None:
        self._name, self.reply, self.available, self.calls = name, reply, available, 0

    @property
    def name(self) -> str:
        return self._name

    @property
    def display_name(self) -> str:
        return {"parallel": "Parallel", "ddgs": "DuckDuckGo"}.get(self._name, self._name)

    def is_available(self) -> bool:
        return self.available

    def supports_extract(self) -> bool:
        return False

    def search(self, query: str, limit: int = 5) -> Dict[str, Any]:
        self.calls += 1
        return self.reply


OK = {"success": True, "data": {"web": [{"title": "Free", "url": "https://free.example", "description": "d",
                                         "position": 1}]}}
PAID_OK = {"success": True, "data": {"web": [{"title": "Paid", "url": "https://paid.example", "description": "d",
                                              "position": 1}]}}
FAILED = {"success": False, "error": "Parallel credits are used up"}


@pytest.fixture
def web(monkeypatch):
    from agent import web_search_registry as reg
    from tools import web_tools

    reg._reset_for_tests()
    monkeypatch.setattr(reg, "_read_config_key", lambda *path: None)
    monkeypatch.setattr(web_tools, "_get_search_backend", lambda: "parallel")

    def install(paid, free=None):
        reg._reset_for_tests()
        reg.register_provider(paid)
        if free is not None:
            reg.register_provider(free)
        return lambda: json.loads(web_tools.web_search_tool("cheap flights"))

    yield install
    reg._reset_for_tests()


def test_a_failed_paid_search_retries_on_the_free_engine(web):
    paid, free = Fake("parallel", FAILED), Fake("ddgs", OK)
    out = web(paid, free)()
    assert out["success"] is True and out["data"]["web"][0]["title"] == "Free"
    assert "Parallel" in out["note"] and "credits" in out["note"] and "DuckDuckGo" in out["note"]
    assert paid.calls == 1 and free.calls == 1


def test_a_working_paid_search_never_touches_the_free_engine(web):
    paid, free = Fake("parallel", PAID_OK), Fake("ddgs", OK)
    out = web(paid, free)()
    assert out["data"]["web"][0]["title"] == "Paid" and "note" not in out
    assert free.calls == 0


def test_no_free_engine_keeps_the_paid_error(web):
    out = web(Fake("parallel", FAILED), Fake("ddgs", OK, available=False))()
    assert out["success"] is False and "credits" in out["error"]


def test_both_failing_reports_the_paid_error_once(web):
    free = Fake("ddgs", {"success": False, "error": "ddgs: no results"})
    out = web(Fake("parallel", FAILED), free)()
    assert out["success"] is False and "credits" in out["error"] and free.calls == 1


def test_the_free_engine_failing_alone_is_not_retried(web, monkeypatch):
    from tools import web_tools
    monkeypatch.setattr(web_tools, "_get_search_backend", lambda: "ddgs")
    free = Fake("ddgs", {"success": False, "error": "ddgs: blocked"})
    out = web(free)()
    assert out["success"] is False and free.calls == 1


def test_an_interrupt_is_not_retried(web):
    free = Fake("ddgs", OK)
    out = web(Fake("parallel", {"success": False, "error": "Interrupted"}), free)()
    assert out["success"] is False and free.calls == 0
