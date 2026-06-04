"""Tests for the A2 browser device skills (chrome_*)."""

import asyncio
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


def test_chrome_navigate_navigates_then_snapshots(monkeypatch):
    calls = []
    monkeypatch.setattr(bm._INSTANCE, "call_tool",
                        lambda name, args=None, **kw: calls.append((name, args)) or {"ok": True, "result": "x"})
    out = sk.invoke("chrome_navigate", {"url": "https://example.com"})
    # navigate, then an EXPLICIT inline snapshot so browser_mcp's size cap applies
    # (Playwright's own post-navigate snapshot can be saved to a file the agent
    # would otherwise read raw).
    assert calls == [("browser_navigate", {"url": "https://example.com"}),
                     ("browser_snapshot", {})]
    assert out == {"ok": True, "result": "x"}


def test_chrome_click_maps_ref_to_target_then_snapshots(monkeypatch):
    # Playwright MCP >=0.0.75 takes the snapshot ref as `target`, not `ref`.
    calls = []
    monkeypatch.setattr(bm._INSTANCE, "call_tool",
                        lambda name, args=None, **kw: calls.append((name, args)) or {"ok": True})
    sk.invoke("chrome_click", {"element": "first result", "ref": "e47"})
    assert calls == [("browser_click", {"element": "first result", "target": "e47"}),
                     ("browser_snapshot", {})]


def test_snapshot_depth_env(monkeypatch):
    import jc_client.skills.browser as br
    monkeypatch.delenv("JC_BROWSER_SNAPSHOT_DEPTH", raising=False)
    assert br._snapshot_args() == {}
    monkeypatch.setenv("JC_BROWSER_SNAPSHOT_DEPTH", "12")
    assert br._snapshot_args() == {"depth": 12}
    monkeypatch.setenv("JC_BROWSER_SNAPSHOT_DEPTH", "0")
    assert br._snapshot_args() == {}


def test_chrome_type_submit_flag(monkeypatch):
    calls = []
    monkeypatch.setattr(bm._INSTANCE, "call_tool",
                        lambda name, args=None, **kw: calls.append((name, args)) or {"ok": True})
    sk.invoke("chrome_type", {"element": "search", "ref": "e3", "text": "houston", "submit": True})
    assert calls[0] == ("browser_type", {"element": "search", "target": "e3", "text": "houston", "submit": True})
    # without submit, the flag is omitted
    calls.clear()
    sk.invoke("chrome_type", {"element": "search", "ref": "e3", "text": "x"})
    assert calls[0] == ("browser_type", {"element": "search", "target": "e3", "text": "x"})


# ── snapshot truncation (the 325k-token fix) ─────────────────────────────────

def test_truncate_snapshot_unchanged_under_cap():
    assert bm._truncate_snapshot("- link a\n- link b", 1000) == "- link a\n- link b"


def test_truncate_snapshot_caps_large_tree():
    big = "\n".join(f'- link "item {i}" [ref=e{i}]' for i in range(5000))
    out = bm._truncate_snapshot(big, 2000)
    assert len(out) <= 2000
    assert "truncated to save context" in out
    # never split an accessibility node mid-line
    body = out.split("\n[... ")[0]
    for line in body.splitlines():
        assert line == "" or line.startswith('- link "item ')


def test_truncate_snapshot_disabled_with_zero():
    big = "x" * 50000
    assert bm._truncate_snapshot(big, 0) == big


def test_snapshot_max_chars_env_override(monkeypatch):
    monkeypatch.setenv("JC_BROWSER_SNAPSHOT_MAX_CHARS", "1234")
    assert bm._snapshot_max_chars() == 1234
    monkeypatch.setenv("JC_BROWSER_SNAPSHOT_MAX_CHARS", "not-a-number")
    assert bm._snapshot_max_chars() == bm._SNAPSHOT_MAX_CHARS_DEFAULT
    monkeypatch.delenv("JC_BROWSER_SNAPSHOT_MAX_CHARS", raising=False)
    assert bm._snapshot_max_chars() == bm._SNAPSHOT_MAX_CHARS_DEFAULT


def test_call_applies_snapshot_cap(monkeypatch):
    # _call must cap whatever the Playwright tool returns, so a huge accessibility
    # tree can't dump 100k+ tokens into the agent's context.
    class _Content:
        def __init__(self, text):
            self.text = text

    class _Result:
        def __init__(self, text):
            self.content = [_Content(text)]
            self.isError = False

    class _Session:
        async def call_tool(self, name, args):
            return _Result('- link "x" [ref=e1]\n' * 10000)

    monkeypatch.setenv("JC_BROWSER_SNAPSHOT_MAX_CHARS", "3000")
    inst = bm._BrowserMcp()
    inst._session = _Session()
    out = asyncio.run(inst._call("browser_snapshot", {}))
    assert out["ok"] is True
    assert len(out["result"]) <= 3000
    assert "truncated to save context" in out["result"]
