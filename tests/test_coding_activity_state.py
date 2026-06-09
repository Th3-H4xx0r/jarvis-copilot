from agent.coding_activity_state import classify_pane


_WORKING_PANE = """\
● I'll run the test suite now.

✻ Running… (12s · ↑ 1.2k tokens · esc to interrupt)
"""

_WAITING_PANE = """\
╭───────────────────────────────────────────────╮
│ Bash command                                   │
│   npm test                                      │
│ Do you want to proceed?                         │
│ ❯ 1. Yes                                        │
│   2. Yes, and don't ask again                   │
│   3. No, and tell Claude what to do (esc)       │
╰───────────────────────────────────────────────╯
"""

_IDLE_PANE = """\
● Done — all tests pass.

╭───────────────────────────────────────────────╮
│ > Try "fix the failing test"                   │
╰───────────────────────────────────────────────╯
  ⏵⏵ accept edits on
"""


def test_working_detected():
    assert classify_pane(_WORKING_PANE) == "working"


def test_waiting_detected():
    assert classify_pane(_WAITING_PANE) == "waiting"


def test_idle_detected():
    assert classify_pane(_IDLE_PANE) == "idle"


def test_empty_is_idle():
    assert classify_pane("") == "idle"
    assert classify_pane(None) == "idle"


def test_real_permission_box_without_spinner_is_waiting():
    # A live permission box BLOCKS claude — there is NO active spinner. (The old
    # synthetic "spinner + box" never occurs in reality; a present spinner means
    # claude is working, not blocked — see the next test.)
    pane = (
        "╭─────────────────────────────╮\n"
        "│ Do you want to proceed?     │\n"
        "│ ❯ 1. Yes                    │\n"
        "│   2. No                     │\n"
        "╰─────────────────────────────╯\n"
    )
    assert classify_pane(pane) == "waiting"


def test_prose_paren_token_above_permission_box_is_waiting():
    # A parenthesized non-time token in claude's output — "(2 · 3)" / "(10 · 20)" —
    # must NOT read as the spinner and suppress a real permission box below it.
    pane = (
        "Ran the steps (2 · 3) and got results.\n"
        "╭─────────────────────────────╮\n"
        "│ Do you want to proceed?     │\n"
        "│ ❯ 1. Yes                    │\n"
        "╰─────────────────────────────╯\n"
    )
    assert classify_pane(pane) == "waiting"


def test_prose_interrupt_hint_above_permission_box_is_waiting():
    # claude WRITING "esc to interrupt" in a sentence (not the parenthesized status
    # line) must not suppress a real permission box below it.
    pane = (
        "You can press esc to interrupt to stop a turn.\n"
        "╭─────────────────────────────╮\n"
        "│ Do you want to proceed?     │\n"
        "│ ❯ 1. Yes                    │\n"
        "╰─────────────────────────────╯\n"
    )
    assert classify_pane(pane) == "waiting"


def test_permission_words_while_spinner_running_is_working():
    # THE reported bug: claude (in the jarvis session) DISCUSSING permission UIs —
    # printing "Do you want to proceed?" / "(y/n)" in its output WHILE its turn
    # spinner is up — must read WORKING, so it can't steal a "waiting" from another
    # session that has a real (spinner-less) prompt open.
    pane = (
        '● The permission box asks "Do you want to proceed?" and shows (y/n).\n'
        '✽ Hyperspacing… (1m 31s · ↓ 5.9k tokens)'
    )
    assert classify_pane(pane) == "working"


def test_yn_prompt_is_waiting():
    assert classify_pane("Overwrite file? (y/n)") == "waiting"


def test_idle_prompt_with_esc_hint_not_working():
    # The permission box's option 3 contains "(esc)" — that must NOT be read as
    # the working signal "esc to interrupt".
    assert classify_pane("3. No, and tell Claude what to do (esc)\n> ") == "idle"


def test_prose_question_while_working_is_working():
    # A streamed "Would you like…" question while the spinner is up must NOT be
    # misread as a permission prompt (regression for the tightened markers).
    pane = "✻ Working… (esc to interrupt)\nWould you like me to also update the tests?"
    assert classify_pane(pane) == "working"


def test_working_spinner_without_esc_hint():
    # Custom Claude forks omit "esc to interrupt" but still show the spinner with
    # a parenthesized elapsed time, e.g. "(35s · ↑ 2.4k tokens · thinking …)".
    pane = "✽ Precipitating… (35s · ↑ 2.4k tokens · thinking with xhigh effort)\n❯ "
    assert classify_pane(pane) == "working"


def test_selection_popup_is_waiting():
    # The AskUserQuestion multiple-choice popup (cursor on ANY option) reads as
    # waiting via its footer — the reliable live-prompt signal — not the "❯"
    # cursor glyph (which also marks the input prompt and echoed user lines).
    pane = (
        "Which season do you like best?\n"
        "❯ 1. Spring\n"
        "  2. Summer\n"
        "  3. Autumn\n"
        "  4. Winter\n"
        "Enter to select · ↑/↓ to navigate · Esc to cancel\n"
    )
    assert classify_pane(pane) == "waiting"


def test_selection_popup_non_first_option_is_waiting():
    pane = (
        "Pick a drink\n"
        "  1. Coffee\n"
        "❯ 2. Tea\n"
        "  3. Energy drink\n"
        "Enter to select · ↑/↓ to navigate · Esc to cancel\n"
    )
    assert classify_pane(pane) == "waiting"


def test_echoed_numbered_user_message_is_not_waiting():
    # The REPL echoes a user message with a "❯ " prefix; a user typing a NUMBERED
    # message ("❯ 2. fix the parser") must NOT be read as a selection menu (the
    # old "❯ \d+\." cursor regex wrongly did). No footer -> idle.
    assert classify_pane("❯ 2. fix the parser then run tests\n❯ ") == "idle"
    assert classify_pane("❯ ask me for another example popup\n❯ ") == "idle"


def test_scrollback_mention_of_footer_is_not_waiting():
    # claude's OWN output mentioning the footer words (e.g. while editing this
    # classifier) lives in SCROLLBACK, not the live tail — so a session that is
    # actually WORKING must not flip to waiting. Regression for "jarvis-copilot
    # shows waiting while it's running".
    pane = "\n".join(
        ['● Adding markers like "esc to cancel" and "enter to select".']
        + [f"  line {i} of edited output" for i in range(20)]
        + ["✻ Working… (12s · ↑ 1.2k tokens · esc to interrupt)"]
    )
    assert classify_pane(pane) == "working"


def test_working_spinner_scrolled_above_tail_is_working():
    # A long tool's output (or a background-agents list) pushes the spinner /
    # "esc to interrupt" line FAR above the bottom of the pane — but the session
    # is still working. Working must be detected over the WHOLE pane, not just the
    # live tail, else a busy session reads "idle" and flaps (spamming "finished").
    pane = "\n".join(
        ["✻ Running the test suite… (3m 12s · ↓ 98k tokens · esc to interrupt)"]
        + [f"test output line {i} ........................ ok" for i in range(40)]
        + ["PASS  tests/test_thing.py"]
    )
    assert classify_pane(pane) == "working"


def test_idle_prompt_below_long_output_is_idle():
    # The inverse: once the turn truly ends there is NO spinner anywhere and the
    # bottom is the input prompt — that stays idle (so "finished" fires once).
    pane = "\n".join(
        [f"test output line {i} ........................ ok" for i in range(40)]
        + ["PASS  tests/test_thing.py", "", "❯ "]
    )
    assert classify_pane(pane) == "idle"


def test_footer_words_in_output_with_prompt_below_is_not_waiting():
    # THE reported bug: claude (e.g. the jarvis session) DISCUSSING the key bar /
    # classifier prints "Enter to select" / "Esc to cancel" in its OUTPUT, then
    # sits at the input prompt. The footer is NOT the bottom line (the prompt is),
    # so the session reads idle — it must not steal a "waiting" that belongs to a
    # DIFFERENT session that actually has a popup open.
    pane = (
        '● I added the key bar; the popup footer is\n'
        '  "Enter to select · ↑/↓ to navigate · Esc to cancel".\n'
        '❯ '
    )
    assert classify_pane(pane) == "idle"


def test_footer_words_in_output_while_working_is_working():
    # Same, but the session is actively working (spinner is the bottom line).
    pane = (
        '● The footer reads "Enter to select · Esc to cancel".\n'
        '✻ Wiring it up… (8s · ↑ 2.1k tokens · esc to interrupt)'
    )
    assert classify_pane(pane) == "working"


def test_permission_words_in_prose_at_input_prompt_is_not_waiting():
    # claude asking "Do you want to proceed?" in PROSE, then resting at the input
    # prompt: the bottom is the composer, so it's idle — the phrase above is
    # scrollback, not a live permission box.
    pane = 'Do you want to proceed with the migration? Let me know.\n❯ '
    assert classify_pane(pane) == "idle"


def test_inline_yn_prompt_at_bottom_is_waiting():
    # A live inline confirm whose chevron-cursor IS the bottom line ("❯ (y/n)")
    # must read waiting — the at-prompt guard must NOT suppress a prompt that
    # carries the confirm on its own line.
    assert classify_pane("Overwrite the file?\n❯ (y/n)") == "waiting"
    assert classify_pane("❯ Delete everything? (y/n)") == "waiting"
