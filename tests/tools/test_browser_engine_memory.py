"""Lightpanda first, Chrome when a site needs it (fast web browsing, 2026-10-11).

Lightpanda runs as a per-task CDP process (`lightpanda serve`) that agent-browser
drives with --cdp; a site whose page breaks on it — or that is known to need a real
renderer (Google Flights) — is remembered, and that task continues on a Chrome
session at the same URL. Next time the site starts on Chrome directly."""
from unittest.mock import patch

import pytest

import tools.browser_tool as bt
from tools import browser_engine_sites as sites


@pytest.fixture(autouse=True)
def _clean(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    bt._active_sessions.clear()
    bt._last_active_session_key.clear()
    yield
    bt._active_sessions.clear()
    bt._last_active_session_key.clear()


def _lightpanda_engine():
    return patch.multiple(bt, _get_browser_engine=lambda: "lightpanda", _get_cdp_override=lambda: "",
                          _get_cloud_provider=lambda: None, _is_camofox_mode=lambda: False)


# ── per-site memory ──────────────────────────────────────────────────────────

def test_a_site_that_broke_is_remembered():
    assert not sites.needs_chrome("https://www.example.com/a")
    sites.remember_chrome("https://www.example.com/a", "empty snapshot")
    assert sites.needs_chrome("https://example.com/other")          # www. is the same site
    assert not sites.needs_chrome("https://example.org/")


def test_known_heavy_pages_start_on_chrome():
    assert sites.needs_chrome("https://www.google.com/travel/flights?q=HOU+SFO")
    assert not sites.needs_chrome("https://www.google.com/search?q=x")


def test_memory_expires_after_two_weeks():
    sites.remember_chrome("https://slow.example/", "x", now=1_000_000)
    assert sites.needs_chrome("https://slow.example/", now=1_000_000 + 13 * 86400)
    assert not sites.needs_chrome("https://slow.example/", now=1_000_000 + 15 * 86400)


# ── routing ──────────────────────────────────────────────────────────────────

def test_a_chrome_site_gets_the_chrome_session():
    sites.remember_chrome("https://heavy.example/", "x")
    with _lightpanda_engine():
        assert bt._navigation_session_key("t1", "https://heavy.example/p") == "t1::chrome"
        assert bt._navigation_session_key("t1", "https://light.example/") == "t1"
    with patch.object(bt, "_get_browser_engine", lambda: "chrome"):
        assert bt._navigation_session_key("t1", "https://heavy.example/p") == "t1"


def test_the_lightpanda_session_is_a_local_cdp_process():
    from tools import lightpanda_local
    with _lightpanda_engine(), \
            patch.object(lightpanda_local, "available", lambda: True), \
            patch.object(lightpanda_local, "start", lambda key: {"cdp_url": "http://127.0.0.1:9555", "pid": 4242}), \
            patch.object(bt, "_ensure_cdp_supervisor", lambda key: None):
        info = bt._get_session_info("t2")
    assert info["cdp_url"] == "http://127.0.0.1:9555" and info["engine"] == "lightpanda"
    assert info["lightpanda_pid"] == 4242


def test_lightpanda_that_will_not_start_falls_back_to_chrome():
    from tools import lightpanda_local

    def boom(key):
        raise RuntimeError("no binary")

    with _lightpanda_engine(), patch.object(lightpanda_local, "available", lambda: True), \
            patch.object(lightpanda_local, "start", boom):
        info = bt._get_session_info("t3")
    assert not info.get("cdp_url") and info["engine"] == "chrome"


def test_the_chrome_session_runs_chrome_not_the_configured_engine():
    with _lightpanda_engine():
        info = bt._get_session_info("t4::chrome")
        assert info["engine"] == "chrome" and not info.get("cdp_url")
        assert bt._engine_args(info, None) == ["--engine", "chrome"]
        assert bt._engine_args({"cdp_url": "http://127.0.0.1:1", "engine": "lightpanda"}, None) == []


# ── switching mid-task ───────────────────────────────────────────────────────

def test_a_lightpanda_failure_moves_the_task_to_chrome_at_the_same_url():
    calls = []

    def fake(key, command, args=None, timeout=None, _engine_override=None):
        calls.append((key, command, list(args or [])))
        if command == "eval":
            return {"success": True, "data": {"result": "https://heavy.example/results"}}
        return {"success": True, "data": {"snapshot": "- heading Results" if command == "snapshot" else ""}}

    with _lightpanda_engine(), patch.object(bt, "_run_browser_command", fake):
        out = bt._switch_task_to_chrome("t5", "snapshot", [], 30, "Lightpanda returned an empty snapshot")
    assert calls[0] == ("t5", "eval", ["window.location.href"])
    assert ("t5::chrome", "open", ["https://heavy.example/results"]) in calls
    assert calls[-1][:2] == ("t5::chrome", "snapshot")
    assert bt._last_active_session_key["t5"] == "t5::chrome"
    assert sites.needs_chrome("https://heavy.example/")
    assert out["browser_engine_fallback"]["to"] == "chrome"


def test_cleanup_stops_the_lightpanda_process_and_the_chrome_session():
    from tools import lightpanda_local
    stopped = []
    bt._active_sessions["t6"] = {"session_name": "h_t6", "cdp_url": "http://127.0.0.1:9", "engine": "lightpanda",
                                 "lightpanda_pid": 777}
    bt._active_sessions["t6::chrome"] = {"session_name": "h_t6c", "engine": "chrome"}
    with patch.object(lightpanda_local, "stop", lambda pid: stopped.append(pid)), \
            patch.object(bt, "_run_browser_command", lambda *a, **k: {"success": True}), \
            patch.object(bt, "_stop_cdp_supervisor", lambda key: None):
        bt.cleanup_browser("t6")
    assert stopped == [777] and not bt._active_sessions


def test_the_agent_can_ask_for_chrome_on_a_page_that_looks_incomplete():
    with _lightpanda_engine():
        bt._apply_engine_request("https://app.heavy.example/search", "chrome")
        assert bt._navigation_session_key("t7", "https://app.heavy.example/other") == "t7::chrome"
        bt._apply_engine_request("https://fine.example/", None)
        assert bt._navigation_session_key("t7", "https://fine.example/") == "t7"
    assert "engine" in bt._BROWSER_SCHEMA_MAP["browser_navigate"]["parameters"]["properties"]
