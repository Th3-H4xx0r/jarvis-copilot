"""POST /api/harnesses/assign for the one default and the Voice/Chat overrides (2026-10-12):
"can you add support for a harness to be used as the default instead of it being a single model only"."""
import json

import pytest

from api.harness_routes import handle_harness_request
from api.harness_store import HarnessStore

DESIGN = {"id": "mine", "name": "Mine", "nodes": [
    {"id": "in", "type": "message", "x": 0, "y": 0},
    {"id": "a", "type": "answer", "model": "@session", "x": 200, "y": 0}],
    "edges": [{"from": "in", "to": "a", "when": "always"}]}


@pytest.fixture
def store(tmp_path):
    s = HarnessStore(tmp_path, "default")
    saved, errors = s.upsert_design(dict(DESIGN))
    assert not errors, errors
    return s


def _assign(store, surface, hid):
    return handle_harness_request("POST", "/assign", {"surface": surface, "harness_id": hid}, store)


def test_set_the_default_to_a_harness(store):
    status, body = _assign(store, "default", "mine")
    assert status == 200 and body["assignments"]["default"] == "mine"
    assert body["assignments"]["chat"] == "mine" and body["overrides"]["chat"] == ""
    assert json.loads(store._assign_path.read_text())["default"] == "mine"


def test_clear_an_override_with_empty(store):
    _assign(store, "default", "mine")
    status, body = _assign(store, "voice", "")
    assert status == 200 and body["overrides"]["voice"] == "" and body["assignments"]["voice"] == "mine"


@pytest.mark.parametrize("surface, hid", [("default", ""), ("default", "nope"), ("voice", "nope"),
                                          ("pod", "mine"), (None, "mine"), ("chat", 7)])
def test_refuses_bad_assignments(store, surface, hid):
    status, _ = _assign(store, surface, hid)
    assert status == 400


def test_deleting_the_default_or_an_override_falls_back(store):
    _assign(store, "default", "mine")
    _assign(store, "chat", "mine")
    assert store.delete_design("mine")
    stored = json.loads(store._assign_path.read_text())
    assert stored["default"] == "single" and stored["chat"] == ""
    assert store.effective("chat") == "single"


def test_snapshot_has_overrides_and_effective_assignments(store):
    status, body = handle_harness_request("GET", "", {}, store)
    assert status == 200 and set(body["overrides"]) == {"voice", "chat"}
    assert body["assignments"]["chat"]  # never "" for clients that predate the one default
