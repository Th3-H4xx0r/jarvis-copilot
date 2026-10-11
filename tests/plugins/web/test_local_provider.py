"""Local extract provider (``plugins/web/local``) — fetch → browser → stealth.

Every tier is faked: no network, no browser, and no dependency on scrapling or
trafilatura being installed (CI does not install the ``web-local`` extra).
"""
from __future__ import annotations

import asyncio
import json
import re
import threading

import pytest

from plugins.web.local import provider as local_mod
from plugins.web.local.provider import LocalWebProvider

LONG = "Real article text that a reader came for. " * 40  # well past the thin-text floor
CHALLENGE_HTML = (
    "<html><head><title>Just a moment...</title></head>"
    "<body><div id='challenge-platform'>Checking your browser</div></body></html>"
)


def _page(html: str, *, status: int = 200, url: str = "", **extra):
    def _fn(u, *a, **k):
        return {"status": status, "url": url or u, "html": html, **extra}

    return _fn


def _boom(message: str = "should not be called"):
    def _fn(*a, **k):
        raise AssertionError(message)

    return _fn


def _fail(error: str):
    def _fn(u, *a, **k):
        return {"status": None, "url": u, "html": "", "error": error}

    return _fn


def _to_text(html: str, url: str):
    """Fake extractor: strip tags; the <title> becomes the title."""
    m = re.search(r"<title>(.*?)</title>", html or "")
    text = re.sub(r"<[^>]+>", " ", html or "")
    return (m.group(1) if m else ""), re.sub(r"\s+", " ", text).strip()


def _provider(**kw) -> LocalWebProvider:
    kw.setdefault("to_text", _to_text)
    kw.setdefault("stealth_enabled", lambda: True)
    kw.setdefault("browser", _boom("browser tier should not run"))
    kw.setdefault("stealth", _boom("stealth tier should not run"))
    return LocalWebProvider(**kw)


@pytest.fixture(autouse=True)
def _no_policy_no_dns(monkeypatch):
    """Keep the URL gates hermetic: no website policy, no DNS lookups."""
    monkeypatch.setattr(local_mod, "check_website_access", lambda url: None)
    monkeypatch.setattr(local_mod, "is_safe_url", lambda url: "127.0.0.1" not in url)


# ---------------------------------------------------------------------------
# Identity / capabilities
# ---------------------------------------------------------------------------


class TestIdentity:
    def test_name_and_capabilities(self):
        p = LocalWebProvider()
        assert p.name == "local"
        assert p.display_name == "Local (fast fetch)"
        assert p.supports_extract() is True
        assert p.supports_search() is False
        assert p.supports_crawl() is False

    def test_unavailable_when_dependencies_missing(self, monkeypatch):
        monkeypatch.setattr(local_mod.importlib.util, "find_spec", lambda name: None)
        assert LocalWebProvider().is_available() is False

    def test_available_when_dependencies_importable(self, monkeypatch):
        monkeypatch.setattr(local_mod.importlib.util, "find_spec", lambda name: object())
        assert LocalWebProvider().is_available() is True

    def test_plugin_registers_the_provider(self):
        from plugins.web import local as plugin

        seen = []

        class Ctx:
            def register_web_search_provider(self, provider):
                seen.append(provider)

        plugin.register(Ctx())
        assert len(seen) == 1 and isinstance(seen[0], LocalWebProvider)


# ---------------------------------------------------------------------------
# Tiers
# ---------------------------------------------------------------------------


class TestTiers:
    def test_fetch_tier_answers_a_normal_page(self):
        p = _provider(fetch=_page(f"<title>Docs</title><p>{LONG}</p>"))
        [r] = p.extract(["https://example.com/a"])
        assert r["url"] == "https://example.com/a"
        assert r["title"] == "Docs"
        assert "Real article text" in r["content"]
        assert r["raw_content"] == r["content"]
        assert not r.get("error")
        assert r["metadata"]["tier"] == "fetch"
        assert isinstance(r["metadata"]["ms"], int) and r["metadata"]["ms"] >= 0

    def test_thin_text_escalates_to_the_browser(self):
        p = _provider(
            fetch=_page("<div id=root></div><noscript>Enable JS</noscript>"),
            browser=_page(f"<title>App</title><main>{LONG}</main>"),
        )
        [r] = p.extract(["https://spa.example.com/"])
        assert r["metadata"]["tier"] == "browser"
        assert r["title"] == "App"
        assert "Real article text" in r["content"]
        assert not r.get("error")

    def test_challenge_page_goes_to_stealth(self):
        p = _provider(
            fetch=_page(CHALLENGE_HTML, status=403),
            stealth=_page(f"<title>Shop</title><p>{LONG}</p>"),
        )
        [r] = p.extract(["https://shop.example.com/item"])
        assert r["metadata"]["tier"] == "stealth"
        assert "Real article text" in r["content"]
        assert not r.get("error")

    def test_challenge_page_skips_stealth_when_disabled(self):
        stealth_calls = []
        p = _provider(
            fetch=_page(CHALLENGE_HTML, status=403),
            browser=_page(CHALLENGE_HTML, status=200, blocked=True),
            stealth=lambda *a, **k: stealth_calls.append(a) or {},
            stealth_enabled=lambda: False,
        )
        [r] = p.extract(["https://shop.example.com/item"])
        assert stealth_calls == []
        assert r["content"] == ""
        assert r["error"] and "block" in r["error"].lower()

    def test_browser_blocked_escalates_to_stealth(self):
        p = _provider(
            fetch=_page("<p>thin</p>"),
            browser=_page(CHALLENGE_HTML, blocked=True),
            stealth=_page(f"<p>{LONG}</p>"),
        )
        [r] = p.extract(["https://example.com/x"])
        assert r["metadata"]["tier"] == "stealth"

    def test_fetch_exception_escalates_instead_of_crashing(self):
        def _raise(*a, **k):
            raise ConnectionError("curl: (35) TLS handshake failed")

        p = _provider(fetch=_raise, browser=_page(f"<p>{LONG}</p>"))
        [r] = p.extract(["https://example.com/tls"])
        assert r["metadata"]["tier"] == "browser"

    def test_all_tiers_failing_gives_a_per_url_error(self):
        p = _provider(
            fetch=_page(CHALLENGE_HTML, status=403),
            browser=_fail("navigation timed out"),
            stealth=_fail("stealth browser crashed"),
        )
        [r] = p.extract(["https://example.com/hard"])
        assert r["content"] == "" and r["raw_content"] == ""
        assert r["error"]
        # The reason names what each tier ran into, never a silent empty success.
        for needle in ("403", "navigation timed out", "stealth browser crashed"):
            assert needle in r["error"]
        assert r["metadata"]["tier"] is None

    def test_not_found_is_final(self):
        p = _provider(fetch=_page("<p>Not here</p>", status=404))
        [r] = p.extract(["https://example.com/missing"])
        assert r["content"] == ""
        assert "404" in r["error"]

    def test_redirect_to_a_private_address_is_refused(self):
        p = _provider(fetch=_page(f"<p>{LONG}</p>", url="http://127.0.0.1/admin"))
        [r] = p.extract(["https://example.com/r"])
        assert r["content"] == ""
        assert "private" in r["error"].lower()

    def test_policy_block_is_reported_without_fetching(self, monkeypatch):
        monkeypatch.setattr(
            local_mod,
            "check_website_access",
            lambda url: {"host": "bad.example", "rule": "bad.example", "source": "config",
                         "message": "Blocked by website policy"},
        )
        p = _provider(fetch=_boom("fetch should not run for a blocked site"))
        [r] = p.extract(["https://bad.example/"])
        assert r["error"] == "Blocked by website policy"
        assert r["blocked_by_policy"]["host"] == "bad.example"

    def test_content_is_capped(self):
        p = _provider(fetch=_page("<p>" + "x" * (local_mod.MAX_CONTENT_CHARS * 3) + "</p>"))
        [r] = p.extract(["https://example.com/huge"])
        assert len(r["content"]) <= local_mod.MAX_CONTENT_CHARS + 200
        assert r["metadata"]["tier"] == "fetch"


# ---------------------------------------------------------------------------
# Many URLs
# ---------------------------------------------------------------------------


class TestManyUrls:
    def test_urls_are_read_concurrently_and_keep_their_order(self):
        urls = [f"https://example.com/{i}" for i in range(3)]
        barrier = threading.Barrier(len(urls), timeout=5)

        def _fetch(u, *a, **k):
            barrier.wait()  # deadlocks (BrokenBarrierError) if run one at a time
            return {"status": 200, "url": u, "html": f"<title>{u}</title><p>{LONG}</p>"}

        results = _provider(fetch=_fetch).extract(urls)
        assert [r["url"] for r in results] == urls
        assert all(r["metadata"]["tier"] == "fetch" for r in results), results
        assert [r["title"] for r in results] == urls

    def test_one_bad_url_does_not_sink_the_others(self):
        def _fetch(u, *a, **k):
            if u.endswith("/bad"):
                return {"status": 404, "url": u, "html": ""}
            return {"status": 200, "url": u, "html": f"<p>{LONG}</p>"}

        good, bad = _provider(fetch=_fetch).extract(
            ["https://example.com/good", "https://example.com/bad"]
        )
        assert good["metadata"]["tier"] == "fetch" and not good.get("error")
        assert bad["error"] and bad["content"] == ""

    def test_empty_url_list(self):
        assert _provider(fetch=_boom()).extract([]) == []


# ---------------------------------------------------------------------------
# web.stealth_fallback config
# ---------------------------------------------------------------------------


class TestStealthConfig:
    @pytest.mark.parametrize(
        "web_cfg,expected",
        [
            ({}, True),
            ({"stealth_fallback": True}, True),
            ({"stealth_fallback": False}, False),
            ({"stealth_fallback": "false"}, False),
            ({"stealth_fallback": "off"}, False),
        ],
    )
    def test_reads_web_stealth_fallback(self, monkeypatch, web_cfg, expected):
        import jarviscopilot_cli.config as cfg

        monkeypatch.setattr(cfg, "load_config", lambda: {"web": web_cfg})
        assert local_mod._stealth_fallback_enabled() is expected

    def test_default_stealth_setting_comes_from_config(self, monkeypatch):
        import jarviscopilot_cli.config as cfg

        monkeypatch.setattr(cfg, "load_config", lambda: {"web": {"stealth_fallback": False}})
        stealth_calls = []
        p = LocalWebProvider(
            fetch=_page(CHALLENGE_HTML, status=403),
            browser=_fail("blocked too"),
            stealth=lambda *a, **k: stealth_calls.append(a) or {},
            to_text=_to_text,
        )
        [r] = p.extract(["https://shop.example.com/"])
        assert stealth_calls == []
        assert r["error"]


# ---------------------------------------------------------------------------
# Registry + web_extract dispatcher
# ---------------------------------------------------------------------------


def _fake_local(monkeypatch) -> LocalWebProvider:
    p = _provider(fetch=_page(f"<title>Local page</title><p>{LONG}</p>"))
    monkeypatch.setattr(p, "is_available", lambda: True)
    return p


@pytest.fixture
def registry(monkeypatch):
    from agent import web_search_registry as reg
    from plugins.web.ddgs.provider import DDGSWebSearchProvider
    from plugins.web.exa.provider import ExaWebSearchProvider
    from plugins.web.firecrawl.provider import FirecrawlWebSearchProvider

    for k in ("EXA_API_KEY", "FIRECRAWL_API_KEY", "FIRECRAWL_API_URL", "TAVILY_API_KEY",
              "PARALLEL_API_KEY", "TOOL_GATEWAY_DOMAIN", "TOOL_GATEWAY_USER_TOKEN"):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.setattr(reg, "_read_config_key", lambda *path: None)
    reg._reset_for_tests()
    reg.register_provider(DDGSWebSearchProvider())
    reg.register_provider(ExaWebSearchProvider())
    reg.register_provider(FirecrawlWebSearchProvider())
    reg.register_provider(_fake_local(monkeypatch))
    yield reg
    reg._reset_for_tests()


def _run_extract(monkeypatch, web_cfg, urls=("https://example.com/page",)):
    from tools import web_tools

    monkeypatch.setattr(web_tools, "_load_web_config", lambda: web_cfg)
    monkeypatch.setattr(web_tools, "_ddgs_package_importable", lambda: True)
    monkeypatch.setattr(web_tools, "_is_tool_gateway_ready", lambda: False)
    monkeypatch.setattr(web_tools, "is_safe_url", lambda url: True)
    return json.loads(asyncio.run(web_tools.web_extract_tool(list(urls), use_llm_processing=False)))


class TestRegistry:
    def test_local_is_the_extract_fallback_without_paid_keys(self, registry):
        assert registry._resolve(None, capability="extract").name == "local"

    def test_paid_extract_provider_outranks_local(self, registry, monkeypatch):
        monkeypatch.setenv("EXA_API_KEY", "exa-test")
        assert registry._resolve(None, capability="extract").name == "exa"

    def test_local_is_never_a_search_provider(self, registry):
        found = registry._resolve(None, capability="search")
        assert found is None or found.name != "local"

    def test_local_follows_the_paid_providers_in_the_preference_walk(self):
        from agent.web_search_registry import _LEGACY_PREFERENCE

        assert "local" in _LEGACY_PREFERENCE
        for paid in ("firecrawl", "parallel", "tavily", "exa"):
            assert _LEGACY_PREFERENCE.index(paid) < _LEGACY_PREFERENCE.index("local")


class TestDispatcher:
    def test_search_only_backend_falls_through_to_local(self, registry, monkeypatch):
        out = _run_extract(monkeypatch, {"backend": "ddgs"})
        [r] = out["results"]
        assert r["title"] == "Local page"
        assert "Real article text" in r["content"]
        assert not r.get("error")
        assert r["tier"] == "fetch"

    def test_explicit_local_extract_backend_beats_an_available_paid_key(self, registry, monkeypatch):
        monkeypatch.setenv("EXA_API_KEY", "exa-test")
        out = _run_extract(monkeypatch, {"backend": "ddgs", "extract_backend": "local"})
        assert out["results"][0]["title"] == "Local page"

    def test_configured_paid_backend_still_wins(self, registry, monkeypatch):
        monkeypatch.setenv("EXA_API_KEY", "exa-test")
        exa = registry.get_provider("exa")
        monkeypatch.setattr(
            exa, "extract",
            lambda urls, **kw: [{"url": u, "title": "From Exa", "content": "exa body",
                                 "raw_content": "exa body"} for u in urls],
        )
        out = _run_extract(monkeypatch, {"backend": "ddgs", "extract_backend": "exa"})
        assert out["results"][0]["title"] == "From Exa"

    def test_search_only_backend_without_any_extractor_still_says_so(self, registry, monkeypatch):
        monkeypatch.setattr(registry.get_provider("local"), "is_available", lambda: False)
        out = _run_extract(monkeypatch, {"backend": "ddgs"})
        assert out["success"] is False
        assert "search-only" in out["error"].lower()

    def test_per_url_error_reaches_the_model(self, registry, monkeypatch):
        local = registry.get_provider("local")
        monkeypatch.setattr(local, "_fetch", _page(CHALLENGE_HTML, status=403))
        monkeypatch.setattr(local, "_browser", _fail("navigation timed out"))
        monkeypatch.setattr(local, "_stealth", _fail("stealth browser crashed"))
        out = _run_extract(monkeypatch, {"backend": "ddgs"})
        [r] = out["results"]
        assert r["content"] == ""
        assert "stealth browser crashed" in r["error"]
