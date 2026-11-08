"""Curses color pairs must work on low-color terminals (Docker).

Regression test for #13688: ``hermes plugins`` crashed with
``curses.error: init_pair() : color number is greater than COLORS-1``
where curses.COLORS == 8 (only colors 0-7 exist), because pair 4 used raw
color 8 ("bright black" / dim gray). Every curses screen now defines its
pairs through ``curses_ui.init_color_pairs``.
"""

import curses
from unittest.mock import patch

import pytest

from jarviscopilot_cli.curses_ui import init_color_pairs


def _init_pair_calls(colors_value: int) -> list[tuple[int, int, int]]:
    calls = []
    with patch("curses.COLORS", colors_value, create=True), \
         patch("curses.init_pair", side_effect=lambda *a: calls.append(a)), \
         patch("curses.has_colors", return_value=True), \
         patch("curses.start_color"), \
         patch("curses.use_default_colors"):
        init_color_pairs(curses)
    return calls


def test_8_color_terminal_never_uses_a_missing_color():
    calls = _init_pair_calls(8)
    assert calls
    for pair, fg, bg in calls:
        assert fg < 8, f"init_pair({pair}, {fg}, {bg}) on an 8-color terminal"


@pytest.mark.parametrize("colors", [16, 256])
def test_wider_terminals_get_dim_gray(colors):
    assert (4, 8, -1) in _init_pair_calls(colors)


def test_monochrome_terminal_defines_no_pairs():
    with patch("curses.has_colors", return_value=False), \
         patch("curses.init_pair") as init_pair:
        init_color_pairs(curses)
    init_pair.assert_not_called()
