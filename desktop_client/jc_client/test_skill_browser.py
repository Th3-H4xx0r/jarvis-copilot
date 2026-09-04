"""Tests for the chrome_* browser skills' shared ``_act_then_snapshot``
helper (skills/browser.py).

``browser_mcp.call_tool``/``start()`` return an error dict instead of
raising (plan 3.5's cold-start-budget rework — see test_browser_mcp_restart.py).
``_act_then_snapshot`` used to ignore the action call's return value and
always follow it with a ``browser_snapshot`` call, which meant:

- a cold/dead child's error was silently swallowed and a (stale or equally
  erroring) snapshot returned as if the action had worked;
- a cold child paid the ``_COLD_START_BUDGET`` (8s) wait TWICE — once for the
  action, once for the immediately-following snapshot.

These tests use a fake ``browser_mcp()`` so no real Playwright/npx child is
ever started.

Run from the ``desktop_client`` directory:
    python3 -m pytest jc_client/test_skill_browser.py -q
"""
from __future__ import annotations

import pytest

from jc_client.skills import browser as browser_skill


class _FakeMcp:
    """Records calls and returns scripted results, one per call_tool name."""

    def __init__(self, results_by_name: dict[str, dict]):
        self._results = results_by_name
        self.calls: list[tuple[str, dict]] = []

    def call_tool(self, name: str, args: dict) -> dict:
        self.calls.append((name, args))
        return self._results[name]


@pytest.fixture(autouse=True)
def _no_env_depth(monkeypatch):
    # Keep _snapshot_args() deterministic across environments.
    monkeypatch.delenv("JC_BROWSER_SNAPSHOT_DEPTH", raising=False)


def test_successful_action_is_followed_by_one_snapshot(monkeypatch):
    fake = _FakeMcp({
        "browser_navigate": {"ok": True, "result": "navigated"},
        "browser_snapshot": {"ok": True, "result": "<tree>"},
    })
    monkeypatch.setattr(browser_skill, "browser_mcp", lambda: fake)

    result = browser_skill._act_then_snapshot("browser_navigate", {"url": "https://x"})

    assert result == {"ok": True, "result": "<tree>"}
    assert [name for name, _ in fake.calls] == ["browser_navigate", "browser_snapshot"]


def test_cold_start_error_short_circuits_before_snapshot(monkeypatch):
    """The action itself reports the browser is still warming up — the
    skill must hand that back immediately, with NO second call_tool for
    browser_snapshot (i.e. at most the action's own single cold-start wait,
    never a second one stacked on top)."""
    fake = _FakeMcp({
        "browser_navigate": {"ok": False, "error": "browser warming up, retry"},
        "browser_snapshot": {"ok": True, "result": "<tree>"},  # must NOT be reached
    })
    monkeypatch.setattr(browser_skill, "browser_mcp", lambda: fake)

    result = browser_skill._act_then_snapshot("browser_navigate", {"url": "https://x"})

    assert result == {"ok": False, "error": "browser warming up, retry"}
    assert [name for name, _ in fake.calls] == ["browser_navigate"]


def test_action_iserror_short_circuits_before_snapshot(monkeypatch):
    """Not just the cold-start case — any action failure (ok: False from a
    real Playwright isError result) must also skip the snapshot rather than
    reporting success against a page the action never touched."""
    fake = _FakeMcp({
        "browser_click": {"ok": False, "result": "element not found"},
        "browser_snapshot": {"ok": True, "result": "<tree>"},  # must NOT be reached
    })
    monkeypatch.setattr(browser_skill, "browser_mcp", lambda: fake)

    result = browser_skill._act_then_snapshot("browser_click", {"element": "x", "target": "e1"})

    assert result == {"ok": False, "result": "element not found"}
    assert [name for name, _ in fake.calls] == ["browser_click"]


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
