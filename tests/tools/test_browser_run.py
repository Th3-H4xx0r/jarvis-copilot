"""browser_run: several browser steps in ONE tool call (open → fill → click → wait →
extract), so a task takes a few model turns instead of one per action."""
import json
from unittest.mock import patch

import pytest

import tools.browser_tool as bt


@pytest.fixture
def fake_browser(monkeypatch):
    log = []

    def tool(name):
        def run(*args, **kwargs):
            log.append((name, args, {k: v for k, v in kwargs.items() if k != "task_id"}))
            if name == "click" and args and args[0] == "@bad":
                return json.dumps({"success": False, "error": "element @bad not found"})
            return json.dumps({"success": True, "snapshot": "- big snapshot " * 50})
        return run

    monkeypatch.setattr(bt, "browser_navigate", tool("open"))
    monkeypatch.setattr(bt, "browser_click", tool("click"))
    monkeypatch.setattr(bt, "browser_type", tool("fill"))
    monkeypatch.setattr(bt, "browser_press", tool("press"))
    monkeypatch.setattr(bt, "browser_scroll", tool("scroll"))
    monkeypatch.setattr(bt, "browser_back", tool("back"))
    monkeypatch.setattr(bt, "browser_extract",
                        lambda instruction, url=None, schema=None, task_id=None:
                        log.append(("extract", (instruction,), {})) or
                        json.dumps({"success": True, "data": {"flights": [1, 2]}}))

    def cmd(key, command, args=None, timeout=None, _engine_override=None):
        log.append(("cmd", (command, *(args or [])), {}))
        if command == "snapshot":
            return {"success": True, "data": {"snapshot": "- heading Results\n- button Book [ref=e9]"}}
        return {"success": True, "data": {}}

    monkeypatch.setattr(bt, "_run_browser_command", cmd)
    monkeypatch.setattr(bt, "_last_session_key", lambda tid: tid or "default")
    return log


def test_steps_run_in_order_in_one_call(fake_browser):
    out = json.loads(bt.browser_run([
        {"action": "open", "url": "https://flights.example"},
        {"action": "fill", "ref": "@e3", "text": "SFO"},
        {"action": "press", "key": "Enter"},
        {"action": "wait_for", "text": "Results"},
        {"action": "extract", "instruction": "every flight with price"},
    ], task_id="t1"))
    assert out["success"] and [s["action"] for s in out["steps"]] == ["open", "fill", "press", "wait_for", "extract"]
    assert out["steps"][-1]["data"] == {"flights": [1, 2]}
    assert ("cmd", ("wait", "--text", "Results"), {}) in fake_browser
    # Step results stay small: no snapshots copied per step.
    assert "big snapshot" not in json.dumps(out["steps"])


def test_the_first_failure_stops_and_shows_where_it_is(fake_browser):
    out = json.loads(bt.browser_run([
        {"action": "open", "url": "https://flights.example"},
        {"action": "click", "ref": "@bad"},
        {"action": "press", "key": "Enter"},
    ], task_id="t2"))
    assert not out["success"] and out["failed_step"] == 1
    assert "not found" in out["steps"][1]["error"] and len(out["steps"]) == 2
    assert "button Book" in out["snapshot"]              # a compact look at the page to recover from


def test_waits_map_to_the_browser(fake_browser):
    bt.browser_run([{"action": "wait_for", "selector": "#results"},
                    {"action": "wait_for", "load": "networkidle"},
                    {"action": "wait_for", "ms": 800}], task_id="t3")
    cmds = [e[1] for e in fake_browser if e[0] == "cmd" and e[1][0] == "wait"]
    assert cmds == [("wait", "#results"), ("wait", "--load", "networkidle"), ("wait", "800")]


def test_unknown_actions_and_empty_runs_are_refused(fake_browser):
    assert not json.loads(bt.browser_run([], task_id="t4"))["success"]
    out = json.loads(bt.browser_run([{"action": "teleport"}], task_id="t4"))
    assert not out["success"] and "teleport" in out["steps"][0]["error"]


def test_it_is_a_browser_tool_in_every_browser_toolset():
    import toolsets
    assert "browser_run" in bt._BROWSER_SCHEMA_MAP
    assert all("browser_run" in ts["tools"] for name, ts in toolsets.TOOLSETS.items()
               if "browser_navigate" in ts.get("tools", []))


def test_chrome_pages_load_light_once_per_session(monkeypatch):
    sent = []
    monkeypatch.setattr(bt, "_run_browser_command",
                        lambda key, command, args=None, timeout=None, _engine_override=None:
                        sent.append((key, command, tuple(args or []))) or {"success": True})
    bt._active_sessions["c1"] = {"session_name": "h_c1", "engine": "chrome"}
    bt._active_sessions["lp1"] = {"session_name": "h_lp1", "engine": "lightpanda", "cdp_url": "http://127.0.0.1:9"}
    try:
        bt._ensure_light_loads("c1")
        bt._ensure_light_loads("c1")
        bt._ensure_light_loads("lp1")
    finally:
        bt._active_sessions.pop("c1", None)
        bt._active_sessions.pop("lp1", None)
    routes = [s for s in sent if s[1] == "network"]
    assert routes and all(s[0] == "c1" and s[2][0] == "route" and "--abort" in s[2] for s in routes)
    assert len(routes) == len(bt._LIGHT_LOAD_PATTERNS)       # once, not per navigation
    assert not any(".png" in " ".join(s[2]) for s in routes)  # images stay for screenshots/vision
