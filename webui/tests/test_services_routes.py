"""The /api/services dispatcher: snapshots, details, checked actions, config that never
echoes a secret, portfolio and wallets. A real hub over a fake HTTP client; no
service API is ever called."""
from __future__ import annotations

import io
import json
import sys
from pathlib import Path
from urllib.parse import urlparse

import pytest

ROOT = Path(__file__).resolve().parents[2]
for _p in (str(ROOT), str(ROOT / "webui")):
    if _p not in sys.path:
        sys.path.insert(0, _p)

from api import services_routes  # noqa: E402
from api.services_routes import SERVICES_PATH_PREFIX, handle_services_request  # noqa: E402
from jarvis_services import default_services  # noqa: E402
from jarvis_services.config import ServicesConfig, _read_env_file  # noqa: E402
from jarvis_services.loop import ServicesHub  # noqa: E402
from jarvis_services.testing import FakeHttp  # noqa: E402


def _writer(path, updates):
    values = _read_env_file(path)
    for k, v in updates.items():
        if v is None:
            values.pop(k, None)
        else:
            values[k] = v
    path.write_text("".join(f"{k}={v}\n" for k, v in values.items()))


@pytest.fixture()
def hub(tmp_path):
    h = ServicesHub(default_services(), ServicesConfig(home_fn=lambda: tmp_path, write_env=_writer),
                    http=FakeHttp(), publish=lambda *a: None, notify=lambda *a: None, sleep=lambda s: None)
    h.home = tmp_path
    return h


def call(hub, method, path, body=None):
    return handle_services_request(method, path, body, hub=hub)


def with_vercel_key(hub):
    status, _ = call(hub, "POST", "/config", {"service": "vercel", "secrets": {"token": "vc_token_123"}})
    assert status == 200
    hub.http.add("GET", "https://api.vercel.com/v6/deployments?limit=20", {"deployments": [
        {"uid": "d1", "name": "site", "state": "READY", "url": "site-d1.vercel.app", "target": "production"},
        {"uid": "b1", "name": "site", "state": "BUILDING", "url": "site-b1.vercel.app"}]})
    hub.http.add("GET", "https://api.vercel.com/v9/projects?limit=20", {"projects": []})


def test_prefix():
    assert SERVICES_PATH_PREFIX == "/api/services"


def test_list_is_empty_when_nothing_is_configured(hub):
    status, payload = call(hub, "GET", "")
    assert status == 200 and payload["services"] == [] and payload["pending"] == [] and payload["ts"] > 0
    assert call(hub, "POST", "", {})[0] == 405


def test_config_get_and_set_never_return_secrets(hub):
    status, payload = call(hub, "GET", "/config")
    assert status == 200 and {s["id"] for s in payload["services"]} >= {"github", "stripe", "n8n"}
    status, payload = call(hub, "POST", "/config", {"service": "stripe", "secrets": {"api_key": "sk_live_TOPSECRET1"}})
    assert status == 200 and payload["ok"] is True
    assert "TOPSECRET" not in json.dumps(payload)
    stripe = next(s for s in payload["services"] if s["id"] == "stripe")
    assert stripe["secrets"][0]["has_key"] is True
    assert "TOPSECRET" not in json.dumps(call(hub, "GET", "/config")[1])
    status, payload = call(hub, "POST", "/config", {"service": "stripe", "secrets": {"api_key": "pk live"}})
    assert status == 400 and "error" in payload


def test_pending_after_configuring_then_polled_at_once(hub):
    with_vercel_key(hub)
    assert call(hub, "GET", "")[1]["pending"] == ["vercel"]
    hub.http.add("GET", "https://api.vercel.com/v6/deployments?limit=5", {"deployments": []})
    hub.tick()                                    # saving the key woke it: polled now, not in 5 s
    status, payload = call(hub, "GET", "")
    assert payload["pending"] == [] and [s["id"] for s in payload["services"]] == ["vercel"]


def test_detail(hub):
    with_vercel_key(hub)
    status, detail = call(hub, "GET", "/vercel/detail")
    assert status == 200 and detail["id"] == "vercel" and detail["error"] is None
    assert detail["sections"][0]["items"][0]["actions"][0]["kind"] == "vercel.redeploy"
    assert call(hub, "GET", "/nope/detail")[0] == 404
    assert call(hub, "GET", "/crypto/detail")[0] == 404
    status, detail = call(hub, "GET", "/github/detail")
    assert status == 200 and "No GitHub key" in detail["error"]


def test_actions(hub):
    with_vercel_key(hub)
    call(hub, "GET", "/vercel/detail")
    status, out = call(hub, "POST", "/vercel/action", {"kind": "vercel.redeploy", "target": "zzz|site|"})
    assert status == 409 and out["ok"] is False and out["result"] is None
    status, out = call(hub, "POST", "/vercel/action", {"kind": "vercel.cancel", "target": "b1"})
    assert status == 409 and out["confirm"] == "Stop this build?"
    hub.http.add("PATCH", "https://api.vercel.com/v12/deployments/b1/cancel", {"message": "nope"}, status=403)
    status, out = call(hub, "POST", "/vercel/action", {"kind": "vercel.cancel", "target": "b1", "confirmed": True})
    assert status == 502 and out["result"]["ok"] is False
    hub.http.add("POST", "https://api.vercel.com/v13/deployments", {"url": "site-new.vercel.app"})
    status, out = call(hub, "POST", "/vercel/action", {"kind": "vercel.redeploy", "target": "d1|site|production"})
    assert status == 200 and out["ok"] is True and out["result"]["message"] == "Building site-new.vercel.app"
    assert out["detail"]["last_action"]["ok"] is True
    status, out = call(hub, "POST", "/stripe/action", {"kind": "stripe.refund", "target": "ch_1"})
    assert status == 409
    for bad in ({}, {"kind": "vercel.redeploy"}, {"kind": 1, "target": "x"}, {"kind": "a", "target": "b", "confirmed": "y"}):
        assert call(hub, "POST", "/vercel/action", bad)[0] == 400
    assert call(hub, "GET", "/vercel/action")[0] == 405


def test_portfolio_and_wallets(hub):
    status, payload = call(hub, "GET", "/portfolio")
    assert status == 200 and payload["crypto"] is None and payload["portfolio"] is None
    status, payload = call(hub, "POST", "/portfolio/wallets",
                           {"op": "add", "network": "ethereum", "address": "0x123"})
    assert status == 400 and "doesn't look like" in payload["error"]
    hub.http.add("POST", "https://ethereum-rpc.publicnode.com", {"result": "0x0"})
    status, payload = call(hub, "POST", "/portfolio/wallets",
                           {"op": "add", "network": "ethereum", "address": "0x" + "ab" * 20, "label": "Ledger"})
    assert status == 200 and payload["wallets"][0]["label"] == "Ledger"
    status, _ = call(hub, "POST", "/portfolio/wallets", {"op": "remove", "network": "base", "address": "0x1"})
    assert status == 404


def test_unknown_routes(hub):
    assert call(hub, "GET", "/nope")[0] == 404
    assert call(hub, "GET", "/a/b/c")[0] == 404


# ── the routes.py wiring ────────────────────────────────────────────────────────

class _FakeHandler:
    def __init__(self, body: bytes = b""):
        self.status = None
        self.body = bytearray()
        self.wfile = self
        self.rfile = io.BytesIO(body)
        self.headers = {"Content-Length": str(len(body))}
        self.request = None

    def send_response(self, status):
        self.status = status

    def send_header(self, *args):
        pass

    def end_headers(self):
        pass

    def write(self, data):
        self.body.extend(data)


def test_wired_into_routes_get_and_post(hub, monkeypatch):
    monkeypatch.setattr(services_routes, "default_hub", lambda: hub)
    from api.routes import handle_get, handle_post
    handler = _FakeHandler()
    handle_get(handler, urlparse("http://x/api/services"))
    assert handler.status == 200 and json.loads(bytes(handler.body))["services"] == []
    raw = json.dumps({"crypto": {"enabled": True}}).encode()
    handler = _FakeHandler(raw)
    handle_post(handler, urlparse("http://x/api/services/config"))
    assert handler.status == 200 and json.loads(bytes(handler.body))["crypto"]["enabled"] is True


def test_the_hub_keeps_one_home_whatever_profile_a_request_carries(tmp_path, monkeypatch):
    """The poller thread has no profile cookie; saves and polls must use the
    same folder, the server's own (sweep finding)."""
    server_home = tmp_path / "server"
    server_home.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(server_home))
    import api.providers as providers
    monkeypatch.setattr(providers, "_get_hermes_home", lambda: tmp_path / "profiles" / "coder")
    monkeypatch.setattr(services_routes, "_HUB", None)
    try:
        hub = services_routes.default_hub()
        assert hub.config.home == server_home
    finally:
        services_routes._HUB = None
