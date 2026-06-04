"""Tests for the A2 browser device skills (chrome_*)."""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "desktop_client"))

from jc_client import skills as sk  # noqa: E402
import jc_client.skills.browser  # noqa: E402,F401 — registers chrome_* skills
import jc_client.browser_mcp as bm  # noqa: E402


def test_chrome_skills_registered():
    names = sk.registered_names()
    for n in ("chrome_navigate", "chrome_snapshot", "chrome_click", "chrome_type", "chrome_press_key"):
        assert n in names, f"{n} not registered"


def test_manifest_includes_chrome_with_schemas():
    m = {s["name"]: s for s in sk.all_manifest()}
    assert "chrome_navigate" in m
    assert m["chrome_navigate"]["input_schema"]["required"] == ["url"]
    assert "real" in m["chrome_navigate"]["description"].lower()


def test_chrome_navigate_forwards_to_playwright_tool(monkeypatch):
    calls = []
    monkeypatch.setattr(bm._INSTANCE, "call_tool",
                        lambda name, args=None, **kw: calls.append((name, args)) or {"ok": True, "result": "x"})
    out = sk.invoke("chrome_navigate", {"url": "https://example.com"})
    assert calls == [("browser_navigate", {"url": "https://example.com"})]
    assert out == {"ok": True, "result": "x"}


def test_chrome_click_forwards_element_and_ref(monkeypatch):
    calls = []
    monkeypatch.setattr(bm._INSTANCE, "call_tool",
                        lambda name, args=None, **kw: calls.append((name, args)) or {"ok": True})
    sk.invoke("chrome_click", {"element": "first result", "ref": "e47"})
    assert calls == [("browser_click", {"element": "first result", "ref": "e47"})]


def test_chrome_type_submit_flag(monkeypatch):
    calls = []
    monkeypatch.setattr(bm._INSTANCE, "call_tool",
                        lambda name, args=None, **kw: calls.append((name, args)) or {"ok": True})
    sk.invoke("chrome_type", {"element": "search", "ref": "e3", "text": "houston", "submit": True})
    assert calls[0] == ("browser_type", {"element": "search", "ref": "e3", "text": "houston", "submit": True})
    # without submit, the flag is omitted
    calls.clear()
    sk.invoke("chrome_type", {"element": "search", "ref": "e3", "text": "x"})
    assert calls[0] == ("browser_type", {"element": "search", "ref": "e3", "text": "x"})
