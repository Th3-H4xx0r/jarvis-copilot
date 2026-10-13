"""The options a decision model picks a Mac move from."""
from agent.computer.choices import build_choices, element_line, parse_choice

LOOK = {"elements": [
    {"i": 1, "role": "AXButton", "label": "Send"},
    {"i": 2, "role": "AXSearchField", "label": "Search"},
    {"i": 3, "role": "AXStaticText", "label": ""},
]}


def test_click_per_element_and_fixed_moves():
    values = dict(build_choices(LOOK, {"do": "send it"}))
    assert values["click 1"] == "Click the button 'Send'"
    assert values["click 3"] == "Click the static text"
    for fixed in ("scroll down", "scroll up", "press return", "press escape", "wait", "done", "stuck"):
        assert fixed in values
    assert not any(v.startswith("fill") for v in values)


def test_fill_only_for_text_inputs_when_the_step_has_text():
    values = dict(build_choices(LOOK, {"do": "search", "text": "lo-fi"}))
    assert values["fill 2"] == "Type “lo-fi” into the search field 'Search'"
    assert "fill 1" not in values


def test_values_unique():
    values = [v for v, _ in build_choices(LOOK, {"do": "x", "text": "y"})]
    assert len(values) == len(set(values))


def test_parse():
    step = {"do": "search", "text": "lo-fi"}
    assert parse_choice("click 1", LOOK, step) == {"action": "click", "element": 1}
    assert parse_choice("fill 2", LOOK, step) == {"action": "fill", "element": 2, "text": "lo-fi"}
    assert parse_choice("scroll down", LOOK, step) == {"action": "scroll", "direction": "down"}
    assert parse_choice("press return", LOOK, step) == {"action": "key", "keys": "return"}
    assert parse_choice("press escape", LOOK, step) == {"action": "key", "keys": "escape"}
    assert parse_choice("wait", LOOK, step) == {"action": "wait"}
    assert parse_choice("done", LOOK, step) == {"action": "done"}
    assert parse_choice("click 99", LOOK, step) == {"action": "stuck"}
    assert parse_choice("nonsense", LOOK, step) == {"action": "stuck"}


def test_element_line():
    assert element_line({"i": 7, "role": "AXButton", "label": "Send"}) == "7. button 'Send'"
    assert element_line({"i": 8, "role": "text", "label": "Total"}) == "8. text 'Total'"
