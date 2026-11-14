"""Power integrations over HTTP: /api/power list, switch, settings, UI, cards and approvals."""
from __future__ import annotations

import sys
import textwrap
import time
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import urlparse

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

import api.power_routes as routes  # noqa: E402
import jarvis_registry.store as store  # noqa: E402
from jarvis_registry import Registry  # noqa: E402
from jarvis_power import approvals, discovery, state  # noqa: E402

SOURCE = '''
import time
from jarvis_power import PowerIntegration, Setting

class Alpha(PowerIntegration):
    id = "alpha"
    name = "Alpha"
    icon = "bolt"
    summary = "Test."
    protected = True
    settings = (Setting("token", "Token", "secret"), Setting("mode", "Mode", "picker",
                default="a", options=(("a", "A"), ("b", "B"))))
    actions = ("ping",)
    slow = False

    def status_line(self):
        return "All good"

    def state(self):
        if type(self).slow:
            time.sleep(3)
        return {"count": 3}

    def action(self, name, event):
        return {"state": {"count": 4}, "toast": "Pinged"}
'''
UI = {"presentations": {"card": {"type": "button", "label": "Ping", "action": "ping"},
                        "page": {"type": "text", "value": "Alpha"}}}


@pytest.fixture()
def env(tmp_path, monkeypatch):
    import json
    root = tmp_path / "pkgroot"
    pkg = root / "fake_power_routes"
    (pkg / "alpha").mkdir(parents=True)
    (pkg / "__init__.py").write_text("")
    (pkg / "alpha" / "__init__.py").write_text(textwrap.dedent(SOURCE))
    (pkg / "alpha" / "ui.json").write_text(json.dumps(UI))
    monkeypatch.syspath_prepend(str(root))
    monkeypatch.setattr(discovery, "PACKAGE", "fake_power_routes")
    discovery.reset()
    r = Registry(tmp_path / "registry.db")
    monkeypatch.setattr(store, "shared", lambda: r)
    state.reset_cache()
    approvals.reset()
    monkeypatch.setattr(approvals, "notifier", lambda item: None)
    state.ensure_all()
    state.store_settings("alpha", {"token": "s3cret"})
    yield r
    discovery.reset()
    state.reset_cache()
    r.close()


def call(method, path, body=None, host=False):
    box = {}
    req = SimpleNamespace(method=method, path=path, parsed=urlparse(path), body=body,
                          host_signed=host, prefix="/api/power", handler=None,
                          sub=path[len("/api/power"):])
    req.reply = lambda status, payload: box.update(status=status, body=payload) or True
    assert routes.route(req) is not False
    return box["status"], box["body"]


def test_list_masks_secrets(env):
    status, body = call("GET", "/api/power")
    assert status == 200 and body["version"]
    [row] = body["integrations"]
    assert row["settings"]["token"] == {"set": True}
    assert "s3cret" not in str(body)
    assert row["status_line"] == "All good"
    assert row["has_card"] and row["has_page"]
    assert {s["key"] for s in row["settings_schema"]} == {"token", "mode"}


def test_post_from_host_is_jarvis(env):
    status, body = call("POST", "/api/power/alpha", {"enabled": False}, host=True)
    assert status == 200 and body["ok"] is False and body["pending"]["command"] == "off:alpha"
    status, body = call("POST", "/api/power/alpha", {"settings": {"mode": "b"}}, host=True)
    assert body["ok"] is True and body["row"]["settings"]["mode"] == "b"


def test_bad_settings_are_400(env):
    status, body = call("POST", "/api/power/alpha", {"settings": {"mode": "z"}})
    assert status == 400 and "Mode" in body["error"]


def test_ui_shapes_match_integration_ui(env):
    status, body = call("GET", "/api/power/alpha/ui")
    assert set(body) == {"space", "version", "definition", "state", "error"}
    assert body["state"] == {"count": 3} and "card" in body["definition"]["presentations"]
    status, body = call("POST", "/api/power/alpha/ui/action", {"action": "ping"})
    assert set(body) == {"ok", "state", "toast", "error", "version"}
    assert body["ok"] is True and body["state"] == {"count": 4} and body["toast"] == "Pinged"


def test_cards_budget_returns_last_state_on_timeout(env, monkeypatch):
    status, body = call("GET", "/api/power/cards")
    assert body["cards"][0]["state"] == {"count": 3}
    p = discovery.get("alpha")
    type(p).slow = True
    monkeypatch.setattr(routes, "CARD_STATE_TIMEOUT", 0.2)
    t = time.monotonic()
    status, body = call("GET", "/api/power/cards")
    assert time.monotonic() - t < 2
    card = body["cards"][0]
    assert card["state"] == {"count": 3} and card["error"]
    type(p).slow = False


def test_approvals_cannot_be_answered_by_host(env):
    status, body = call("POST", "/api/power/alpha", {"enabled": False})
    approval_id = body["pending"]["id"]
    status, listed = call("GET", "/api/power/approvals")
    assert [a["id"] for a in listed["approvals"]] == [approval_id]
    status, body = call("POST", f"/api/power/approvals/{approval_id}/approve",
                        {"ts": 1, "signature": "x"}, host=True)
    assert status == 403
    status, body = call("POST", f"/api/power/approvals/{approval_id}/deny")
    assert status == 200 and body["ok"] is True


def test_boards_cannot_change_power(env, monkeypatch):
    monkeypatch.setattr(routes, "_is_board", lambda req: True)
    status, body = call("POST", "/api/power/alpha", {"settings": {"mode": "b"}})
    assert status == 403
    status, body = call("GET", "/api/power")
    assert status == 200
