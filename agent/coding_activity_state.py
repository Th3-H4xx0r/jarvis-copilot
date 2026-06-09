"""Classify a Claude Code tmux pane into a live "activity state".

This is the SOURCE OF TRUTH for the heuristics. The desktop client replicates
``classify_pane`` verbatim in ``desktop_client/jc_client/coding_discover.py``
(the client process can't import ``agent/``) — keep the two in sync.

States:
  - ``working`` — Claude is actively processing (a spinner / "esc to interrupt").
  - ``waiting`` — Claude is blocked on the user (a permission / choice prompt).
  - ``idle``    — at rest at the prompt with nothing pending.

Precedence: a present WORKING spinner wins over any prompt phrase — a real
permission box / selection popup BLOCKS claude so it has NO live spinner; a
phrase seen alongside a live spinner is claude's OUTPUT, not a live box. With no
spinner, a selection footer or permission marker BELOW the live composer →
waiting; otherwise idle.

The hard problem is that a tmux pane contains claude's OWN conversational output
(scrollback), which can MENTION the very words a live prompt uses — e.g. claude
discussing "esc to cancel" / "Do you want to proceed?", or echoing a user's
numbered message "❯ 2. do the thing". A naive substring scan then misreads an
idle/working session as "waiting" (the real bug: jarvis-copilot flipping to
"waiting" whenever its scrollback quoted prompt phrases). So we anchor detection
to the LAST COMPOSER line — the free-text input prompt "❯ ":
  • everything ABOVE the last composer is scrollback (output precedes the
    composer), so prompt words there are quotes, never a live prompt;
  • a live permission box / selection popup REPLACES the composer, so when one
    is up the last composer line is an old echoed user message far above and the
    box's markers land BELOW the anchor → waiting.
NOTE the composer is NOT the pane's last line in the real rendering: a rule,
the composer, another rule and 1-2 status/mode lines render below it (an earlier
version anchored on "the last line is the prompt" — that guard never engaged in
production and quoted phrases in the tail flipped idle panes to waiting).
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

# How many lines up from the bottom a selection popup's FOOTER can sit — the
# footer itself + the status/mode chrome AND the background-agents list, which
# render below it (the agents list alone is 1 line per agent + a header). Safe
# to be generous: the window is anchored strictly below the last composer, so
# quoted footer words in scrollback can never land in it.
_FOOTER_TAIL = 10

# Echoed TOOL OUTPUT shown in the transcript: the "⎿" result gutter, "⏺"
# message bullets, diff +/- lines, and line-numbered file dumps. These can
# contain verbatim spinner/status text (e.g. this repo's own test fixtures:
# "⎿ +✻ Running… (12s · esc to interrupt)") — never read a WORKING signal off
# them. The live spinner line always starts with the spinner glyph itself.
_ECHO_LINE_RE = re.compile(r"^\s*(?:⎿|⏺|\+|-|\d+[\t ])")

# The free-text INPUT PROMPT line (the composer): a chevron/`>` alone (tmux
# captures the cursor cell as a no-break space, which `\s` matches) or followed
# by typed text — but NOT a numbered option ("❯ 1. Yes"), which belongs to a
# selection list. A permission box's option row ("│ ❯ 1. Yes") never matches:
# the leading box border isn't whitespace. The LAST line matching this is the
# anchor: prompt words at or above it are scrollback.
_COMPOSER_RE = re.compile(r"^\s*[❯>](?:\s+(?!\d+\.)|$)")

# Claude shows "esc to interrupt" on its status line whenever it is running a
# turn or a tool (in every permission mode), so it is the reliable "working"
# signal. We deliberately do NOT key off bare spinner glyphs alone (the splash
# screen uses one), to avoid false positives on an idle session.
_WORKING_MARKERS = (
    "esc to interrupt",
    "esc to stop",
)

# The background hint inside the status segment. Rendered with variable middle
# text across versions — "ctrl+b to run in background", "ctrl+b ctrl+b (twice)
# to run in background" — so match the stable head + tail, not one literal.
_BG_HINT_RE = re.compile(r"ctrl\+b.*to run in background")

# The live "spinner" status line — a parenthesized ELAPSED TIME followed by a
# middot, e.g. "(35s · …)", "(3m 12s · …)". We REQUIRE a time unit (h/m/s) before
# the middot so it can't match plain parenthesized prose like "(2 · 3)" / "(10 ·
# 20)" that claude might emit in a list/table (which would falsely read working
# and suppress a real "waiting").
_WORKING_SPINNER_RE = re.compile(r"\(\d[\dhms\s]*[hms][\dhms\s]*·")


def _last_working_line(lines: list) -> int:
    """Index of the LAST line carrying a live working signal — the elapsed-time
    spinner, or a working hint ("esc to interrupt" …) INSIDE the parenthesized
    status segment — or -1. Requiring the "(" anchors the hint to the status
    line so claude's PROSE ("press esc to interrupt to stop") can't be misread
    as working; echoed tool-output lines (_ECHO_LINE_RE) are never signals."""
    idx = -1
    for i, line in enumerate(lines):
        if _ECHO_LINE_RE.match(line):
            continue
        if _WORKING_SPINNER_RE.search(line):
            idx = i
            continue
        if "(" in line:
            low = line.lower()
            if any(m in low for m in _WORKING_MARKERS) or _BG_HINT_RE.search(low):
                idx = i
    return idx


def extract_status_line(text: str) -> str | None:
    """The LIVE spinner/status line of a working pane (e.g. "✳ Zesting… (50s ·
    ↑ 2.0k tokens)"), or None. Uses the same echo-aware detection as
    classification, so a quoted spinner in scrollback is never returned."""
    if not text:
        return None
    lines = text.splitlines()
    while lines and not lines[-1].strip():
        lines.pop()
    idx = _last_working_line(lines)
    if idx < 0:
        return None
    return lines[idx].strip()[:160] or None


def classify_pane(text: str) -> str:
    """Return ``"working" | "waiting" | "idle"`` for a captured tmux pane."""
    if not text:
        return "idle"
    lines = text.splitlines()
    while lines and not lines[-1].strip():
        lines.pop()              # drop tmux's trailing blank padding
    if not lines:
        return "idle"

    # The anchor: the LAST composer-like line. Output renders ABOVE the composer,
    # so prompt words at or above the anchor are scrollback quotes. A live
    # permission box / selection popup REPLACES the composer — its markers land
    # below whatever old echoed "❯ message" remains above → still detected.
    last_composer = -1
    for i, line in enumerate(lines):
        if _COMPOSER_RE.match(line):
            last_composer = i

    # Is claude ACTIVELY WORKING? The live spinner / "esc to interrupt" hint only
    # render while a turn or tool runs. A real PERMISSION box / popup BLOCKS
    # claude, so it has NO live spinner — therefore a prompt phrase seen WHILE a
    # spinner is up is claude's own OUTPUT, NOT a live prompt. We scan the WHOLE
    # pane for the working signal so a long tool's output scrolling the spinner
    # above the bottom still reads working. BUT a prompt marker strictly BELOW
    # the last working line wins: nothing live renders after a blocking box, so
    # a "spinner" above a box is an echo/quote, not a live turn.
    working_idx = _last_working_line(lines)
    working = working_idx >= 0

    # 1) A live SELECTION popup — its footer sits in the bottom window (mode
    #    line / agents list may render below it), strictly BELOW the last
    #    composer AND below any working signal.
    for i in range(max(last_composer + 1, len(lines) - _FOOTER_TAIL), len(lines)):
        if i <= working_idx:
            continue
        low = lines[i].lower()
        if any(m in low for m in _SELECT_FOOTER_MARKERS):
            return "waiting"

    # 2) A PERMISSION / confirmation box — a marker in the tail, strictly BELOW
    #    the last composer and below any working signal. Exception: the bottom
    #    line itself carrying the confirm (e.g. "❯ (y/n)") is a real inline
    #    prompt even though it matches the composer shape.
    if len(lines) - 1 > working_idx and \
            any(m in lines[-1].lower() for m in _PERMISSION_MARKERS):
        return "waiting"
    start = max(last_composer + 1, len(lines) - _PERMISSION_TAIL, working_idx + 1)
    tail = "\n".join(lines[start:]).lower()
    if any(m in tail for m in _PERMISSION_MARKERS):
        return "waiting"

    return "working" if working else "idle"
