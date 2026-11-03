"""An integration's own UI over HTTP: the definition, its state, actions and cards."""
from __future__ import annotations

import json
import sys
from pathlib import Path
from urllib.parse import urlparse

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import api.helpers as helpers  # noqa: E402
import api.integrations_routes as routes  # noqa: E402
import jarvis_registry.store as store  # noqa: E402
from jarvis_registry import Registry, ui  # noqa: E402

LOAD = (
    "from jarvis_registry import ui_script as u\n"
    "items = u.space().get('items', default=[])\n"
    "u.reply({'items': items, 'count': len(items)})\n"
)
ADD = (
    "from jarvis_registry import ui_script as u\n"
    "name = (u.inputs().get('new_item') or '').strip()\n"
    "if not name:\n"
    "    u.fail('Type something to add')\n"
    "s = u.space()\n"
    "s.put('items', s.get('items', default=[]) + [{'name': name}])\n"
    "u.reply(toast='Added ' + name)\n"
)


def doc(card: bool = True, load: str = LOAD) -> dict:
    presentations = {
        "page": {"type": "vstack", "children": [
            {"type": "textField", "id": "new_item", "submit": "add_item"},
            {"type": "list", "data": {"$": "items"},
             "row": {"type": "row", "title": {"$row": "name"}}},
        ]},
    }
    if card:
        presentations["card"] = {"type": "hstack", "children": [
            {"type": "stat", "value": {"$": "count"}},
            {"type": "button", "label": "Add", "action": "add_item"},
        ]}
    return {"schema": 1, "presentations": presentations,
            "scripts": {"load": {"code": load},
                        "add_item": {"code": ADD, "confirm": "Add it?"}}}


@pytest.fixture()
def sent(monkeypatch):
    box: dict = {}

    def fake_j(handler, body, status=200):
        box["body"] = json.loads(json.dumps(body))     # must be plain JSON
        box["status"] = status
        return True

    monkeypatch.setattr(helpers, "j", fake_j)
    return box


@pytest.fixture()
def reg(tmp_path, monkeypatch):
    r = Registry(tmp_path / "registry.db")
    monkeypatch.setattr(store, "shared", lambda: r)
    monkeypatch.setattr("cron.jobs.list_jobs", lambda include_disabled=False: [])
    ui._reset_cache()
    yield r
    r.close()


def get(path):
    return routes.handle_get(object(), urlparse(path))


def post(path, body):
    return routes.handle_post(object(), urlparse(path), body)


def test_an_integration_without_a_ui(reg, sent):
    reg.space("shop", name="Shopping")
    assert get("/api/integrations/shop/ui") is True
    assert sent["status"] == 200
    assert sent["body"] == {"space": "shop", "version": None, "definition": None,
                            "state": {}, "error": None}


def test_the_ui_comes_with_its_state_and_without_code(reg, sent):
    reg.space("shop", name="Shopping").put("items", [{"name": "Milk"}])
    ui.save_ui("shop", doc())
    assert get("/api/integrations/shop/ui") is True
    body = sent["body"]
    assert body["space"] == "shop" and body["version"] == 1 and body["error"] is None
    assert body["state"] == {"items": [{"name": "Milk"}], "count": 1}
    assert body["definition"]["scripts"] == {"load": {}, "add_item": {"confirm": "Add it?"}}
    assert "code" not in json.dumps(body["definition"])
    assert body["definition"]["presentations"]["card"]["type"] == "hstack"


def test_an_unknown_integration_is_404(reg, sent):
    assert get("/api/integrations/nope/ui") is True
    assert sent["status"] == 404
    assert post("/api/integrations/nope/ui/action", {"action": "x"}) is True
    assert sent["status"] == 404


def test_an_action_runs_its_script(reg, sent):
    reg.space("shop", name="Shopping")
    ui.save_ui("shop", doc())
    assert post("/api/integrations/shop/ui/action",
                {"action": "add_item", "control": "new_item", "value": None,
                 "inputs": {"new_item": "Eggs"}, "row": None, "version": 1}) is True
    assert sent["status"] == 200
    assert sent["body"] == {"ok": True, "version": 1,
                            "state": {"items": [{"name": "Eggs"}], "count": 1},
                            "toast": "Added Eggs", "error": None}


def test_a_failing_action_says_why(reg, sent):
    reg.space("shop", name="Shopping")
    ui.save_ui("shop", doc())
    assert post("/api/integrations/shop/ui/action",
                {"action": "add_item", "inputs": {}}) is True
    assert sent["status"] == 200
    assert sent["body"]["ok"] is False
    assert sent["body"]["error"] == "Type something to add"

    assert post("/api/integrations/shop/ui/action", {"action": "explode"}) is True
    assert sent["body"]["ok"] is False and "explode" in sent["body"]["error"]

    assert post("/api/integrations/shop/ui/action", {}) is True
    assert sent["status"] == 400


def test_cards_keep_paused_skip_cardless_and_carry_errors(reg, sent):
    reg.space("shop", name="Shopping", icon="cart")
    ui.save_ui("shop", doc())
    reg.space("paused", name="Paused")
    ui.save_ui("paused", doc())
    reg.set_status("paused", "paused")
    reg.space("archived", name="Archived")
    ui.save_ui("archived", doc())
    reg.set_status("archived", "archived")
    reg.space("pageonly", name="Page only")
    ui.save_ui("pageonly", doc(card=False))
    reg.space("broken", name="Broken")
    ui.save_ui("broken", doc(load="import sys\nsys.stderr.write('kaput')\nsys.exit(2)\n"))

    assert get("/api/integration-cards") is True
    cards = {c["id"]: c for c in sent["body"]["cards"]}
    assert set(cards) == {"shop", "broken", "paused"}
    shop = cards["shop"]
    assert shop == {"id": "shop", "name": "Shopping", "icon": "cart", "version": 1,
                    "card": doc()["presentations"]["card"],
                    "state": {"items": [], "count": 0}, "error": None,
                    "confirms": {"add_item": "Add it?"}}
    assert "kaput" in cards["broken"]["error"]


def test_the_list_and_detail_know_about_the_ui_and_hide_its_document(reg, sent):
    space = reg.space("shop", name="Shopping")
    space.put("settings", {"a": 1})
    ui.save_ui("shop", doc())
    reg.space("plain", name="Plain")

    assert get("/api/integrations") is True
    rows = {r["id"]: r for r in sent["body"]["integrations"]}
    assert rows["shop"]["has_ui"] is True
    assert rows["plain"]["has_ui"] is False
    assert rows["shop"]["document_count"] == 1

    assert get("/api/integrations/shop") is True
    assert sent["body"]["has_ui"] is True
    assert [d["key"] for d in sent["body"]["documents"]] == ["settings"]


def test_ui_is_not_an_integration_id(reg, sent):
    assert post("/api/integrations", {"name": "UI"}) is True
    assert sent["status"] == 400


def test_the_server_routes_cards_here():
    src = (Path(__file__).resolve().parents[1] / "api" / "routes.py").read_text()
    assert '"/api/integration-cards"' in src
