"""Classify a Claude Code tmux pane into a live "activity state".

This is the SOURCE OF TRUTH for the heuristics. The desktop client replicates
``classify_pane`` verbatim in ``desktop_client/jc_client/coding_discover.py``
(the client process can't import ``agent/``) — keep the two in sync.

States:
  - ``working`` — Claude is actively processing (a spinner / "esc to interrupt").
  - ``waiting`` — Claude is blocked on the user (a permission / choice prompt).
  - ``idle``    — at rest at the prompt with nothing pending.

Precedence: a live SELECTION footer (the bottom line) always wins → waiting.
Otherwise, a present WORKING spinner wins over a permission phrase — a real
permission box blocks claude so it has NO spinner; a phrase seen alongside a live
spinner is claude's OUTPUT, not a live box. A permission box (no spinner) →
waiting; everything else → working (spinner) or idle.

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

# The live "spinner" status line — a parenthesized ELAPSED TIME followed by a
# middot, e.g. "(35s · …)", "(3m 12s · …)". We REQUIRE a time unit (h/m/s) before
# the middot so it can't match plain parenthesized prose like "(2 · 3)" / "(10 ·
# 20)" that claude might emit in a list/table (which would falsely read working
# and suppress a real "waiting").
_WORKING_SPINNER_RE = re.compile(r"\(\d[\dhms\s]*[hms][\dhms\s]*·")


def _pane_is_working(text: str) -> bool:
    """True if any line is the LIVE status line — the elapsed-time spinner, or a
    working hint ("esc to interrupt" …) INSIDE the parenthesized status segment.
    Requiring the "(" anchors the hint to the status line so claude's PROSE (e.g.
    "press esc to interrupt to stop") can't be misread as working."""
    for line in text.splitlines():
        if _WORKING_SPINNER_RE.search(line):
            return True
        if "(" in line:
            low = line.lower()
            if any(m in low for m in _WORKING_MARKERS):
                return True
    return False


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
    low_last = last.lower()

    # 1) A live SELECTION popup — its footer IS the bottom line. (claude merely
    #    printing those words leaves the input prompt / more output below them, so
    #    the footer is NOT the last line → no false "waiting".)
    if any(m in low_last for m in _SELECT_FOOTER_MARKERS):
        return "waiting"

    # Is claude ACTIVELY WORKING? The live spinner / "esc to interrupt" hint only
    # render while a turn or tool runs. A real PERMISSION box BLOCKS claude, so it
    # has NO live spinner — therefore a permission phrase seen WHILE a spinner is
    # up is claude's own OUTPUT (claude discussing "(y/n)" / "do you want to…"),
    # NOT a live prompt. This is the fix for a busy session being misread as
    # "waiting" because its claude was writing about permission UIs. We also scan
    # the WHOLE pane for the working signal so a long tool's output scrolling the
    # spinner above the bottom still reads working.
    working = _pane_is_working(text)

    # 2) A PERMISSION / confirmation box — a marker a few lines up. Only when NOT
    #    working (a live box blocks claude → no spinner) and NOT sitting at the
    #    free-text input prompt (then the marker is scrollback) — UNLESS the bottom
    #    line itself carries the confirm (e.g. "❯ (y/n)"), a real prompt.
    if not working:
        at_prompt = bool(_INPUT_PROMPT_RE.match(last))
        if not at_prompt or any(m in low_last for m in _PERMISSION_MARKERS):
            tail = "\n".join(lines[-_PERMISSION_TAIL:]).lower()
            if any(m in tail for m in _PERMISSION_MARKERS):
                return "waiting"

    return "working" if working else "idle"
