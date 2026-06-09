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

# How many lines from the BOTTOM of the pane hold the LIVE UI — the active popup
# / permission box / spinner / input prompt. We classify from this tail ONLY, so a
# marker that merely appears in claude's SCROLLBACK output (claude printing the
# words "esc to cancel" while discussing a UI, or ECHOING a user's numbered
# message like "❯ 2. do the thing") can't be mistaken for a live prompt. A real
# popup's footer is the last content line, and a permission box's prompt sits ~5
# lines from the bottom, so this comfortably covers both.
_TAIL_LINES = 15

# A prompt that is BLOCKED on the user. Two shapes:
#   • the permission-confirmation box ("Do you want to proceed?" + a yes/no list);
#   • the interactive SELECTION popup (AskUserQuestion / multiple-choice), whose
#     footer "Enter to select · ↑/↓ to navigate · Esc to cancel" is the reliable
#     signal — present ONLY while the prompt is live.
# We deliberately do NOT key off the "❯" cursor glyph: it also marks the input
# prompt, an echoed user message, and any numbered list in claude's own output,
# so it produced false "waiting" (e.g. jarvis-copilot reading waiting while it was
# actually working). The footer/box phrases are specific to a live prompt.
_WAITING_MARKERS = (
    "do you want to proceed",
    "do you want to run",
    "do you want to make this edit",
    "do you want to create",
    "do you want to delete",
    "would you like to proceed",   # ExitPlanMode-style approval
    "(y/n)",
    "press enter to continue",
    "esc to cancel",       # selection-popup footer ("… · Esc to cancel")
    "enter to select",     # selection-popup footer ("Enter to select · …")
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


def _live_tail(text: str) -> str:
    """The bottom ``_TAIL_LINES`` lines of the pane, with tmux's trailing blank
    padding stripped — the region that holds the LIVE UI."""
    lines = text.splitlines()
    while lines and not lines[-1].strip():
        lines.pop()
    return "\n".join(lines[-_TAIL_LINES:])


def classify_pane(text: str) -> str:
    """Return ``"working" | "waiting" | "idle"`` for a captured tmux pane."""
    if not text:
        return "idle"
    # WAITING is detected from the live TAIL only — its markers (popup footer,
    # "do you want to…") can also appear in claude's scrollback OUTPUT or an
    # echoed user message, so scoping to the bottom avoids a false "waiting".
    if any(m in _live_tail(text).lower() for m in _WAITING_MARKERS):
        return "waiting"
    # WORKING is detected from the WHOLE pane: a long tool's output (or a
    # background-agents list) scrolls the spinner / "esc to interrupt" line well
    # above the tail window, but the session is still working. The spinner /
    # interrupt hint never legitimately appears in claude's prose, so a full-pane
    # scan can't false-positive — and tail-scoping it made a busy session read
    # "idle" (and flap working↔idle, spamming "finished" pings).
    low = text.lower()
    if any(m in low for m in _WORKING_MARKERS) or _WORKING_SPINNER_RE.search(text):
        return "working"
    return "idle"
