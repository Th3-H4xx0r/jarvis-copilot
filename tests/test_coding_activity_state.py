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
