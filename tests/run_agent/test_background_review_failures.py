"""Tests for surfacing silently-dropped background-review writes."""
from __future__ import annotations

import json

from agent.background_review import summarize_background_review_failures


def _tool(tcid, **payload):
    return {"role": "tool", "tool_call_id": tcid, "content": json.dumps(payload)}


def test_collects_only_explicit_failures():
    msgs = [
        _tool("a", success=False, error="Invalid frontmatter: missing name"),
        _tool("b", success=True, message="Skill created"),
        _tool("c", success=False, error="A skill named 'x' already exists"),
        _tool("d", message="no success key — not a failure"),
    ]
    failures = summarize_background_review_failures(msgs, [])
    assert len(failures) == 2
    assert any("frontmatter" in f for f in failures)
    assert any("already exists" in f for f in failures)


def test_skips_prior_snapshot_failures():
    prior = [_tool("a", success=False, error="old rejected write")]
    msgs = prior + [_tool("b", success=False, error="new rejected write")]
    failures = summarize_background_review_failures(msgs, prior)
    assert failures == ["new rejected write"]


def test_ignores_non_tool_and_unparsable():
    msgs = [
        {"role": "assistant", "content": "hi"},
        {"role": "tool", "tool_call_id": "x", "content": "not json"},
        _tool("y", success=False, message="char limit exceeded"),
    ]
    failures = summarize_background_review_failures(msgs, [])
    assert failures == ["char limit exceeded"]
