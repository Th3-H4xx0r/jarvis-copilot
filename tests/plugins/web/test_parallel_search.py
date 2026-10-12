"""Parallel as Jarvis's web search (Pranav, 2026-10-11: "add parallel support").

Search goes straight to Parallel's ``POST /v1/search`` over httpx (no SDK), in the
cheap ``fast`` mode ($1 per 1,000 searches) unless ``web.parallel_mode`` picks
another, and a refused key / empty credit balance comes back as a plain error so
web_search can fall back to the free engine."""
import json

import httpx
import pytest

import tools.web_tools as wt
from plugins.web.parallel import provider as pp


class _Resp:
    def __init__(self, status, body):
        self.status_code = status
        self._body = body
        self.text = json.dumps(body)

    def json(self):
        return self._body


@pytest.fixture
def calls(monkeypatch):
    state = type("Calls", (), {})()
    state.sent = []
    state.reply = [_Resp(200, {"search_id": "s1", "results": [
        {"url": "https://a.example/fares", "title": "Cheap fares", "excerpts": ["$89 one way", "Houston to SF"]},
        {"url": "https://b.example", "title": None, "excerpts": []},
    ]})]

    def fake_post(url, **kw):
        state.sent.append({"url": url, **kw})
        return state.reply[0]

    monkeypatch.setenv("PARALLEL_API_KEY", "par-test-key-123")
    monkeypatch.delenv("PARALLEL_SEARCH_MODE", raising=False)
    monkeypatch.setattr(wt, "_load_web_config", lambda: {})
    monkeypatch.setattr(httpx, "post", fake_post)
    return state


def test_searches_parallel_v1_in_fast_mode(calls):
    out = pp.ParallelWebSearchProvider().search("cheap flights Houston to SF", limit=5)
    assert out["success"] is True
    web = out["data"]["web"]
    assert web[0] == {"url": "https://a.example/fares", "title": "Cheap fares",
                      "description": "$89 one way Houston to SF", "position": 1}
    assert web[1]["title"] == "" and web[1]["description"] == "" and web[1]["position"] == 2
    (req,) = calls.sent
    assert req["url"] == "https://api.parallel.ai/v1/search"
    assert req["headers"]["x-api-key"] == "par-test-key-123"
    body = req["json"]
    assert body["mode"] == "fast"
    assert body["search_queries"] == ["cheap flights Houston to SF"]
    assert body["advanced_settings"]["max_results"] == 5


def test_snippets_are_kept_short(calls):
    calls.reply[0] = _Resp(200, {"results": [{"url": "https://a.example", "title": "t",
                                              "excerpts": ["x" * 5000]}]})
    out = pp.ParallelWebSearchProvider().search("q", limit=3)
    assert len(out["data"]["web"][0]["description"]) <= pp.MAX_SNIPPET_CHARS
    assert calls.sent[0]["json"]["advanced_settings"]["excerpt_settings"]["max_chars_per_result"] <= pp.MAX_SNIPPET_CHARS


@pytest.mark.parametrize("configured, sent", [
    ("turbo", "turbo"), ("advanced", "advanced"), ("basic", "basic"),
    ("agentic", "fast"), ("", "fast"), ("nonsense", "fast"),
])
def test_mode_comes_from_web_config(calls, monkeypatch, configured, sent):
    monkeypatch.setattr(wt, "_load_web_config", lambda: {"parallel_mode": configured})
    pp.ParallelWebSearchProvider().search("q")
    assert calls.sent[0]["json"]["mode"] == sent


@pytest.mark.parametrize("status, words", [
    (401, "key"), (403, "key"), (402, "credit"), (429, "rate"), (500, "500"),
])
def test_http_errors_are_plain_failures(calls, status, words):
    calls.reply[0] = _Resp(status, {"type": "error", "error": {"message": "nope"}})
    out = pp.ParallelWebSearchProvider().search("q")
    assert out["success"] is False and words in out["error"].lower()


def test_network_failure_is_a_plain_failure(calls, monkeypatch):
    def boom(url, **kw):
        raise httpx.ConnectTimeout("timed out")
    monkeypatch.setattr(httpx, "post", boom)
    out = pp.ParallelWebSearchProvider().search("q")
    assert out["success"] is False and "parallel" in out["error"].lower()


def test_no_key_means_no_request(calls, monkeypatch):
    monkeypatch.delenv("PARALLEL_API_KEY")
    out = pp.ParallelWebSearchProvider().search("q")
    assert out["success"] is False and "PARALLEL_API_KEY" in out["error"]
    assert calls.sent == []


def test_credits_only_pay_for_searches(monkeypatch):
    """The config Settings → Providers writes on save: Parallel searches, the free
    local reader reads pages (a saved key must not take over web_extract/read_top)."""
    from agent import web_search_registry as reg
    from jarviscopilot_cli.plugins import _ensure_plugins_discovered
    _ensure_plugins_discovered()
    monkeypatch.setenv("PARALLEL_API_KEY", "par-test-key-123")
    monkeypatch.setattr(wt, "_load_web_config",
                        lambda: {"backend": "ddgs", "search_backend": "parallel", "extract_backend": "local"})
    if not wt._is_backend_available("local"):
        pytest.skip("local reader packages (scrapling, curl_cffi, trafilatura) not installed here")
    assert wt._get_search_backend() == "parallel"
    assert wt._get_extract_backend() == "local"
    assert reg.get_provider(wt._get_extract_backend()).name == "local"
