"""Unit tests for the Dynamic Island design-tree validator (api.island_schema).

Pure validation — no I/O, no server. Run from the webui/ dir:
    cd webui && python3 -m pytest tests/test_island_schema.py
"""
from __future__ import annotations

from api import island_schema as s


def _minimal():
    return {
        "id": "demo", "version": 1, "name": "Demo",
        "presentations": {"expanded": {"type": "text", "value": "hi"}},
    }


def test_minimal_valid():
    assert s.validate_design(_minimal()) == []
    assert s.is_valid(_minimal())


def _design(node):
    return {"id": "x", "version": 1, "name": "X",
            "presentations": {"expanded": node}}


def test_progress_tip_string_shorthand_valid():
    assert s.validate_design(_design(
        {"type": "progress", "value": 0.4, "tip": "airplane"})) == []


def test_progress_tip_object_valid():
    assert s.validate_design(_design(
        {"type": "progress", "value": {"$": "frac"},
         "tip": {"symbol": "airplane", "color": "#FFFFFF", "size": 13, "rotation": 12}})) == []


def test_segbar_tip_with_from_to_dates_valid():
    assert s.validate_design(_design({
        "type": "segbar",
        "segments": [{"weight": 1, "color": "#a78bfa"}, {"weight": 1, "color": "#a78bfa"}],
        "from": {"$": "departAt"}, "to": {"$": "arriveAt"},
        "tip": {"symbol": "airplane", "rotation": 0}})) == []


def test_segbar_tip_with_explicit_progress_valid():
    assert s.validate_design(_design({
        "type": "segbar", "segments": [{"weight": 1, "color": "#a78bfa"}],
        "progress": {"$": "frac"}, "tip": "airplane"})) == []


def test_tip_object_requires_symbol():
    errs = s.validate_design(_design(
        {"type": "progress", "value": 0.4, "tip": {"color": "#fff"}}))
    assert any("tip.symbol is required" in e for e in errs)


def test_tip_size_must_be_a_number():
    errs = s.validate_design(_design(
        {"type": "progress", "value": 0.4, "tip": {"symbol": "airplane", "size": "big"}}))
    assert any("tip.size must be a number" in e for e in errs)


def test_empty_string_tip_is_rejected():
    errs = s.validate_design(_design(
        {"type": "segbar", "segments": [{"weight": 1, "color": "#fff"}], "progress": 0.5, "tip": "  "}))
    assert any("symbol name must be non-empty" in e for e in errs)


def test_tip_on_unsupported_leaf_is_ignored():
    # timer doesn't support a tip; the prop is simply not validated (no error).
    assert s.validate_design(_design({"type": "timer", "to": 123, "tip": "airplane"})) == []


def test_clock_phase_binding_valid():
    # offline status/label switching: a text value computed from the device clock
    assert s.validate_design(_design({
        "type": "text",
        "value": {"clock": "phase",
                  "keys": [{"at": 1718000000, "value": "Boarding"},
                           {"at": 1718003600, "value": "In flight"}],
                  "default": "Scheduled"}})) == []


def test_clock_phase_with_map_and_fmt_valid():
    assert s.validate_design(_design({
        "type": "badge",
        "text": {"clock": "phase", "keys": [{"at": 1, "value": "flying"}],
                 "map": {"flying": "Flying"}, "fmt": "{}"}})) == []


def test_clock_fraction_drives_tip_valid():
    assert s.validate_design(_design({
        "type": "segbar",
        "segments": [{"weight": 1, "color": "#a78bfa"}],
        "progress": {"clock": "fraction", "from": {"$": "departAt"}, "to": 1718039600},
        "tip": {"symbol": "airplane"}})) == []


def test_clock_remaining_and_elapsed_and_index_valid():
    for node in (
        {"type": "stat", "value": {"clock": "remaining", "to": 1718039600, "fmt": "{}s"}},
        {"type": "stat", "value": {"clock": "elapsed", "from": 1718000000}},
        {"type": "stat", "value": {"clock": "index", "keys": [1, 2, 3]}},
    ):
        assert s.validate_design(_design(node)) == [], node


def test_clock_unknown_kind_rejected():
    errs = s.validate_design(_design({"type": "text", "value": {"clock": "wobble"}}))
    assert any("unknown kind" in e for e in errs)


def test_clock_fraction_missing_from_to_rejected():
    errs = s.validate_design(_design({"type": "text", "value": {"clock": "fraction", "to": 1}}))
    assert any("needs 'from'" in e for e in errs)


def test_clock_phase_missing_keys_rejected():
    errs = s.validate_design(_design({"type": "text", "value": {"clock": "phase"}}))
    assert any("keys must be a non-empty list" in e for e in errs)


def test_clock_phase_key_missing_at_or_value_rejected():
    errs = s.validate_design(_design({"type": "text",
        "value": {"clock": "phase", "keys": [{"at": 1}]}}))
    assert any("must have 'at' and 'value'" in e for e in errs)


def test_clock_timestamp_wrong_type_rejected():
    # a list / bool timestamp passes presence but is unparseable on-device → reject
    errs = s.validate_design(_design({"type": "text",
        "value": {"clock": "fraction", "from": [1, 2], "to": 3}}))
    assert any("from must be an epoch number" in e for e in errs)
    errs = s.validate_design(_design({"type": "text",
        "value": {"clock": "remaining", "to": True}}))
    assert any("to must be an epoch number or ISO date string, not a bool" in e for e in errs)
    errs = s.validate_design(_design({"type": "text",
        "value": {"clock": "phase", "keys": [{"at": [1], "value": "x"}]}}))
    assert any("keys[0].at must be an epoch number" in e for e in errs)


def test_clock_timestamp_string_and_epoch_and_binding_ok():
    for ts in ("2030-03-17T17:30:00Z", 1718039600, {"$": "departAt"}):
        assert s.validate_design(_design({"type": "text",
            "value": {"clock": "remaining", "to": ts}})) == [], ts


def test_time_condition_after_before_valid():
    # show the gate only after arrival (offline boundary)
    assert s.validate_design({
        "id": "x", "version": 1, "name": "X",
        "presentations": {"expanded": {"type": "vstack", "children": [
            {"type": "text", "value": "Gate B12",
             "when": {"op": "after", "at": 1718039600}},
            {"type": "text", "value": "Boarding soon",
             "when": {"op": "before", "at": 1718003600}},
        ]}}}) == []


def test_time_condition_after_missing_at_rejected():
    errs = s.validate_design({
        "id": "x", "version": 1, "name": "X",
        "presentations": {"expanded": {"type": "text", "value": "hi",
            "when": {"op": "after"}}}})
    assert any(".at is required" in e for e in errs)


def test_deploy_status_example_valid():
    design = {
        "id": "deploy-status", "version": 1, "name": "Deploy status",
        "icon": "shippingbox.fill", "tint": "#0a84ff",
        "presentations": {
            "expanded": {"type": "vstack", "spacing": 8, "children": [
                {"type": "hstack", "children": [
                    {"type": "symbol", "name": "shippingbox.fill",
                     "style": {"tint": "#0a84ff"}},
                    {"type": "titleSubtitle", "title": {"$": "repo"},
                     "subtitle": {"$": "branch"}},
                    {"type": "spacer"},
                    {"type": "gauge", "style": "single",
                     "rings": [{"value": {"$": "pct"}, "tint": "#0a84ff"}]}]},
                {"type": "progress", "value": {"$": "pct"},
                 "tint": {"$": "state",
                          "map": {"running": "#0a84ff", "passed": "#34c759"}}},
                {"type": "list", "data": {"$": "steps"}, "max": 3, "row":
                    {"type": "hstack", "children": [
                        {"type": "dot", "color": {"$row": "state",
                         "map": {"ok": "#34c759"}}},
                        {"type": "text", "value": {"$row": "name"}},
                        {"type": "spacer"},
                        {"type": "text", "value": {"$row": "dur"}}]}}]},
            "compactLeading": {"type": "symbol", "name": "shippingbox.fill"},
            "compactTrailing": {"type": "text",
                                "value": {"$": "pct", "fmt": "{}%"}},
            "minimal": {"type": "dot", "color": {"$": "state"}},
        },
    }
    assert s.validate_design(design) == []


def test_not_an_object():
    assert s.validate_design([]) == ["design must be an object"]


def test_bad_id():
    d = _minimal(); d["id"] = "Bad ID!"
    assert any("id must be" in e for e in s.validate_design(d))


def test_missing_expanded():
    d = _minimal(); d["presentations"] = {"minimal": {"type": "divider"}}
    assert any("expanded is required" in e for e in s.validate_design(d))


def test_unknown_presentation():
    d = _minimal(); d["presentations"]["bogus"] = {"type": "divider"}
    assert any("unknown presentation" in e for e in s.validate_design(d))


def test_unknown_node_type():
    d = _minimal(); d["presentations"]["expanded"] = {"type": "blink"}
    assert any("unknown node type" in e for e in s.validate_design(d))


def test_row_binding_outside_list_rejected():
    d = _minimal()
    d["presentations"]["expanded"] = {"type": "text", "value": {"$row": "x"}}
    assert any("$row binding only valid inside a list" in e
               for e in s.validate_design(d))


def test_row_binding_inside_list_ok():
    d = _minimal()
    d["presentations"]["expanded"] = {
        "type": "list", "data": {"$": "rows"},
        "row": {"type": "text", "value": {"$row": "x"}}}
    assert s.validate_design(d) == []


def test_unknown_source():
    d = _minimal()
    d["presentations"]["expanded"] = {"type": "text", "value": {"src": "nope.x"}}
    assert any("unknown source" in e for e in s.validate_design(d))


def test_known_namespace_source_ok():
    d = _minimal()
    d["presentations"]["expanded"] = {"type": "text",
                                      "value": {"src": "jarvis.deployPct"}}
    assert s.validate_design(d) == []


def test_binding_needs_exactly_one_key():
    d = _minimal()
    d["presentations"]["expanded"] = {"type": "text",
                                      "value": {"$": "a", "src": "time.now"}}
    assert any("exactly one of" in e for e in s.validate_design(d))


def test_list_requires_row():
    d = _minimal()
    d["presentations"]["expanded"] = {"type": "list", "data": {"$": "rows"}}
    assert any(".row is required" in e for e in s.validate_design(d))


def test_array_prop_rejects_scalar():
    d = _minimal()
    d["presentations"]["expanded"] = {"type": "segbar", "segments": "nope"}
    assert any("expected a list or array binding" in e
               for e in s.validate_design(d))


def test_array_prop_accepts_binding_and_list():
    d = _minimal()
    d["presentations"]["expanded"] = {
        "type": "sparkline", "points": {"$": "series"}}
    assert s.validate_design(d) == []


def test_gauge_requires_rings():
    d = _minimal()
    d["presentations"]["expanded"] = {"type": "gauge", "style": "single"}
    assert any("rings must be a non-empty list" in e
               for e in s.validate_design(d))


def test_regions_only_in_expanded():
    d = _minimal()
    d["presentations"]["minimal"] = {"type": "regions",
                                     "leading": {"type": "divider"}}
    assert any("only allowed at the top of presentations.expanded" in e
               for e in s.validate_design(d))


def test_regions_in_expanded_ok():
    d = _minimal()
    d["presentations"]["expanded"] = {"type": "regions",
                                      "leading": {"type": "symbol", "name": "bolt"},
                                      "bottom": {"type": "text", "value": "x"}}
    assert s.validate_design(d) == []


def test_too_deep():
    node = {"type": "text", "value": "x"}
    for _ in range(s.MAX_DEPTH + 3):
        node = {"type": "vstack", "children": [node]}
    d = _minimal(); d["presentations"]["expanded"] = node
    assert any("too deep" in e for e in s.validate_design(d))


def test_too_many_nodes():
    children = [{"type": "divider"} for _ in range(s.MAX_NODES + 5)]
    d = _minimal()
    d["presentations"]["expanded"] = {"type": "vstack", "children": children}
    assert any("too many nodes" in e for e in s.validate_design(d))


def test_missing_required_leaf_prop():
    d = _minimal()
    d["presentations"]["expanded"] = {"type": "progress"}  # value required
    assert any(".value is required for progress" in e
               for e in s.validate_design(d))


def test_condition_validation():
    good = {"op": "and", "items": [
        {"op": "gt", "a": {"src": "battery.level"}, "b": 20},
        {"op": "exists", "a": {"$": "x"}}]}
    assert s.validate_condition(good) == []
    bad = {"op": "frobnicate"}
    assert any("unknown condition op" in e for e in s.validate_condition(bad))


def test_when_on_node_validated():
    d = _minimal()
    d["presentations"]["expanded"] = {
        "type": "text", "value": "x", "when": {"op": "nope"}}
    assert any("unknown condition op" in e for e in s.validate_design(d))


def test_time_progress_requires_from_and_to():
    d = _minimal()
    d["presentations"]["expanded"] = {"type": "timeProgress", "to": 100}
    assert any(".from is required" in e for e in s.validate_design(d))


def test_time_progress_valid():
    d = _minimal()
    d["presentations"]["expanded"] = {"type": "timeProgress",
                                      "from": {"$": "dep"}, "to": {"$": "arr"}}
    assert s.validate_design(d) == []


def test_timeline_validation():
    d = _minimal()
    d["timeline"] = [{"at": 100, "data": {"phase": "Boarding"}}]
    assert s.validate_design(d) == []
    d["timeline"] = [{"at": "nope", "data": {}}]
    assert any("timeline[0].at" in e for e in s.validate_design(d))
    d["timeline"] = "x"
    assert any("timeline must be a list" in e for e in s.validate_design(d))


def test_notifications_validation():
    d = _minimal()
    d["notifications"] = [{"at": 100, "title": "Boarding", "body": "Gate A1"}]
    assert s.validate_design(d) == []
    d["notifications"] = [{"at": 100, "title": ""}]
    assert any("title must be" in e for e in s.validate_design(d))
    d["notifications"] = [{"title": "x"}]
    assert any("notifications[0].at" in e for e in s.validate_design(d))


def test_bad_tint():
    d = _minimal(); d["tint"] = "octarine"
    assert any("tint must be" in e for e in s.validate_design(d))
