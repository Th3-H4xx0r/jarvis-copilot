"""Every main view that has a "show on its page" rule is also hidden by default.

`.main-view` is display:flex, so a view left out of the hidden-by-default group
shows on every page: the Live transcript sat on top of Settings, Chat and the
rest, with the real page squeezed underneath.
"""
import pathlib
import re

CSS = (pathlib.Path(__file__).parent.parent / "static" / "style.css").read_text(encoding="utf-8")


def _hidden_by_default() -> set:
    hidden = set()
    for selectors in re.findall(r"((?:main\.main > #main\w+,\s*)*main\.main > #main\w+)\s*\{display:none;\}", CSS):
        hidden.update(re.findall(r"#(main\w+)", selectors))
    return hidden


def test_every_shown_view_is_hidden_elsewhere():
    shown = set(re.findall(r"main\.main\.showing-\w+ > #(main\w+)\s*\{display:flex", CSS))
    assert shown, "no showing-<page> rules found"
    assert shown - _hidden_by_default() == set()
