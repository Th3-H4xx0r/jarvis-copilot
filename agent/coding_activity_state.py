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

The hard problem is that a tmux pane contains claude's OWN conversational output
(scrollback), which can MENTION the very words a live prompt uses — e.g. claude
discussing "esc to cancel" / "enter to select", or echoing a user's numbered
message "❯ 2. do the thing". A naive substring scan then misreads a working
session as "waiting" (the real bug: jarvis-copilot showing "waiting" while it was
just talking about the UI). So we anchor detection to the LIVE position of each
prompt, not "anywhere on screen":
  • a SELECTION popup's footer is literally the BOTTOM line of the pane;
  • a PERMISSION box's bottom line is a box border/option — NEVER the free-text
    input prompt — so if the bottom line IS the input prompt, claude is at rest
    and any permission-ish words above are scrollback.
"""
from __future__ import annotations

import re

# Selection-popup FOOTER fragments. The AskUserQuestion / multiple-choice popup
# renders "Enter to select · ↑/↓ to navigate · Esc to cancel" as its last line;
# "Esc to cancel" is always the final segment, so it survives a narrow-pane wrap.
_SELECT_FOOTER_MARKERS = (
    "esc to cancel",
    "enter to select",
)

# Permission / confirmation prompts. These phrases are essentially never emitted
# verbatim in claude's prose, but we still only trust them when the pane is NOT
# sitting at the input prompt (see classify_pane).
_PERMISSION_MARKERS = (
    "do you want to proceed",
    "do you want to run",
    "do you want to make this edit",
    "do you want to create",
    "do you want to delete",
    "would you like to proceed",   # ExitPlanMode-style approval
    "(y/n)",
    "press enter to continue",
)

# How many lines up from the bottom a permission box's prompt can sit (title +
# command + "Do you want to…" + the option list + border).
_PERMISSION_TAIL = 12

# The free-text INPUT PROMPT line (the composer): a chevron/`>` then a space and
# the cursor or typed text — but NOT a numbered option ("❯ 1. Yes"), which belongs
# to a selection list and has the footer/border below it. When THIS is the bottom
# line, claude is at rest (idle/working), so permission/footer words above it are
# scrollback, not a live prompt.
_INPUT_PROMPT_RE = re.compile(r"^\s*[❯>]\s+(?!\d+\.)")

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
    lines = text.splitlines()
    while lines and not lines[-1].strip():
        lines.pop()              # drop tmux's trailing blank padding
    if not lines:
        return "idle"
    last = lines[-1]

    # 1) A live SELECTION popup — its footer IS the bottom line. (claude merely
    #    printing those words leaves the input prompt / more output below them, so
    #    the footer is NOT the last line → no false "waiting".)
    low_last = last.lower()
    if any(m in low_last for m in _SELECT_FOOTER_MARKERS):
        return "waiting"

    # 2) A PERMISSION / confirmation box — its bottom line is a border/option,
    #    never the free-text input prompt. So skip this when the bottom line IS the
    #    input prompt (claude at rest) — UNLESS that line itself carries a live
    #    confirm (e.g. "❯ (y/n)"), which is a real prompt, not the composer.
    at_prompt = bool(_INPUT_PROMPT_RE.match(last))
    if not at_prompt or any(m in low_last for m in _PERMISSION_MARKERS):
        tail = "\n".join(lines[-_PERMISSION_TAIL:]).lower()
        if any(m in tail for m in _PERMISSION_MARKERS):
            return "waiting"

    # 3) WORKING over the WHOLE pane: a long tool's output (or a background-agents
    #    list) scrolls the spinner / "esc to interrupt" line well above the bottom,
    #    but the session is still working. The spinner / interrupt hint never
    #    appears in claude's prose, so a full-pane scan can't false-positive.
    low = text.lower()
    if any(m in low for m in _WORKING_MARKERS) or _WORKING_SPINNER_RE.search(text):
        return "working"
    return "idle"
