"""Widget designs: schema (api.widget_schema), store (api.widget_store) and the
REST dispatcher (api.widget_routes).

Pure: a real WidgetStore on tmp_path. Run from the repo root:
    TZ=UTC LANG=C.UTF-8 python3 -m pytest -o addopts="" -q webui/tests/test_widget_routes.py
"""
from __future__ import annotations

import pytest

from api import island_schema
from api import widget_schema as ws
from api.widget_routes import handle_widgets_request as H
from api.widget_store import WidgetStore

CATALOG = [
    {"key": "health.steps", "label": "Steps", "area": "health", "kind": "number", "unit": "steps"},
    {"key": "health.steps_week", "label": "Steps this week", "area": "health", "kind": "series"},
    {"key": "x5ring.battery", "label": "X5 battery", "area": "wearables", "kind": "number", "unit": "%"},
]


def _design(did="steps", presentations=None, **extra):
    if presentations is None:
        presentations = {"small": {"type": "stat", "value": {"src": "health.steps"}}}
    d = {"schema": 1, "id": did, "name": "Steps", "presentations": presentations}
    d.update(extra)
    return d


def _errors(node, size="small"):
    errors, _ = ws.validate_design(_design(presentations={size: node}))
    return errors


@pytest.fixture()
def store(tmp_path):
    return WidgetStore(tmp_path)


# ── schema: sizes ────────────────────────────────────────────────────────────

@pytest.mark.parametrize("size", ["small", "medium", "large", "extraLarge",
                                  "circular", "rectangular", "inline"])
def test_every_widget_size_is_a_presentation(size):
    errors, _ = ws.validate_design(_design(presentations={size: {"type": "text", "value": "hi"}}))
    assert errors == []


def test_a_design_needs_at_least_one_presentation():
    errors, _ = ws.validate_design(_design(presentations={}))
    assert errors and any("presentation" in e for e in errors)


def test_presentations_must_be_an_object():
    errors, _ = ws.validate_design({"id": "x", "name": "X", "presentations": [1]})
    assert errors


@pytest.mark.parametrize("key", ["expanded", "huge", "Small"])
def test_unknown_size_keys_are_rejected(key):
    errors, _ = ws.validate_design(_design(presentations={
        "small": {"type": "text", "value": "hi"}, key: {"type": "text", "value": "hi"}}))
    assert any(key in e for e in errors), errors


@pytest.mark.parametrize("bad", [
    {"id": "Has Spaces", "name": "X"},
    {"id": "x", "name": ""},
    {"id": "x", "name": "X", "tint": "not-a-colour"},
    {"id": "x", "name": "X", "icon": 5},
    {"id": "x", "name": "X", "version": -1},
    {"id": "x", "name": "X", "schema": 0},
])
def test_top_level_fields_are_checked(bad):
    design = {"presentations": {"small": {"type": "text", "value": "hi"}}, **bad}
    errors, _ = ws.validate_design(design)
    assert errors


def test_not_an_object():
    errors, warnings = ws.validate_design("nope")
    assert errors and warnings == []


def test_builder_may_hold_anything():
    errors, _ = ws.validate_design(_design(builder={"rows": [{"blocks": [1, "two", None]}]}))
    assert errors == []


# ── schema: node types ───────────────────────────────────────────────────────

def test_island_nodes_still_work_in_widgets():
    tree = {"type": "vstack", "spacing": 4, "children": [
        {"type": "symbolValue", "symbol": "figure.walk", "value": {"src": "health.steps", "fmt": "{} steps"}},
        {"type": "progress", "value": 0.4, "tint": "#34c759"},
        {"type": "gauge", "rings": [{"value": 0.5, "tint": "green"}]},
        {"type": "text", "value": {"$": "health.steps"},
         "when": {"op": "gt", "a": {"src": "health.steps"}, "b": 0}},
    ]}
    assert _errors(tree, "medium") == []


@pytest.mark.parametrize("node", [
    {"type": "chart", "series": {"src": "health.steps_week"}},
    {"type": "chart", "series": [1, 2, 3], "style": "bar", "color": "#0a84ff", "min": 0, "max": 10},
    {"type": "chart", "series": [{"x": 1, "y": 2}], "style": "area"},
    {"type": "chart", "series": {"src": "health.steps_week"}, "style": "line", "min": {"src": "health.steps"}},
    {"type": "model", "device": "x5ring"},
    {"type": "model", "device": "ring"},
    {"type": "button", "button": "lights-off"},
    {"type": "button", "button": "lights-off", "label": "Lights", "symbol": "lightbulb.fill"},
    {"type": "toggle", "button": "keep-alive"},
    {"type": "toggle", "button": "keep-alive", "label": "Keep alive"},
])
def test_new_widget_nodes_are_accepted(node):
    assert _errors(node, "large") == []


@pytest.mark.parametrize("device", ["ring", "x5ring", "glasses", "bottle", "scale", "esp32", "pod"])
def test_every_model_device(device):
    assert _errors({"type": "model", "device": device}) == []


@pytest.mark.parametrize("node, needle", [
    ({"type": "chart"}, "series"),
    ({"type": "chart", "series": 5}, "series"),
    ({"type": "chart", "series": [1], "style": "pie"}, "style"),
    ({"type": "chart", "series": [1], "min": "low"}, "min"),
    ({"type": "chart", "series": [1], "max": [9]}, "max"),
    ({"type": "model"}, "device"),
    ({"type": "model", "device": "toaster"}, "device"),
    ({"type": "model", "device": {"src": "health.steps"}}, "device"),
    ({"type": "button"}, "button"),
    ({"type": "button", "button": ""}, "button"),
    ({"type": "button", "button": 7}, "button"),
    ({"type": "toggle"}, "button"),
    ({"type": "toggle", "button": ["a"]}, "button"),
    ({"type": "stat"}, "value"),
])
def test_new_nodes_need_their_props(node, needle):
    errors = _errors(node)
    assert errors and any(needle in e for e in errors), errors


@pytest.mark.parametrize("node", [
    {"type": "carousel"},
    {"type": "regions", "bottom": {"type": "text", "value": "hi"}},
    "not a node",
])
def test_bad_node_types_are_rejected(node):
    assert _errors(node)


def test_nodes_nested_in_containers_are_validated():
    tree = {"type": "hstack", "children": [{"type": "chart", "style": "line"}]}
    errors = _errors(tree)
    assert any("children[0].series" in e for e in errors), errors


def test_node_limit_is_per_size():
    many = {"type": "vstack", "children": [{"type": "text", "value": str(i)} for i in range(150)]}
    errors, _ = ws.validate_design(_design(presentations={"small": many, "medium": many, "large": many}))
    assert errors == []
    too_many = {"type": "vstack", "children": [{"type": "text", "value": str(i)} for i in range(200)]}
    assert any("too many nodes" in e for e in _errors(too_many))


# ── schema: bindings + catalog warnings ──────────────────────────────────────

def test_any_area_key_source_is_allowed_in_widgets():
    node = {"type": "stat", "value": {"src": "x5ring.battery", "fmt": "{}%"}}
    assert _errors(node) == []
    # …while the island keeps its own source registry.
    island = {"id": "i", "name": "I", "presentations": {"expanded": node}}
    assert any("unknown source" in e for e in island_schema.validate_design(island))


@pytest.mark.parametrize("src", ["steps", "health.", ".steps", "health..steps", "health steps"])
def test_a_source_must_be_an_area_key(src):
    errors = _errors({"type": "stat", "value": {"src": src}})
    assert any("src" in e for e in errors), errors


def test_sources_in_conditions_use_the_widget_rules():
    node = {"type": "text", "value": "low",
            "when": {"op": "lt", "a": {"src": "x5ring.battery"}, "b": 20}}
    assert _errors(node) == []
    assert _errors({**node, "when": {"op": "lt", "a": {"src": "battery"}, "b": 20}})


def test_keys_missing_from_the_catalog_are_warnings_not_errors():
    keys = {e["key"] for e in CATALOG}
    design = _design(presentations={"small": {"type": "vstack", "children": [
        {"type": "stat", "value": {"src": "health.steps"}},
        {"type": "stat", "value": {"src": "glasses.battery"}},
        {"type": "text", "value": {"$": "chat.last_reply"}},
    ]}})
    errors, warnings = ws.validate_design(design, catalog_keys=keys)
    assert errors == []
    assert any("glasses.battery" in w for w in warnings)
    assert any("chat.last_reply" in w for w in warnings)
    assert not any("health.steps" in w for w in warnings)


def test_chart_bounds_bindings_are_checked_like_any_value():
    errors, warnings = ws.validate_design(_design(presentations={"small": {
        "type": "chart", "series": [1, 2], "min": {"src": "health.floor"}, "max": {"bogus": 1}}}),
        catalog_keys={"health.steps"})
    assert any("max" in e and "binding" in e for e in errors), errors
    assert any("health.floor" in w for w in warnings)


def test_no_catalog_yet_is_one_warning():
    _, warnings = ws.validate_design(_design(), catalog_keys=set())
    assert len(warnings) == 1 and "catalog" in warnings[0]


def test_no_warnings_when_every_key_is_known():
    _, warnings = ws.validate_design(_design(), catalog_keys={"health.steps"})
    assert warnings == []


def test_island_validation_is_unchanged_by_the_widget_rules():
    chart_on_island = {"id": "i", "name": "I", "presentations": {
        "expanded": {"type": "chart", "series": [1, 2]}}}
    assert any("unknown node type" in e for e in island_schema.validate_design(chart_on_island))
    assert island_schema.validate_condition({"op": "gt", "a": {"src": "battery.level"}, "b": 1}) == []
    assert island_schema.validate_condition({"op": "gt", "a": {"src": "x5ring.battery"}, "b": 1})


# ── catalog validation ──────────────────────────────────────────────────────

def test_catalog_entries_are_validated():
    assert ws.validate_catalog(CATALOG) == []
    assert ws.validate_catalog("nope")
    assert ws.validate_catalog([{"label": "No key", "area": "health", "kind": "number"}])
    assert ws.validate_catalog([{"key": "steps", "label": "S", "area": "health", "kind": "number"}])
    assert ws.validate_catalog([{"key": "a.b", "label": "S", "area": "a", "kind": "number", "unit": 5}])


# ── store ────────────────────────────────────────────────────────────────────

def test_upsert_numbers_versions_and_ignores_the_client_version(store):
    saved, errors, _ = store.upsert_design(_design(version=40))
    assert errors == [] and saved["version"] == 1
    saved, _, _ = store.upsert_design(_design(name="Steps today"))
    assert saved["version"] == 2 and saved["name"] == "Steps today"
    assert store.get_design("steps")["version"] == 2


def test_upsert_defaults_the_schema(store):
    design = _design()
    del design["schema"]
    saved, errors, _ = store.upsert_design(design)
    assert errors == [] and saved["schema"] == 1


def test_invalid_designs_are_not_stored(store):
    saved, errors, _ = store.upsert_design(_design(presentations={"huge": {"type": "text", "value": "x"}}))
    assert saved is None and errors
    assert store.list_designs() == []


def test_list_get_delete(store):
    store.upsert_design(_design("b"))
    store.upsert_design(_design("a"))
    assert [d["id"] for d in store.list_designs()] == ["a", "b"]
    assert store.get_design("missing") is None
    assert store.delete_design("a") is True
    assert store.delete_design("a") is False
    assert [d["id"] for d in store.list_designs()] == ["b"]


def test_a_deleted_design_starts_again_at_version_one(store):
    store.upsert_design(_design())
    store.upsert_design(_design())
    store.delete_design("steps")
    saved, _, _ = store.upsert_design(_design())
    assert saved["version"] == 1


def test_catalog_round_trip(store):
    assert store.get_catalog() == []
    ok, errors = store.set_catalog(CATALOG)
    assert ok and errors == []
    assert store.get_catalog() == CATALOG
    assert WidgetStore(store.root).get_catalog() == CATALOG  # persisted
    ok, errors = store.set_catalog([{"key": "bad"}])
    assert not ok and errors
    assert store.get_catalog() == CATALOG  # a bad post keeps the old one


def test_upsert_warns_against_the_stored_catalog(store):
    store.set_catalog(CATALOG)
    _, errors, warnings = store.upsert_design(_design(presentations={
        "small": {"type": "stat", "value": {"src": "scale.weight"}}}))
    assert errors == [] and any("scale.weight" in w for w in warnings)


def test_profiles_are_kept_apart(tmp_path):
    WidgetStore(tmp_path, "work").upsert_design(_design())
    assert WidgetStore(tmp_path, "home").list_designs() == []


def test_corrupt_files_read_as_empty(store):
    store.upsert_design(_design())
    (store.base / "designs" / "steps.json").write_text("{not json")
    (store.base / "catalog.json").parent.mkdir(parents=True, exist_ok=True)
    (store.base / "catalog.json").write_text("[oops")
    assert store.get_design("steps") is None
    assert store.list_designs() == []
    assert store.get_catalog() == []


# ── routes ───────────────────────────────────────────────────────────────────

def test_get_designs_returns_designs_and_catalog(store):
    store.set_catalog(CATALOG)
    store.upsert_design(_design())
    status, payload = H("GET", "/designs", None, store)
    assert status == 200
    assert set(payload) == {"designs", "catalog"}
    assert [d["id"] for d in payload["designs"]] == ["steps"]
    assert payload["catalog"] == CATALOG


def test_post_design_then_get_it(store):
    status, payload = H("POST", "/designs", _design(), store)
    assert status == 200
    assert payload["ok"] is True and payload["design"]["version"] == 1
    assert isinstance(payload["warnings"], list)
    status, payload = H("GET", "/designs/steps", None, store)
    assert status == 200 and payload == {"ok": True, "design": store.get_design("steps")}


def test_post_again_bumps_the_version(store):
    H("POST", "/designs", _design(), store)
    status, payload = H("POST", "/designs", _design(), store)
    assert status == 200 and payload["design"]["version"] == 2


def test_post_wrapped_design(store):
    status, payload = H("POST", "/designs", {"design": _design("wrapped")}, store)
    assert status == 200 and payload["design"]["id"] == "wrapped"


@pytest.mark.parametrize("body", [
    _design(presentations={}),
    _design(presentations={"small": {"type": "chart"}}),
    {"id": "x"},
    None,
])
def test_post_invalid_design_is_400_with_errors(store, body):
    status, payload = H("POST", "/designs", body, store)
    assert status == 400
    assert payload["ok"] is False and payload["errors"]
    assert store.list_designs() == []


def test_post_returns_catalog_warnings(store):
    store.set_catalog(CATALOG)
    status, payload = H("POST", "/designs", _design(presentations={
        "small": {"type": "stat", "value": {"src": "pod.battery"}}}), store)
    assert status == 200 and any("pod.battery" in w for w in payload["warnings"])


def test_get_missing_design_is_404(store):
    status, payload = H("GET", "/designs/ghost", None, store)
    assert status == 404 and "error" in payload


def test_delete_design(store):
    H("POST", "/designs", _design(), store)
    status, payload = H("DELETE", "/designs/steps", None, store)
    assert status == 200 and payload["ok"] is True
    status, payload = H("DELETE", "/designs/steps", None, store)
    assert status == 404 and "error" in payload


def test_post_delete_alias(store):
    H("POST", "/designs", _design(), store)
    status, payload = H("POST", "/designs/steps/delete", {}, store)
    assert status == 200 and payload["ok"] is True
    assert store.get_design("steps") is None


def test_catalog_routes(store):
    assert H("GET", "/catalog", None, store) == (200, {"catalog": []})
    status, payload = H("POST", "/catalog", {"catalog": CATALOG}, store)
    assert (status, payload) == (200, {"ok": True})
    assert H("GET", "/catalog", None, store) == (200, {"catalog": CATALOG})


@pytest.mark.parametrize("body", [{"catalog": "nope"}, {}, {"catalog": [{"key": 1}]}])
def test_post_bad_catalog_is_400(store, body):
    status, payload = H("POST", "/catalog", body, store)
    assert status == 400 and payload["ok"] is False and payload["errors"]


def test_trailing_slash_and_query_are_tolerated(store):
    assert H("GET", "/designs/?fresh=1", None, store)[0] == 200
    assert H("GET", "/catalog?x=1", None, store)[0] == 200


@pytest.mark.parametrize("method, path, status", [
    ("GET", "/nope", 404),
    ("POST", "/nope", 404),
    ("DELETE", "/catalog", 404),
    ("PUT", "/designs", 405),
])
def test_unknown_endpoints(store, method, path, status):
    assert H(method, path, {}, store)[0] == status
