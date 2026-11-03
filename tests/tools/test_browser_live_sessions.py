"""Live browser sessions (2026-11-03): the chat's browser card, the move of an
interactive task to the cloud browser, take-over, and the card's row.

Pranav's picks: reads stay on Lightpanda; the first interactive call moves the task
to the cloud browser (Steel) at the same URL so he can watch it; "Run on cloud
browser" moves it on the next call of any kind; while he has taken over, browser
calls wait and then tell the model to re-snapshot.
"""
import json
from typing import Any, Dict, List

import pytest

import tools.browser_tool as bt
from tools import browser_recorder, browser_sessions


class _FakeProvider:
    name = "steel"
    display_name = "Steel"

    def __init__(self):
        self.created: List[str] = []
        self.closed: List[str] = []

    def is_available(self):
        return True

    def create_session(self, task_id):
        self.created.append(task_id)
        return {
            "session_name": f"steel_{task_id}",
            "bb_session_id": "steel-sess-1",
            "cdp_url": "wss://connect.steel.dev?apiKey=k&sessionId=steel-sess-1",
            "features": {"steel": True},
            "live_url": "https://api.steel.dev/v1/sessions/steel-sess-1/player?interactive=false",
            "live_interactive_url": "https://api.steel.dev/v1/sessions/steel-sess-1/player?interactive=true",
        }

    def close_session(self, sid):
        self.closed.append(sid)
        return True


@pytest.fixture
def live(monkeypatch):
    """A Lightpanda task with a fake agent-browser and a ready Steel provider."""
    calls: List[Dict[str, Any]] = []
    pages = {"url": "about:blank", "title": ""}

    def fake_run(session_key, command, args=None, timeout=None, _engine_override=None):
        args = args or []
        calls.append({"key": session_key, "command": command, "args": list(args)})
        bt._get_session_info(session_key)
        if command == "open":
            pages["url"], pages["title"] = args[0], "Example Domain"
            return {"success": True, "data": {"url": args[0], "title": "Example Domain"}}
        if command == "snapshot":
            return {"success": True, "data": {"snapshot": f"- button \"Sign in\" [ref=e1] ({session_key})",
                                               "refs": {"e1": {}}}}
        if command == "eval":
            if args and args[0].startswith("JSON.stringify"):
                return {"success": True, "data": {"result": json.dumps([pages["url"], pages["title"]])}}
            return {"success": True, "data": {"result": pages["url"]}}
        if command in ("click", "fill", "press", "scroll", "close"):
            return {"success": True, "data": {}}
        return {"success": False, "error": f"unexpected {command}"}

    provider = _FakeProvider()
    attached: List[tuple] = []
    monkeypatch.setattr(bt, "_run_browser_command", fake_run)
    monkeypatch.setattr(bt, "_ensure_cdp_supervisor", lambda key: None)
    monkeypatch.setattr(bt, "_start_browser_cleanup_thread", lambda: None)
    monkeypatch.setattr(bt, "_get_cloud_provider", lambda: None)
    monkeypatch.setattr(bt, "_get_cdp_override", lambda: "")
    monkeypatch.setattr(bt, "_is_camofox_mode", lambda: False)
    monkeypatch.setattr(bt, "_get_browser_engine", lambda: "lightpanda")
    monkeypatch.setattr(bt, "_url_is_private", lambda url: "192.168." in url or "localhost" in url)
    monkeypatch.setattr(bt, "_create_engine_local_session", lambda key: {
        "session_name": "h_lp", "bb_session_id": None, "cdp_url": "ws://127.0.0.1:9222/devtools/browser/lp",
        "engine": "lightpanda", "features": {"local": True, "lightpanda": True}})
    monkeypatch.setattr(browser_sessions, "live_provider", lambda: provider)
    monkeypatch.setattr(bt, "_registry_get_browser_provider", lambda name: provider if name == "steel" else None)
    monkeypatch.setattr(browser_sessions, "cloud_for_interactive", lambda: True)
    monkeypatch.setattr(browser_recorder, "attach", lambda sid, url: attached.append((sid, url)))
    monkeypatch.setattr(browser_recorder, "is_recording", lambda sid: any(a[0] == sid for a in attached))
    monkeypatch.setattr(browser_recorder, "finish", lambda sid, background=True: attached.append((sid, "finish")))
    monkeypatch.setattr(bt, "_active_sessions", {})
    monkeypatch.setattr(bt, "_last_active_session_key", {})
    monkeypatch.setattr(bt, "_session_last_activity", {})
    return {"calls": calls, "provider": provider, "attached": attached}


def _call(name, args, task="chat1"):
    entry = bt.registry.get_entry(name)
    return json.loads(entry.handler(args, task_id=task))


def test_every_result_carries_the_card_first(live):
    out = _call("browser_navigate", {"url": "https://example.com"})
    assert list(out)[0] == "card"
    assert out["card"]["kind"] == "browser_session" and out["card"]["session"].startswith("b_")
    view = browser_sessions.view(out["card"]["session"])
    assert view["engine"] == "lightpanda" and view["url"] == "https://example.com"
    assert view["title"] == "Example Domain" and view["status"] == "running"
    # the same task keeps one session id across calls
    again = _call("browser_snapshot", {})
    assert again["card"]["session"] == out["card"]["session"]


def test_reads_never_move_to_the_cloud(live):
    _call("browser_navigate", {"url": "https://example.com"})
    _call("browser_snapshot", {})
    _call("browser_scroll", {"direction": "down"})
    assert live["provider"].created == []
    assert not any(c["key"].endswith("::cloud") for c in live["calls"])


def test_first_interactive_call_moves_the_task_to_the_cloud_at_the_same_url(live):
    nav = _call("browser_navigate", {"url": "https://example.com/login"})
    sid = nav["card"]["session"]
    out = _call("browser_click", {"ref": "@e1"})
    assert out["moved_to_cloud"] is True and out["success"] is False
    assert "repeat the action" in out["error"] and "::cloud" in out["snapshot"]
    assert live["provider"].created == ["chat1"]
    opens = [c for c in live["calls"] if c["key"] == "chat1::cloud" and c["command"] == "open"]
    assert opens and opens[0]["args"] == ["https://example.com/login"]
    # nothing was clicked on either browser
    assert not any(c["command"] == "click" for c in live["calls"])
    view = browser_sessions.view(sid)
    assert view["engine"] == "cloud" and view["provider"] == "steel" and view["provider_name"] == "Steel"
    assert view["live_url"].endswith("interactive=false") and view["live_interactive_url"]
    assert view["can_move_to_cloud"] is False
    assert live["attached"] and live["attached"][0][1].startswith("wss://connect.steel.dev")
    # the Lightpanda browser was closed; the next click runs on the cloud
    assert "chat1" not in bt._active_sessions
    again = _call("browser_click", {"ref": "@e1"})
    assert again["success"] is True and again["card"]["session"] == sid
    assert [c["key"] for c in live["calls"] if c["command"] == "click"] == ["chat1::cloud"]


def test_navigation_after_the_move_stays_on_the_cloud(live):
    _call("browser_navigate", {"url": "https://example.com"})
    _call("browser_type", {"ref": "@e1", "text": "hi"})
    _call("browser_navigate", {"url": "https://example.org"})
    assert [c["key"] for c in live["calls"] if c["command"] == "open"][-1] == "chat1::cloud"


def test_switch_off_keeps_interactive_calls_local(live, monkeypatch):
    monkeypatch.setattr(browser_sessions, "cloud_for_interactive", lambda: False)
    _call("browser_navigate", {"url": "https://example.com"})
    out = _call("browser_click", {"ref": "@e1"})
    assert out["success"] is True and live["provider"].created == []


def test_run_on_cloud_moves_on_the_next_call_of_any_kind(live):
    nav = _call("browser_navigate", {"url": "https://example.com"})
    sid = nav["card"]["session"]
    browser_sessions.request_move(sid)
    out = _call("browser_snapshot", {})
    assert out["success"] is True and "::cloud" in out["snapshot"]
    assert "moved to the cloud browser" in out["browser_note"]
    assert browser_sessions.view(sid)["move_requested"] is False


def test_private_pages_stay_local(live):
    nav = _call("browser_navigate", {"url": "http://192.168.1.5/admin"})
    browser_sessions.request_move(nav["card"]["session"])
    out = _call("browser_click", {"ref": "@e1"})
    assert out["success"] is True and live["provider"].created == []


def test_no_cloud_browser_set_up_means_no_move(live, monkeypatch):
    monkeypatch.setattr(browser_sessions, "live_provider", lambda: None)
    _call("browser_navigate", {"url": "https://example.com"})
    assert _call("browser_click", {"ref": "@e1"})["success"] is True


def test_move_requested_before_any_page_starts_the_task_on_the_cloud(live):
    sid = browser_sessions.ensure("chat2")
    browser_sessions.request_move(sid)
    out = _call("browser_navigate", {"url": "https://example.com"}, task="chat2")
    assert out["card"]["session"] == sid
    assert [c["key"] for c in live["calls"] if c["command"] == "open"] == ["chat2::cloud"]
    assert browser_sessions.view(sid)["engine"] == "cloud"


def test_takeover_waits_then_tells_the_model_to_resnapshot(live, monkeypatch):
    nav = _call("browser_navigate", {"url": "https://example.com"})
    sid = nav["card"]["session"]
    _call("browser_type", {"ref": "@e1", "text": "x"})          # → cloud
    browser_sessions.set_takeover(sid, True)
    polls = {"n": 0}

    def fake_sleep(_s):
        polls["n"] += 1
        if polls["n"] == 3:
            browser_sessions.set_takeover(sid, False)

    monkeypatch.setattr(bt.time, "sleep", fake_sleep)
    out = _call("browser_click", {"ref": "@e1"})
    assert out["success"] is False and out["handed_back"] is True
    assert "fresh snapshot" in out["error"]
    assert polls["n"] == 3
    snap = _call("browser_snapshot", {})
    assert snap["success"] is True


def test_takeover_snapshot_runs_with_a_note(live, monkeypatch):
    nav = _call("browser_navigate", {"url": "https://example.com"})
    sid = nav["card"]["session"]
    _call("browser_type", {"ref": "@e1", "text": "x"})
    browser_sessions.set_takeover(sid, True)
    monkeypatch.setattr(bt.time, "sleep", lambda _s: browser_sessions.set_takeover(sid, False))
    out = _call("browser_snapshot", {})
    assert out["success"] is True and "handed it back" in out["browser_note"]


def test_takeover_gives_up_after_ten_minutes(live, monkeypatch):
    nav = _call("browser_navigate", {"url": "https://example.com"})
    sid = nav["card"]["session"]
    browser_sessions.set_takeover(sid, True)
    monkeypatch.setattr(bt, "TAKEOVER_MAX_WAIT_S", 0)
    out = _call("browser_click", {"ref": "@e1"})
    assert out["success"] is False and "still has the browser" in out["error"]


def test_closing_the_task_ends_the_card_and_finishes_the_replay(live):
    nav = _call("browser_navigate", {"url": "https://example.com"})
    sid = nav["card"]["session"]
    _call("browser_click", {"ref": "@e1"})
    bt.cleanup_browser("chat1")
    assert browser_sessions.view(sid)["status"] == "ended"
    assert (sid, "finish") in live["attached"]
    assert live["provider"].closed == ["steel-sess-1"]
    # the next browser call of the task is a new session
    nxt = _call("browser_navigate", {"url": "https://example.com"})
    assert nxt["card"]["session"] != sid


def test_a_taken_over_cloud_browser_survives_the_turn_ending(live):
    nav = _call("browser_navigate", {"url": "https://example.com"})
    sid = nav["card"]["session"]
    _call("browser_click", {"ref": "@e1"})
    browser_sessions.set_takeover(sid, True)
    bt.cleanup_browser("chat1")
    assert "chat1::cloud" in bt._active_sessions
    assert browser_sessions.view(sid)["status"] == "running"


def test_explicit_live_setup_keeps_tasks_starting_locally(monkeypatch):
    """With browser.cloud_for_interactive in config.yaml the cloud provider is kept
    for moved sessions; a fresh task does not start on it."""
    import jarviscopilot_cli.config as cfg_mod
    monkeypatch.setattr(cfg_mod, "read_raw_config", lambda: {
        "browser": {"cloud_provider": "steel", "cloud_for_interactive": True}})
    monkeypatch.setattr(bt, "_cloud_provider_resolved", False)
    monkeypatch.setattr(bt, "_cached_cloud_provider", None)
    assert bt._get_cloud_provider() is None
