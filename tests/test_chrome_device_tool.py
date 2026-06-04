"""Tests for the direct chrome_* agent tools (A2 speed path)."""

import json
import sys
import types

from tools.registry import discover_builtin_tools, registry

discover_builtin_tools()  # ensure chrome_device_tool is auto-imported + registered

import tools.chrome_device_tool as cdt  # noqa: E402


def test_chrome_tools_registered():
    for n in ("chrome_navigate", "chrome_snapshot", "chrome_click",
              "chrome_type", "chrome_press_key"):
        assert registry.get_entry(n) is not None, f"{n} not registered"


def test_module_is_auto_discovered():
    assert "tools.chrome_device_tool" in discover_builtin_tools()


# ── result unwrapping ────────────────────────────────────────────────────────

def test_extract_snapshot_unwraps_nested_result():
    res = {"ok": True, "result": {"ok": True, "result": "- link x [ref=e1]"}}
    text, err = cdt._extract_snapshot(res)
    assert err is None and text == "- link x [ref=e1]"


def test_extract_snapshot_device_offline():
    text, err = cdt._extract_snapshot({"ok": False, "error": "device did not respond"})
    assert text == "" and "did not respond" in err


def test_extract_snapshot_inner_error():
    text, err = cdt._extract_snapshot({"ok": True, "result": {"ok": False, "error": "boom"}})
    assert text == "" and err == "boom"


def test_truncate_caps_large():
    big = "\n".join(f"- link {i} [ref=e{i}]" for i in range(5000))
    out = cdt._truncate(big)
    assert len(out) <= 8200


# ── call path (device resolution + invoke mocked) ────────────────────────────

def test_chrome_call_no_device(monkeypatch):
    monkeypatch.setattr(cdt, "_resolve_chrome_device", lambda: None)
    out = json.loads(cdt._chrome_call("chrome_navigate", {"url": "x"}))
    assert "error" in out and "paired" in out["error"].lower()


def test_chrome_call_success(monkeypatch):
    monkeypatch.setattr(cdt, "_resolve_chrome_device", lambda: "dev1")
    captured = {}

    def fake_invoke(dev, skill, args):
        captured.update(dev=dev, skill=skill, args=args)
        return {"ok": True, "result": {"ok": True, "result": "- heading 'Houston' [ref=e1]"}}

    monkeypatch.setattr(cdt, "invoke_skill_safe", fake_invoke)
    out = cdt._chrome_call("chrome_navigate", {"url": "https://en.wikipedia.org/wiki/Houston"})
    assert "Houston" in out
    assert captured == {"dev": "dev1", "skill": "chrome_navigate",
                        "args": {"url": "https://en.wikipedia.org/wiki/Houston"}}


def test_handlers_forward_args(monkeypatch):
    calls = []
    monkeypatch.setattr(cdt, "_chrome_call", lambda skill, args: calls.append((skill, args)) or "ok")
    cdt._h_navigate({"url": "u"})
    cdt._h_click({"element": "first", "ref": "e9"})
    cdt._h_type({"element": "box", "ref": "e3", "text": "hi", "submit": True})
    cdt._h_press_key({"key": "Enter"})
    cdt._h_snapshot({})
    assert calls == [
        ("chrome_navigate", {"url": "u"}),
        ("chrome_click", {"element": "first", "ref": "e9"}),
        ("chrome_type", {"element": "box", "ref": "e3", "text": "hi", "submit": True}),
        ("chrome_press_key", {"key": "Enter"}),
        ("chrome_snapshot", {}),
    ]


# ── device resolution + check_fn against a faked bridge ───────────────────────

def test_resolve_and_check_fn_via_bridge(monkeypatch):
    webui = types.ModuleType("webui"); webui.__path__ = []
    api = types.ModuleType("webui.api"); api.__path__ = []
    bridge = types.ModuleType("webui.api.device_bridge")
    bridge.connected_device_ids = lambda: ["mac", "phone"]
    bridge.skills_for_device = lambda d: (
        [{"name": "chrome_navigate"}, {"name": "chrome_click"}] if d == "mac"
        else [{"name": "send_sms"}]
    )
    monkeypatch.setitem(sys.modules, "webui", webui)
    monkeypatch.setitem(sys.modules, "webui.api", api)
    monkeypatch.setitem(sys.modules, "webui.api.device_bridge", bridge)
    assert cdt._resolve_chrome_device() == "mac"
    assert cdt._chrome_available() is True


def test_check_fn_false_without_bridge(monkeypatch):
    # No device bridge importable / no chrome device → tools stay hidden.
    monkeypatch.setattr(cdt, "_resolve_chrome_device", lambda: None)
    assert cdt._chrome_available() is False
