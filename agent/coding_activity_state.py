"""Classify a Claude Code tmux pane into a live "activity state".

This is the SOURCE OF TRUTH for the heuristics. The desktop client replicates
``classify_pane`` verbatim in ``desktop_client/jc_client/coding_discover.py``
(the client process can't import ``agent/``) — keep the two in sync.

States:
  - ``working`` — Claude is actively processing (a spinner / "esc to interrupt").
  - ``waiting`` — Claude is blocked on the user (a permission / choice prompt).
  - ``idle``    — at rest at the prompt with nothing pending.

Precedence is WAITING > WORKING > IDLE: a permission box can still render a
spinner frame underneath it, and "blocked on the user" is the more important
signal to surface.
"""
from __future__ import annotations

import re

# A permission / numbered-choice prompt. These strings are specific to Claude
# Code's confirmation UI ("Do you want to proceed?" + a "❯ 1. Yes" list) so they
# don't fire on ordinary assistant prose.
_WAITING_MARKERS = (
    "do you want to proceed",
    "do you want to run",
    "do you want to make this edit",
    "do you want to create",
    "do you want to delete",
    "❯ 1.",
    "1. yes",
    "(y/n)",
    "press enter to continue",
)

# Claude shows "esc to interrupt" on its status line whenever it is running a
# turn or a tool (in every permission mode), so it is the reliable "working"
# signal. We deliberately do NOT key off bare spinner glyphs alone (the splash
# screen uses one), to avoid false positives on an idle session.
_WORKING_MARKERS = (
    "esc to interrupt",
    "esc to stop",
    "ctrl+b to run in background",
)

# The live "spinner" status line — a parenthesized elapsed time followed by a
# middot, e.g. "(35s · ↑ 2.4k tokens · …)". Present in BOTH standard Claude Code
# and custom forks (whose verb/suffix differ but this prefix doesn't), so it's
# the robust "actively working" signal — more reliable than the "esc to
# interrupt" hint, which some forks omit.
_WORKING_SPINNER_RE = re.compile(r"\(\d[\dhms\s]*·")


def classify_pane(text: str) -> str:
    """Return ``"working" | "waiting" | "idle"`` for a captured tmux pane."""
    if not text:
        return "idle"
    low = text.lower()
    if any(m in low for m in _WAITING_MARKERS):
        return "waiting"
    if any(m in low for m in _WORKING_MARKERS) or _WORKING_SPINNER_RE.search(text):
        return "working"
    return "idle"
