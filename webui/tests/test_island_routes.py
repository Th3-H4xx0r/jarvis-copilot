"""Unit tests for the island REST dispatcher (api.island_routes).

Pure: a real IslandStore on tmp_path + a fake token store. Run from webui/:
    cd webui && python3 -m pytest tests/test_island_routes.py
"""
from __future__ import annotations

import pytest

from api.island_routes import handle_island_request as H
from api.island_store import IslandStore


def _design(did="deploy"):
    return {"id": did, "version": 1, "name": "Deploy",
            "presentations": {"expanded": {"type": "text", "value": "hi"}}}


@pytest.fixture()
def store(tmp_path):
    return IslandStore(tmp_path)


def test_get_designs_snapshot(store):
    status, payload = H("GET", "/designs", None, store)
    assert status == 200
    assert {"designs", "catalog", "selection"} <= set(payload)


def test_post_upsert_valid_and_get_single(store):
    status, payload = H("POST", "/designs", _design(), store)
    assert status == 200 and payload["ok"] and payload["id"] == "deploy"
    status, payload = H("GET", "/designs/deploy", None, store)
    assert status == 200 and payload["design"]["name"] == "Deploy"


def test_post_upsert_wrapped_in_design_key(store):
    status, payload = H("POST", "/designs", {"design": _design("x")}, store)
    assert status == 200 and payload["id"] == "x"


def test_post_upsert_invalid_400(store):
    status, payload = H("POST", "/designs", {"id": "x", "presentations": {}}, store)
    assert status == 400 and "errors" in payload


def test_post_upsert_missing_presentations_400(store):
    status, payload = H("POST", "/designs", {"id": "x"}, store)
    assert status == 400


def test_get_single_404(store):
    status, _ = H("GET", "/designs/ghost", None, store)
    assert status == 404


def test_selection_pinned_and_auto(store):
    H("POST", "/designs", _design(), store)
    status, payload = H("POST", "/selection",
                        {"mode": "pinned", "pinnedId": "deploy"}, store)
    assert status == 200 and payload["selection"]["pinnedId"] == "deploy"
    status, _ = H("POST", "/selection", {"mode": "auto"}, store)
    assert status == 200


def test_selection_invalid_400(store):
    status, _ = H("POST", "/selection", {"mode": "pinned"}, store)  # no pinnedId
    assert status == 400


def test_rules_ok_and_unknown(store):
    H("POST", "/designs", _design(), store)
    status, _ = H("POST", "/designs/deploy/rules",
                  {"enabled": False, "priority": 3}, store)
    assert status == 200
    status, _ = H("POST", "/designs/ghost/rules", {"enabled": True}, store)
    assert status == 404


def test_data_sets_values(store):
    H("POST", "/designs", _design(), store)
    status, payload = H("POST", "/designs/deploy/data",
                        {"pct": 62, "state": "running"}, store)
    assert status == 200 and payload["data"]["pct"] == 62
    assert store.get_data("deploy")["state"] == "running"


def test_data_wrapped_and_design_missing(store):
    H("POST", "/designs", _design(), store)
    status, payload = H("POST", "/designs/deploy/data", {"data": {"k": 1}}, store)
    assert status == 200 and payload["data"]["k"] == 1
    status, _ = H("POST", "/designs/ghost/data", {"k": 1}, store)
    assert status == 404


def test_data_triggers_push_when_pinned(store):
    H("POST", "/designs", _design(), store)
    H("POST", "/selection", {"mode": "pinned", "pinnedId": "deploy"}, store)

    class FakeTokenStore:
        def list_la_tokens(self):
            return [{"token": "abc"}]

        def delete_la_token(self, t):
            pass

    # token_store present + pinned → push module runs; sender import may no-op in
    # test env, so just assert the route stays 200 and reports a 'pushed' count.
    status, payload = H("POST", "/designs/deploy/data", {"pct": 1}, store,
                        token_store=FakeTokenStore())
    assert status == 200 and "pushed" in payload


def test_rules_bad_priority_returns_400(store):
    H("POST", "/designs", _design(), store)
    status, _ = H("POST", "/designs/deploy/rules", {"priority": "abc"}, store)
    assert status == 400  # not a 500


def test_pin_custom_triggers_push(store):
    H("POST", "/designs", _design(), store)

    class FakeTokenStore:
        def list_la_tokens(self):
            return [{"token": "abc"}]

        def delete_la_token(self, t):
            pass

    status, payload = H("POST", "/selection",
                        {"mode": "pinned", "pinnedId": "deploy"}, store,
                        token_store=FakeTokenStore())
    assert status == 200 and "pushed" in payload


def test_delete_and_post_delete(store):
    H("POST", "/designs", _design(), store)
    status, _ = H("DELETE", "/designs/deploy", None, store)
    assert status == 200
    H("POST", "/designs", _design("d2"), store)
    status, _ = H("POST", "/designs/d2/delete", None, store)
    assert status == 200


def test_delete_missing_404(store):
    status, _ = H("DELETE", "/designs/ghost", None, store)
    assert status == 404


def test_unknown_endpoint_404(store):
    status, _ = H("GET", "/bogus", None, store)
    assert status == 404


def test_method_not_allowed_405(store):
    status, _ = H("PATCH", "/designs", {}, store)
    assert status == 405
