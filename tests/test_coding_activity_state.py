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


def test_waiting_wins_over_working():
    # A permission box that still shows a spinner frame underneath must read as
    # waiting (blocked on the user is the more important signal).
    mixed = "✻ Running… (esc to interrupt)\nDo you want to proceed?\n❯ 1. Yes\n"
    assert classify_pane(mixed) == "waiting"


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
