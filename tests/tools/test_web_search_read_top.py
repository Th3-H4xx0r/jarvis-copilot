"""web_search(read_top=N): read the first N results' pages in the same call.

Search and extract providers are fakes registered in the web registry: no
network, no browser, no DNS.
"""
from __future__ import annotations

import json
from typing import Any, Dict, List

import pytest

from agent.web_search_provider import WebSearchProvider


class FakeSearch(WebSearchProvider):
    def __init__(self, n: int = 3, urls: List[str] | None = None) -> None:
        self.urls = urls or [f"https://site{i}.example.com/page" for i in range(n)]

    @property
    def name(self) -> str:
        return "fake-search"

    def is_available(self) -> bool:
        return True

    def supports_extract(self) -> bool:
        return False

    def search(self, query: str, limit: int = 5) -> Dict[str, Any]:
        return {
            "success": True,
            "data": {
                "web": [
                    {"title": f"Result {i}", "url": u, "description": f"snippet {i}", "position": i + 1}
                    for i, u in enumerate(self.urls[:limit])
                ]
            },
        }


class FakeExtract(WebSearchProvider):
    def __init__(self, body: str = "Full page text. " * 50, fail: Dict[str, str] | None = None,
                 raise_exc: Exception | None = None) -> None:
        self.calls: List[List[str]] = []
        self.body = body
        self.fail = fail or {}
        self.raise_exc = raise_exc

    @property
    def name(self) -> str:
        return "fake-extract"

    def is_available(self) -> bool:
        return True

    def supports_search(self) -> bool:
        return False

    def supports_extract(self) -> bool:
        return True

    def extract(self, urls, **kwargs):
        self.calls.append(list(urls))
        if self.raise_exc:
            raise self.raise_exc
        out = []
        for u in urls:
            if u in self.fail:
                out.append({"url": u, "title": "", "content": "", "raw_content": "", "error": self.fail[u]})
            else:
                out.append({"url": u, "title": f"T {u}", "content": self.body, "raw_content": self.body,
                            "metadata": {"tier": "fetch", "ms": 12}})
        return out


class AsyncFakeExtract(FakeExtract):
    async def extract(self, urls, **kwargs):  # type: ignore[override]
        return FakeExtract.extract(self, urls, **kwargs)


@pytest.fixture
def web(monkeypatch):
    """Wire the fakes in; return a helper that runs web_search and parses it."""
    from agent import web_search_registry as reg
    from tools import web_tools

    reg._reset_for_tests()
    monkeypatch.setattr(reg, "_read_config_key", lambda *path: None)
    monkeypatch.setattr(web_tools, "_get_search_backend", lambda: "fake-search")
    monkeypatch.setattr(web_tools, "_get_extract_backend", lambda: "fake-extract")
    monkeypatch.setattr(web_tools, "is_safe_url", lambda url: "127.0.0.1" not in url)

    class Web:
        search = FakeSearch()
        extract = FakeExtract()

        def install(self, search=None, extract=None):
            reg._reset_for_tests()
            self.search = search or self.search
            self.extract = extract if extract is not None else self.extract
            reg.register_provider(self.search)
            if self.extract:
                reg.register_provider(self.extract)
            return self

        def run(self, **kw):
            return json.loads(web_tools.web_search_tool("robot vacuums", **kw))

    w = Web().install()
    yield w
    reg._reset_for_tests()


def _results(out):
    return out["data"]["web"]


class TestReadTop:
    def test_read_top_zero_is_todays_behaviour(self, web):
        plain = web.run(limit=3)
        zero = web.run(limit=3, read_top=0)
        assert zero == plain
        assert web.extract.calls == []
        assert all("content" not in r for r in _results(zero))

    def test_reads_the_top_n_in_one_batched_call(self, web):
        out = web.run(limit=3, read_top=2)
        top, rest = _results(out)[:2], _results(out)[2:]
        assert web.extract.calls == [[r["url"] for r in top]]  # one call, parallel inside the provider
        for r in top:
            assert r["content"].startswith("Full page text.")
            assert r["description"]  # the snippet stays
            assert not r.get("error")
            assert r["tier"] == "fetch"
        assert all("content" not in r for r in rest)
        assert out["success"] is True

    def test_content_is_capped(self, web):
        from tools import web_tools

        web.install(extract=FakeExtract(body="y" * 50_000))
        [r] = _results(web.run(limit=1, read_top=1))
        assert len(r["content"]) <= web_tools.READ_TOP_MAX_CHARS + 100
        assert len(r["content"]) < 50_000

    def test_a_failed_page_keeps_its_snippet_and_gets_an_error(self, web):
        bad = web.search.urls[1]
        web.install(extract=FakeExtract(fail={bad: "fetch: HTTP 403, blocked by a bot challenge"}))
        good, failed = _results(web.run(limit=2, read_top=2))
        assert good["content"] and not good.get("error")
        assert failed["description"] == "snippet 1"
        assert "403" in failed["error"]
        assert not failed.get("content")

    def test_extractor_crash_keeps_every_snippet(self, web):
        web.install(extract=FakeExtract(raise_exc=RuntimeError("extractor exploded")))
        out = web.run(limit=3, read_top=2)
        assert out["success"] is True
        top = _results(out)[:2]
        assert all(r["description"] and "extractor exploded" in r["error"] for r in top)
        assert all("content" not in r for r in _results(out)[2:])

    def test_no_extract_provider_reports_an_error_per_result(self, web):
        web.install(extract=False)
        out = web.run(limit=2, read_top=2)
        assert out["success"] is True
        assert all(r["error"] and r["description"] for r in _results(out))

    def test_read_top_is_capped_at_five(self, web):
        web.install(search=FakeSearch(n=8))
        web.run(limit=8, read_top=50)
        assert len(web.extract.calls[0]) == 5

    @pytest.mark.parametrize("bad", [-3, "lots", None])
    def test_nonsense_read_top_means_zero(self, web, bad):
        web.run(limit=2, read_top=bad)
        assert web.extract.calls == []

    def test_private_and_secret_urls_are_never_sent(self, web):
        urls = ["http://127.0.0.1/admin", "https://evil.example.com/?k=sk-ant-api03-abcdefghijklmnopqrstuv",
                "https://ok.example.com/"]
        web.install(search=FakeSearch(urls=urls), extract=FakeExtract())
        priv, secret, ok = _results(web.run(limit=3, read_top=3))
        assert web.extract.calls == [["https://ok.example.com/"]]
        assert priv["error"] and "content" not in priv
        assert secret["error"] and "content" not in secret
        assert ok["content"]

    def test_async_extract_providers_work(self, web):
        web.install(extract=AsyncFakeExtract())
        [r] = _results(web.run(limit=1, read_top=1))
        assert r["content"].startswith("Full page text.")

    def test_failed_search_is_untouched(self, web, monkeypatch):
        monkeypatch.setattr(web.search, "search", lambda q, limit=5: {"success": False, "error": "rate limited"})
        out = web.run(limit=3, read_top=2)
        assert out == {"success": False, "error": "rate limited"}
        assert web.extract.calls == []


class TestSchemaAndHandler:
    def test_schema_offers_read_top(self):
        from tools.web_tools import WEB_SEARCH_SCHEMA

        prop = WEB_SEARCH_SCHEMA["parameters"]["properties"]["read_top"]
        assert prop["type"] == "integer"
        assert prop["minimum"] == 0 and prop["maximum"] == 5 and prop["default"] == 0
        assert "read_top" not in WEB_SEARCH_SCHEMA["parameters"]["required"]

    def test_schema_text_names_no_tools_from_other_toolsets(self):
        from tools.web_tools import WEB_SEARCH_SCHEMA

        text = json.dumps(WEB_SEARCH_SCHEMA).lower()
        for other in ("browser_", "terminal", "execute_code", "delegate_task", "chrome_"):
            assert other not in text

    def test_registry_handler_passes_read_top(self, web):
        from tools.registry import registry

        out = json.loads(registry.dispatch("web_search", {"query": "q", "limit": 2, "read_top": 1}))
        assert _results(out)[0]["content"]
        assert web.extract.calls == [[_results(out)[0]["url"]]]
