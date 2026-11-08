"""The mount table: every feature prefix reaches its module for every HTTP method."""
import importlib
import io
import json
from urllib.parse import urlparse

import pytest

from api import mounts, routes

METHODS = {
    "GET": routes.handle_get,
    "POST": routes.handle_post,
    "PUT": routes.handle_put,
    "PATCH": routes.handle_patch,
    "DELETE": routes.handle_delete,
}


class _Handler:
    def __init__(self, body=None, *, raw_only=False):
        data = json.dumps(body).encode() if body is not None else b""
        self.headers = {"Content-Length": str(len(data))}
        self.rfile = _Unreadable() if raw_only else io.BytesIO(data)
        self.wfile = io.BytesIO()
        self.client_address = ("127.0.0.1", 0)
        self.command = "GET"
        self.status = None

    def send_response(self, status):
        self.status = status

    def send_header(self, *_):
        pass

    def end_headers(self):
        pass


class _Unreadable:
    def read(self, *_):
        raise AssertionError("the body was parsed before the raw-body route ran")


@pytest.fixture
def recorded(monkeypatch):
    monkeypatch.setattr(routes, "check_csrf", lambda handler: True)
    seen = []

    def recorder(module):
        def route(req):
            seen.append((module, req.method, req.prefix, req.sub_with_query))
            return True
        return route

    for _, module in mounts.MOUNTS:
        monkeypatch.setattr(importlib.import_module(module), "route", recorder(module))
    return seen


@pytest.mark.parametrize("prefix,module", mounts.MOUNTS)
@pytest.mark.parametrize("method", METHODS)
def test_every_method_reaches_the_owning_module(recorded, method, prefix, module):
    handled = METHODS[method](_Handler({}), urlparse(f"{prefix}/thing?x=1"))
    assert handled is True
    assert recorded == [(module, method, prefix, "/thing?x=1")]


def test_a_sibling_path_is_not_swallowed_by_a_prefix(recorded):
    routes.handle_get(_Handler(), urlparse("/api/carpool"))
    assert recorded == []


def test_raw_body_routes_run_before_any_json_parse(monkeypatch):
    monkeypatch.setattr(routes, "check_csrf", lambda handler: True)
    import api.screen_share as screen_share
    monkeypatch.setattr(screen_share, "handle_post", lambda handler, parsed: True)
    assert routes.handle_post(_Handler(raw_only=True), urlparse("/api/screen/replay")) is True


def test_the_body_is_read_once_and_shared_with_the_rest_of_the_router(monkeypatch):
    monkeypatch.setattr(routes, "check_csrf", lambda handler: True)
    import api.browser_routes as browser_routes
    monkeypatch.setattr(browser_routes, "handle_post", lambda handler, parsed, body: False)
    handler = _Handler({"session_id": ""})
    # Falls through the mount to the 404 path without a second, empty read.
    routes.handle_post(handler, urlparse("/api/browser/unknown"))
    assert handler.rfile.read() == b""


@pytest.mark.parametrize("method", ["GET", "POST", "PATCH", "DELETE"])
def test_unknown_kanban_endpoint_names_the_stale_bundle_for_every_method(monkeypatch, method):
    monkeypatch.setattr(routes, "check_csrf", lambda handler: True)
    import api.kanban_bridge as kanban
    monkeypatch.setattr(kanban, "handle_kanban_get", lambda handler, parsed: False)
    for verb in ("POST", "PATCH", "DELETE"):
        monkeypatch.setitem(kanban._WRITES, verb, lambda h, p, b: False)
    handler = _Handler({})
    assert METHODS[method](handler, urlparse("/api/kanban/obsolete-shape")) is True
    assert handler.status == 404
    error = json.loads(handler.wfile.getvalue())["error"]
    assert f"unknown Kanban endpoint: {method} /api/kanban/obsolete-shape" in error
