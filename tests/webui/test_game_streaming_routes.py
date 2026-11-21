"""Game streaming routes: localhost Sunshine, the structured target store + migration,
the detect probe and the POST /targets write. No raw JSON anywhere user-facing."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "webui"))

import api.game_streaming_routes as R  # noqa: E402
from api.game_streaming_store import GameStreamingStore  # noqa: E402


class Req:
    def __init__(self, method, sub, body=None):
        self.method = method
        self.sub = sub
        self.body = body or {}
        self.replied = None

    def reply(self, status, data):
        self.replied = (status, data)
        return True


@pytest.fixture
def store(tmp_path, monkeypatch):
    s = GameStreamingStore(tmp_path / "gs")
    monkeypatch.setattr(R, "store", lambda: s)
    return s


@pytest.fixture
def settings(monkeypatch):
    values = {}
    monkeypatch.setattr(R, "_settings", lambda: dict(values))
    return values


def _route(method, sub, body=None):
    req = Req(method, sub, body)
    handled = R.route(req)
    return handled, req.replied


# ── Sunshine connection is always localhost ──────────────────────────────────
def test_sunshine_conn_has_no_host_or_port(settings):
    settings.update({"user": "admin", "password": "pw"})
    conn = R._sunshine_conn()
    assert "host" not in conn and "port" not in conn
    assert conn["user"] == "admin" and conn["password"] == "pw"


# ── structured target store ──────────────────────────────────────────────────
def test_store_targets_roundtrip(store):
    store.set_targets([{"name": "Mac", "kind": "mac"},
                       {"name": "Shield", "kind": "androidtv", "tv_addr": "10.0.0.5:5555"}])
    got = store.get_targets()
    assert [t["name"] for t in got] == ["Mac", "Shield"]
    shield = [t for t in got if t["name"] == "Shield"][0]
    assert shield["tv_addr"] == "10.0.0.5:5555"
    assert "tv_addr" not in [t for t in got if t["name"] == "Mac"][0]


def test_targets_injects_the_moonlight_host(store, settings):
    settings["host"] = "gaming-pc"
    store.set_targets([{"name": "Mac", "kind": "mac"}])
    (t,) = R._targets()
    assert t["host"] == "gaming-pc"           # auto-filled, never typed per device


def test_targets_migrates_legacy_json_once(store, settings):
    settings["targets"] = '[{"name":"Mac","kind":"mac","host":"old-pc"},' \
                          '{"name":"TV","kind":"androidtv","tv_addr":"10.0.0.9:5555"}]'
    out = R._targets()
    assert {t["name"] for t in out} == {"Mac", "TV"}
    assert store.get_targets()                 # persisted into the structured store
    tv = [t for t in out if t["name"] == "TV"][0]
    assert tv["tv_addr"] == "10.0.0.9:5555"
    # the legacy per-target host is preserved on migration
    mac = [t for t in out if t["name"] == "Mac"][0]
    assert mac["host"] == "old-pc"
    # a second read does not re-migrate on top of edits
    store.set_targets([{"name": "Mac", "kind": "mac"}])
    assert [t["name"] for t in R._targets()] == ["Mac"]


# ── detect route ─────────────────────────────────────────────────────────────
def test_detect_offline(store, settings, monkeypatch):
    monkeypatch.setattr(R, "_pc_id", lambda: "pc1")
    monkeypatch.setattr(R, "_connected", lambda: [])
    handled, (status, data) = _route("GET", "/detect")
    assert handled and status == 200
    assert data["online"] is False and data["running"] is False


def test_detect_running_and_logged_in(store, settings, monkeypatch):
    monkeypatch.setattr(R, "_pc_id", lambda: "pc1")
    monkeypatch.setattr(R, "_connected", lambda: ["pc1"])
    monkeypatch.setattr(R, "_invoke", lambda did, skill, args, timeout=20.0:
                        {"ok": True, "data": {"running": True, "needs_login": False}})
    _, (status, data) = _route("GET", "/detect")
    assert data == {"ok": True, "online": True, "running": True, "needs_login": False,
                    "username": ""}


def test_detect_running_but_needs_login(store, settings, monkeypatch):
    monkeypatch.setattr(R, "_pc_id", lambda: "pc1")
    monkeypatch.setattr(R, "_connected", lambda: ["pc1"])
    monkeypatch.setattr(R, "_invoke", lambda *a, **k:
                        {"ok": True, "data": {"running": True, "needs_login": True}})
    _, (_, data) = _route("GET", "/detect")
    assert data["running"] is True and data["needs_login"] is True


# ── POST /targets writes structured data (no JSON) ───────────────────────────
def test_post_targets_persists_clean_rows(store, settings):
    body = {"targets": [
        {"name": "Mac", "kind": "mac", "tv_addr": ""},
        {"name": "Shield", "kind": "androidtv", "tv_addr": "10.0.0.5:5555"},
        {"name": "", "kind": "mac"},        # dropped: no name
    ]}
    handled, (status, data) = _route("POST", "/targets", body)
    assert handled and status == 200 and data["ok"] is True
    names = [t["name"] for t in store.get_targets()]
    assert names == ["Mac", "Shield"]
    shield = [t for t in store.get_targets() if t["name"] == "Shield"][0]
    assert shield["tv_addr"] == "10.0.0.5:5555"
    assert "tv_addr" not in [t for t in store.get_targets() if t["name"] == "Mac"][0]


def test_post_targets_rejects_non_list(store, settings):
    _, (status, data) = _route("POST", "/targets", {"targets": "nope"})
    assert status == 400 and data["ok"] is False
