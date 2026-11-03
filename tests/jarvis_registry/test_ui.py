"""Integration UI: the stored definition, its validation and the scripts it runs."""
from __future__ import annotations

import copy
import json

import pytest

import jarvis_registry.store as store
from jarvis_registry import Registry
from jarvis_registry import ui


@pytest.fixture()
def reg(tmp_path, monkeypatch):
    r = Registry(tmp_path / "registry.db")
    monkeypatch.setattr(store, "shared", lambda: r)
    ui._reset_cache()
    yield r
    r.close()


LOAD = (
    "from jarvis_registry import ui_script as u\n"
    "items = u.space().get('items', default=[])\n"
    "u.reply({'items': items, 'count': len(items)})\n"
)
ADD = (
    "from jarvis_registry import ui_script as u\n"
    "s = u.space()\n"
    "items = s.get('items', default=[])\n"
    "items.append({'name': u.inputs().get('new_item', '')})\n"
    "s.put('items', items)\n"
    "u.reply(toast='Added')\n"
)


def good_doc() -> dict:
    return {
        "schema": 1,
        "presentations": {
            "card": {"type": "vstack", "children": [
                {"type": "stat", "value": {"$": "count"}, "unit": "items"},
                {"type": "button", "label": "Add", "action": "add_item"},
            ]},
            "page": {"type": "vstack", "children": [
                {"type": "section", "title": "Add", "children": [
                    {"type": "textField", "id": "new_item", "placeholder": "Milk",
                     "submit": "add_item"},
                ]},
                {"type": "section", "title": "Items", "children": [
                    {"type": "list", "data": {"$": "items"},
                     "row": {"type": "row", "title": {"$row": "name"},
                             "swipe": [{"label": "Delete", "action": "add_item",
                                        "role": "destructive"}]}},
                ]},
                {"type": "grid", "columns": 3, "children": [
                    {"type": "stat", "value": {"$": "count"}, "span": 2},
                    {"type": "gauge", "rings": [{"value": 0.5}]},
                ]},
            ]},
        },
        "scripts": {"load": {"code": LOAD},
                    "add_item": {"code": ADD, "confirm": "Add it?", "label": "Add item"}},
        "prompt": "a shopping list",
    }


# ── validation ───────────────────────────────────────────────────────────────
def test_a_good_document_passes():
    errors, _warnings = ui.validate_ui(good_doc())
    assert errors == []


def test_load_is_required():
    doc = good_doc()
    del doc["scripts"]["load"]
    errors, _ = ui.validate_ui(doc)
    assert any("load" in e for e in errors)


def test_an_action_needs_its_script():
    doc = good_doc()
    doc["presentations"]["card"]["children"][1]["action"] = "remove_all"
    errors, _ = ui.validate_ui(doc)
    assert any("remove_all" in e for e in errors)


def test_unknown_node_types_are_refused():
    doc = good_doc()
    doc["presentations"]["card"]["children"].append({"type": "webview"})
    errors, _ = ui.validate_ui(doc)
    assert any("webview" in e for e in errors)


def test_regions_is_island_only():
    doc = good_doc()
    doc["presentations"]["card"] = {"type": "regions", "leading": {"type": "text", "value": "x"}}
    errors, _ = ui.validate_ui(doc)
    assert any("regions" in e for e in errors)


def test_the_card_has_a_node_cap():
    doc = good_doc()
    doc["presentations"]["card"] = {"type": "vstack", "children": [
        {"type": "text", "value": str(i)} for i in range(ui.MAX_CARD_NODES + 5)]}
    errors, _ = ui.validate_ui(doc)
    assert any("too many nodes" in e for e in errors)


def test_at_least_one_presentation():
    doc = good_doc()
    doc["presentations"] = {}
    errors, _ = ui.validate_ui(doc)
    assert errors


def test_input_ids_are_unique_and_slugs():
    doc = good_doc()
    page = doc["presentations"]["page"]["children"]
    page.append({"type": "textField", "id": "new_item"})
    page.append({"type": "slider", "id": "Bad Id", "min": 0, "max": 10})
    errors, _ = ui.validate_ui(doc)
    assert any("new_item" in e and "unique" in e for e in errors)
    assert any("Bad Id" in e for e in errors)


def test_span_must_fit_the_grid():
    doc = good_doc()
    doc["presentations"]["page"]["children"][2]["children"][0]["span"] = 4
    errors, _ = ui.validate_ui(doc)
    assert any("span" in e for e in errors)


def test_row_bindings_only_inside_a_list():
    doc = good_doc()
    doc["presentations"]["card"]["children"].append({"type": "text", "value": {"$row": "name"}})
    errors, _ = ui.validate_ui(doc)
    assert any("$row" in e for e in errors)


def test_button_needs_an_action():
    doc = good_doc()
    del doc["presentations"]["card"]["children"][1]["action"]
    errors, _ = ui.validate_ui(doc)
    assert any("action" in e for e in errors)


def test_validation_never_mutates_or_raises():
    doc = good_doc()
    before = copy.deepcopy(doc)
    ui.validate_ui(doc)
    assert doc == before
    for junk in (None, [], "x", {"presentations": "x", "scripts": 3}):
        errors, _ = ui.validate_ui(junk)
        assert errors


# ── storage ──────────────────────────────────────────────────────────────────
def test_save_bumps_the_version_and_refuses_invalid(reg):
    reg.space("shop", name="Shopping")
    first = ui.save_ui("shop", good_doc())
    second = ui.save_ui("shop", good_doc())
    assert second["version"] == first["version"] + 1
    assert second["updated_at"].endswith("Z")
    assert ui.get_ui("shop")["version"] == second["version"]

    bad = good_doc()
    del bad["scripts"]["load"]
    with pytest.raises(ui.UIError) as caught:
        ui.save_ui("shop", bad)
    assert caught.value.errors
    assert ui.get_ui("shop")["version"] == second["version"]


def test_public_definition_drops_code_but_keeps_confirm_and_label(reg):
    reg.space("shop", name="Shopping")
    doc = ui.save_ui("shop", good_doc())
    public = ui.public_definition(doc)
    assert "code" not in json.dumps(public["scripts"])
    assert public["scripts"]["add_item"] == {"confirm": "Add it?", "label": "Add item"}
    assert public["scripts"]["load"] == {}
    assert public["presentations"] == doc["presentations"]
    assert "code" in doc["scripts"]["load"]          # the stored doc is untouched


# ── running scripts ──────────────────────────────────────────────────────────
def test_load_reads_the_space(reg):
    reg.space("shop", name="Shopping").put("items", [{"name": "Milk"}])
    ui.save_ui("shop", good_doc())
    out = ui.load_state("shop")
    assert out["error"] is None
    assert out["state"] == {"items": [{"name": "Milk"}], "count": 1}
    assert out["version"] == 1


def test_an_action_without_state_reruns_load(reg):
    reg.space("shop", name="Shopping")
    ui.save_ui("shop", good_doc())
    out = ui.run_action("shop", "add_item", {"inputs": {"new_item": "Eggs"}})
    assert out["ok"] is True, out
    assert out["toast"] == "Added"
    assert out["state"]["items"] == [{"name": "Eggs"}]
    assert reg.open("shop").get("items") == [{"name": "Eggs"}]


def test_a_failing_script_reports_its_stderr(reg):
    reg.space("shop", name="Shopping")
    doc = good_doc()
    doc["scripts"]["add_item"]["code"] = "import sys\nsys.stderr.write('boom happened')\nsys.exit(1)\n"
    ui.save_ui("shop", doc)
    out = ui.run_action("shop", "add_item", {})
    assert out["ok"] is False
    assert "boom happened" in out["error"]


def test_a_slow_script_times_out(reg):
    reg.space("shop", name="Shopping")
    doc = good_doc()
    doc["scripts"]["load"]["code"] = "import time\ntime.sleep(10)\n"
    ui.save_ui("shop", doc)
    out = ui.load_state("shop", timeout=1)
    assert out["error"] and "1" in out["error"]
    assert out["state"] == {}


def test_unknown_action(reg):
    reg.space("shop", name="Shopping")
    ui.save_ui("shop", good_doc())
    out = ui.run_action("shop", "explode", {})
    assert out["ok"] is False and "explode" in out["error"]


def test_logs_before_the_json_line_are_ignored(reg):
    reg.space("shop", name="Shopping")
    doc = good_doc()
    doc["scripts"]["load"]["code"] = (
        "print('loading...')\nprint('{not json')\nprint(); print('{\"state\": {\"n\": 2}}')\nprint('')\n")
    ui.save_ui("shop", doc)
    out = ui.load_state("shop")
    assert out == {"state": {"n": 2}, "error": None, "version": 1}


def test_bad_json_is_an_error_and_keeps_the_last_good_state(reg):
    reg.space("shop", name="Shopping").put("items", [{"name": "Milk"}])
    ui.save_ui("shop", good_doc())
    assert ui.load_state("shop")["state"]["count"] == 1
    doc = good_doc()
    doc["scripts"]["load"]["code"] = "print('nothing useful')\n"
    ui.save_ui("shop", doc)
    out = ui.load_state("shop")
    assert out["error"]
    assert out["state"]["count"] == 1


def test_the_action_sees_the_event_and_last_state(reg):
    reg.space("shop", name="Shopping")
    doc = good_doc()
    doc["scripts"]["add_item"]["code"] = (
        "from jarvis_registry import ui_script as u\n"
        "u.reply({'event': u.event(), 'prev': u.state(), 'row': u.row(),"
        " 'space': u.integration()})\n")
    ui.save_ui("shop", doc)
    ui.load_state("shop")
    out = ui.run_action("shop", "add_item", {"control": "x", "value": 3,
                                             "inputs": {"a": 1}, "row": {"name": "Milk"}})
    assert out["ok"] is True
    state = out["state"]
    assert state["event"] == {"action": "add_item", "control": "x", "value": 3,
                              "inputs": {"a": 1}, "row": {"name": "Milk"}}
    assert state["prev"] == {"items": [], "count": 0}
    assert state["row"] == {"name": "Milk"}
    assert state["space"] == "shop"


def test_fail_helper_reports_its_message(reg):
    reg.space("shop", name="Shopping")
    doc = good_doc()
    doc["scripts"]["add_item"]["code"] = (
        "from jarvis_registry import ui_script as u\nu.fail('Type a name first')\n")
    ui.save_ui("shop", doc)
    out = ui.run_action("shop", "add_item", {})
    assert out == {"ok": False, "state": {}, "toast": None,
                   "error": "Type a name first", "version": 1}


def test_cards_for_live_integrations_with_a_card(reg):
    reg.space("shop", name="Shopping", icon="cart")
    ui.save_ui("shop", good_doc())

    reg.space("paused", name="Paused")
    ui.save_ui("paused", good_doc())
    reg.set_status("paused", "paused")

    reg.space("pageonly", name="Page only")
    page_only = good_doc()
    del page_only["presentations"]["card"]
    ui.save_ui("pageonly", page_only)

    reg.space("broken", name="Broken")
    broken = good_doc()
    broken["scripts"]["load"]["code"] = "raise SystemExit(3)\n"
    ui.save_ui("broken", broken)

    reg.space("plain", name="Plain")

    reg.space("gone", name="Archived")
    ui.save_ui("gone", good_doc())
    reg.set_status("gone", "archived")

    cards = ui.cards()
    by_id = {c["id"]: c for c in cards}
    assert set(by_id) == {"shop", "broken", "paused"}
    assert by_id["shop"]["state"]["count"] == 0 and by_id["shop"]["error"] is None
    assert by_id["shop"]["icon"] == "cart" and by_id["shop"]["name"] == "Shopping"
    assert by_id["shop"]["card"]["type"] == "vstack"
    assert by_id["shop"]["confirms"] == {"add_item": "Add it?"}
    assert by_id["broken"]["error"]


def test_an_action_named_like_a_stdlib_module_does_not_hijack_load(reg):
    # `json` / `random` as action names used to shadow the stdlib for every script
    # in the space (the script folder sat first on sys.path).
    reg.space("shop", name="Shop")
    doc = good_doc()
    doc["scripts"]["json"] = {"code": "raise SystemExit('json ran')"}
    doc["scripts"]["random"] = {"code": "raise SystemExit('random ran')"}
    ui.save_ui("shop", doc)
    assert ui.run_action("shop", "json")["error"]       # create both files on disk
    assert ui.run_action("shop", "random")["error"]
    out = ui.load_state("shop")
    assert out["error"] is None
    assert out["state"] == {"items": [], "count": 0}


def test_runaway_output_is_capped(reg, monkeypatch):
    monkeypatch.setattr(ui, "MAX_OUTPUT_BYTES", 10_000)
    reg.space("shop", name="Shop")
    doc = good_doc()
    doc["scripts"]["spam"] = {"code": "import sys\nwhile True:\n    sys.stdout.write('x' * 4096)\n"}
    ui.save_ui("shop", doc)
    out = ui.run_action("shop", "spam", timeout=20)
    assert out["ok"] is False
    assert "printed more than" in out["error"]
