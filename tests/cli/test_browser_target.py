"""Tests for jarviscopilot_cli.browser_target — browser target selector."""

import pytest

from jarviscopilot_cli.browser_target import (
    DEFAULT_TARGET,
    VALID_TARGETS,
    normalize_browser_target,
    get_browser_target,
)


class TestNormalize:
    def test_default_when_empty_or_none(self):
        assert normalize_browser_target(None) == DEFAULT_TARGET
        assert normalize_browser_target("") == DEFAULT_TARGET
        assert DEFAULT_TARGET == "server"

    def test_canonical_values_passthrough(self):
        assert normalize_browser_target("server") == "server"
        assert normalize_browser_target("desktop") == "desktop"

    def test_case_and_whitespace_insensitive(self):
        assert normalize_browser_target("  DESKTOP ") == "desktop"
        assert normalize_browser_target("Server") == "server"

    def test_unknown_falls_back_to_default(self):
        assert normalize_browser_target("banana") == DEFAULT_TARGET

    def test_valid_targets_set(self):
        assert VALID_TARGETS == ("server", "desktop")


class TestGetBrowserTarget:
    def test_reads_from_config(self):
        assert get_browser_target({"browser": {"target": "desktop"}}) == "desktop"

    def test_missing_returns_default(self):
        assert get_browser_target({}) == "server"
        assert get_browser_target({"browser": {}}) == "server"

    def test_garbage_normalized(self):
        assert get_browser_target({"browser": {"target": "WAT"}}) == "server"


class TestProvisioning:
    @pytest.fixture(autouse=True)
    def _isolate(self, tmp_path, monkeypatch):
        monkeypatch.setenv("HERMES_HOME", str(tmp_path))
        monkeypatch.setattr(
            "jarviscopilot_cli.config.get_hermes_home", lambda: tmp_path
        )
        monkeypatch.setattr(
            "jarviscopilot_cli.config.get_config_path", lambda: tmp_path / "config.yaml"
        )
        monkeypatch.setattr(
            "jarviscopilot_cli.config.get_env_path", lambda: tmp_path / ".env"
        )
        self.tmp = tmp_path

    def test_server_config_shape(self):
        from jarviscopilot_cli.browser_target import (
            playwright_desktop_server_config,
            PLAYWRIGHT_DESKTOP_SERVER_NAME,
        )
        cfg = playwright_desktop_server_config(enabled=True)
        assert cfg["command"] == "npx"
        assert "@playwright/mcp@latest" in cfg["args"]
        assert "--browser" in cfg["args"] and "chrome" in cfg["args"]
        # Dedicated profile, SEPARATE from /browser connect's chrome-debug dir —
        # Chrome can't open one user-data-dir from two live processes.
        from jarviscopilot_cli.browser_connect import chrome_debug_data_dir
        from jarviscopilot_cli.browser_target import playwright_desktop_profile_dir
        assert playwright_desktop_profile_dir() in cfg["args"]
        assert chrome_debug_data_dir() not in cfg["args"]
        assert playwright_desktop_profile_dir() != chrome_debug_data_dir()
        assert cfg["enabled"] is True
        assert PLAYWRIGHT_DESKTOP_SERVER_NAME == "playwright-desktop"

    def test_ensure_writes_entry(self):
        from jarviscopilot_cli.browser_target import (
            ensure_playwright_desktop_server, PLAYWRIGHT_DESKTOP_SERVER_NAME,
        )
        from jarviscopilot_cli.config import load_config
        changed = ensure_playwright_desktop_server(enabled=True)
        assert changed is True
        servers = load_config().get("mcp_servers", {})
        assert PLAYWRIGHT_DESKTOP_SERVER_NAME in servers
        assert servers[PLAYWRIGHT_DESKTOP_SERVER_NAME]["enabled"] is True

    def test_ensure_is_idempotent(self):
        from jarviscopilot_cli.browser_target import ensure_playwright_desktop_server
        ensure_playwright_desktop_server(enabled=True)
        # Second call with same enabled state makes no change.
        assert ensure_playwright_desktop_server(enabled=True) is False

    def test_ensure_flips_enabled_without_clobbering_others(self):
        from jarviscopilot_cli.browser_target import (
            ensure_playwright_desktop_server, PLAYWRIGHT_DESKTOP_SERVER_NAME,
        )
        from jarviscopilot_cli.config import load_config, save_config
        cfg = load_config()
        cfg.setdefault("mcp_servers", {})["other"] = {"command": "foo", "enabled": True}
        save_config(cfg)
        ensure_playwright_desktop_server(enabled=True)
        changed = ensure_playwright_desktop_server(enabled=False)
        assert changed is True
        servers = load_config().get("mcp_servers", {})
        assert servers["other"] == {"command": "foo", "enabled": True}  # untouched
        assert servers[PLAYWRIGHT_DESKTOP_SERVER_NAME]["enabled"] is False

    def test_set_browser_target_persists(self):
        from jarviscopilot_cli.browser_target import set_browser_target, get_browser_target
        set_browser_target("desktop")
        assert get_browser_target() == "desktop"
        set_browser_target("server")
        assert get_browser_target() == "server"

    def test_relay_server_config_shape(self):
        from jarviscopilot_cli.browser_target import playwright_relay_server_config
        cfg = playwright_relay_server_config("dev-123", enabled=True, browser="chrome")
        assert cfg["transport"] == "device-relay"
        assert cfg["device_id"] == "dev-123"
        assert cfg["meta"] == {"browser": "chrome"}
        assert cfg["enabled"] is True
        # No command/url — routed to the relay transport, not stdio/http.
        assert "command" not in cfg and "url" not in cfg

    def test_ensure_relay_server_idempotent_and_isolated(self):
        from jarviscopilot_cli.browser_target import (
            ensure_playwright_relay_server, PLAYWRIGHT_RELAY_SERVER_NAME,
        )
        from jarviscopilot_cli.config import load_config
        assert ensure_playwright_relay_server("dev-9", enabled=True) is True
        assert ensure_playwright_relay_server("dev-9", enabled=True) is False
        servers = load_config().get("mcp_servers", {})
        assert servers[PLAYWRIGHT_RELAY_SERVER_NAME]["device_id"] == "dev-9"
        # flipping enabled rewrites
        assert ensure_playwright_relay_server("dev-9", enabled=False) is True


class TestToolsetOverrides:
    def test_server_target_disables_playwright_keeps_native(self):
        from jarviscopilot_cli.browser_target import (
            browser_target_toolset_overrides, PLAYWRIGHT_DESKTOP_SERVER_NAME,
        )
        _enable, disable = browser_target_toolset_overrides("server")
        assert PLAYWRIGHT_DESKTOP_SERVER_NAME in disable
        assert "browser" not in disable

    def test_desktop_target_disables_native_keeps_playwright(self):
        from jarviscopilot_cli.browser_target import (
            browser_target_toolset_overrides, PLAYWRIGHT_DESKTOP_SERVER_NAME,
        )
        enable, disable = browser_target_toolset_overrides("desktop")
        assert "browser" in disable
        assert PLAYWRIGHT_DESKTOP_SERVER_NAME in enable

    def test_apply_overrides_is_default_no_op_for_server(self):
        from jarviscopilot_cli.browser_target import apply_browser_target_gating
        # Default config (target=server, no playwright server present):
        enabled = {"browser", "web", "memory"}
        result = apply_browser_target_gating(enabled, target="server")
        assert result == {"browser", "web", "memory"}  # playwright-desktop absent → no-op

    def test_apply_overrides_desktop_drops_native_browser(self):
        from jarviscopilot_cli.browser_target import (
            apply_browser_target_gating, PLAYWRIGHT_DESKTOP_SERVER_NAME,
        )
        enabled = {"browser", "web", PLAYWRIGHT_DESKTOP_SERVER_NAME}
        result = apply_browser_target_gating(enabled, target="desktop")
        assert "browser" not in result
        assert PLAYWRIGHT_DESKTOP_SERVER_NAME in result
        assert "web" in result

    def test_apply_overrides_desktop_without_playwright_keeps_native(self):
        # Fallback-safe: if the Playwright engine isn't present, do NOT hide
        # native browser — never leave the model with zero browser tools.
        from jarviscopilot_cli.browser_target import apply_browser_target_gating
        enabled = {"browser", "web"}
        result = apply_browser_target_gating(enabled, target="desktop")
        assert "browser" in result
        assert "web" in result

    def test_server_target_also_hides_relay_engine(self):
        from jarviscopilot_cli.browser_target import (
            apply_browser_target_gating, PLAYWRIGHT_RELAY_SERVER_NAME,
        )
        enabled = {"browser", "web", PLAYWRIGHT_RELAY_SERVER_NAME}
        result = apply_browser_target_gating(enabled, target="server")
        assert PLAYWRIGHT_RELAY_SERVER_NAME not in result
        assert "browser" in result

    def test_desktop_with_only_relay_hides_native(self):
        from jarviscopilot_cli.browser_target import (
            apply_browser_target_gating, PLAYWRIGHT_RELAY_SERVER_NAME,
        )
        enabled = {"browser", "web", PLAYWRIGHT_RELAY_SERVER_NAME}
        result = apply_browser_target_gating(enabled, target="desktop")
        assert "browser" not in result
        assert PLAYWRIGHT_RELAY_SERVER_NAME in result

    def test_server_hides_auto_registered_relay(self):
        # The auto-registered relay is named playwright-relay-<id>; server must hide it.
        from jarviscopilot_cli.browser_target import apply_browser_target_gating
        enabled = {"browser", "web", "playwright-relay-afb105a1"}
        result = apply_browser_target_gating(enabled, target="server")
        assert "playwright-relay-afb105a1" not in result
        assert "browser" in result and "web" in result

    def test_desktop_with_auto_registered_relay_hides_native(self):
        from jarviscopilot_cli.browser_target import apply_browser_target_gating
        enabled = {"browser", "web", "playwright-relay-afb105a1"}
        result = apply_browser_target_gating(enabled, target="desktop")
        assert "browser" not in result
        assert "playwright-relay-afb105a1" in result

    def test_desktop_with_both_engines_prefers_relay(self):
        from jarviscopilot_cli.browser_target import (
            apply_browser_target_gating,
            PLAYWRIGHT_RELAY_SERVER_NAME, PLAYWRIGHT_DESKTOP_SERVER_NAME,
        )
        enabled = {"browser", PLAYWRIGHT_DESKTOP_SERVER_NAME, PLAYWRIGHT_RELAY_SERVER_NAME}
        result = apply_browser_target_gating(enabled, target="desktop")
        assert "browser" not in result
        assert PLAYWRIGHT_RELAY_SERVER_NAME in result
        assert PLAYWRIGHT_DESKTOP_SERVER_NAME not in result  # single surface


class TestSearchEngine:
    def test_default_and_normalization(self):
        from jarviscopilot_cli.browser_target import get_browser_search_engine
        assert get_browser_search_engine({}) == "duckduckgo"
        assert get_browser_search_engine({"browser": {"search_engine": "GOOGLE"}}) == "google"
        assert get_browser_search_engine({"browser": {"search_engine": "weird"}}) == "duckduckgo"

    def test_search_url_quotes_and_uses_engine(self):
        from jarviscopilot_cli.browser_target import browser_search_url
        url = browser_search_url("hello world", {"browser": {"search_engine": "duckduckgo"}})
        assert url.startswith("https://duckduckgo.com/?q=")
        assert "hello+world" in url

    def test_guidance_mentions_engine_google_and_screenshots(self):
        from jarviscopilot_cli.browser_target import desktop_browser_guidance
        g = desktop_browser_guidance({"browser": {"search_engine": "duckduckgo"}}).lower()
        assert "duckduckgo" in g
        assert "google" in g
        assert "screenshot" in g


class TestAutoRegister:
    def test_relay_server_name_stable_and_safe(self):
        from jarviscopilot_cli.browser_target import relay_server_name
        assert relay_server_name("2ded03c3daa94618a933ae0d955390dc") == "playwright-relay-2ded03c3"
        assert relay_server_name("") == "playwright-relay-device"
        # non-alnum stripped
        assert relay_server_name("ab-cd/ef!gh") == "playwright-relay-abcdefgh"

    def test_synthesize_skips_covered_and_builds_relay(self):
        from jarviscopilot_cli.browser_target import synthesize_relay_servers, relay_server_name
        devices = [
            {"device_id": "AAA111", "meta": {"browser": "chrome"}},
            {"device_id": "BBB222", "meta": {}},
        ]
        existing = {"hand": {"transport": "device-relay", "device_id": "AAA111"}}
        out = synthesize_relay_servers(devices, existing)
        # AAA111 already covered by a hand-written relay entry → skipped
        assert relay_server_name("AAA111") not in out
        name = relay_server_name("BBB222")
        assert name in out
        assert out[name]["transport"] == "device-relay"
        assert out[name]["device_id"] == "BBB222"
        assert out[name]["meta"]["browser"] == "chrome"  # default when meta empty
        assert out[name]["enabled"] is True

    def test_synthesize_empty_inputs(self):
        from jarviscopilot_cli.browser_target import synthesize_relay_servers
        assert synthesize_relay_servers([], {}) == {}
        assert synthesize_relay_servers(None, {}) == {}


class TestTargetPlan:
    def test_desktop_plan_provisions_without_delegating(self):
        # desktop must NOT delegate to /browser connect (that would launch a
        # second Chrome and conflict with Playwright MCP's own browser).
        from jarviscopilot_cli.browser_target import browser_target_plan
        plan = browser_target_plan("desktop")
        assert plan["target"] == "desktop"
        assert plan["delegate"] is None
        assert plan["provision_enabled"] is True

    def test_server_plan_disconnects_and_disables(self):
        from jarviscopilot_cli.browser_target import browser_target_plan
        plan = browser_target_plan("server")
        assert plan["target"] == "server"
        assert plan["delegate"] == "disconnect"
        assert plan["provision_enabled"] is False
