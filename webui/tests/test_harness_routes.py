from api.harness_routes import handle_harness_request
from api.harness_store import HarnessStore

DOC = {"id": "mine", "name": "Mine", "nodes": [
    {"id": "in", "type": "message"}, {"id": "a", "type": "answer", "model": "@x:y"}],
    "edges": [{"from": "in", "to": "a"}]}


def test_list(tmp_path):
    status, body = handle_harness_request("GET", "", None, HarnessStore(tmp_path))
    assert status == 200 and {h["id"] for h in body["harnesses"]} >= {"single", "fast-claude"}
    assert body["assignments"]["voice"] == "fast-claude"


def test_upsert_and_delete(tmp_path):
    st = HarnessStore(tmp_path)
    status, body = handle_harness_request("POST", "/designs", {"design": DOC}, st)
    assert status == 200 and body["design"]["version"] == 1
    assert handle_harness_request("POST", "/designs/mine/delete", {}, st)[0] == 200
    assert handle_harness_request("DELETE", "/designs/mine", None, st)[0] == 404


def test_upsert_invalid_returns_errors(tmp_path):
    status, body = handle_harness_request("POST", "/designs", {"design": {"id": "x"}}, HarnessStore(tmp_path))
    assert status == 400 and body["errors"]


def test_assign(tmp_path):
    st = HarnessStore(tmp_path)
    status, body = handle_harness_request("POST", "/assign", {"surface": "chat", "harness_id": "router"}, st)
    assert status == 200 and body["assignments"]["chat"] == "router"
    assert handle_harness_request("POST", "/assign", {"surface": "chat", "harness_id": "zzz"}, st)[0] == 400


def test_unknown_endpoint(tmp_path):
    assert handle_harness_request("GET", "/nope", None, HarnessStore(tmp_path))[0] == 404


def test_session_harness_field_round_trips():
    import api.models as models
    s = models.Session(session_id="abc123", harness_id="router")
    assert s.harness_id == "router" and s.compact()["harness_id"] == "router"


def test_routes_dispatch_harness_endpoints():
    import inspect
    import api.routes as routes
    src = inspect.getsource(routes)
    assert src.count("handle_harness_request(") >= 3  # GET, POST, DELETE
    assert '"/api/session/harness"' in src
    assert "_turn_harness_id" in src and "_turn_explicit_model" in src
