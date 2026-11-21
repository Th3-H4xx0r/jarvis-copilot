"""game_stream skill: per-device connect drivers + dispatch + registration."""
from __future__ import annotations

import json
import types

import pytest

from jc_client.skills import game_stream
from jc_client import skills as skills_registry


class FakeRun:
    def __init__(self, returncode=0, stderr="", raise_exc=None):
        self.calls = []
        self.returncode = returncode
        self.stderr = stderr
        self.raise_exc = raise_exc

    def __call__(self, cmd, timeout=15):
        self.calls.append(cmd)
        if self.raise_exc:
            raise self.raise_exc
        return types.SimpleNamespace(returncode=self.returncode, stderr=self.stderr, stdout="")


def test_connect_mac_builds_moonlight_cli():
    run = FakeRun()
    res = game_stream.connect({"kind": "mac", "host": "gpc"}, "Cyberpunk 2077", run=run)
    assert res["ok"] is True
    assert run.calls[0] == ["moonlight", "stream", "gpc", "Cyberpunk 2077"]


def test_connect_androidtv_adb_intent():
    run = FakeRun()
    res = game_stream.connect(
        {"kind": "androidtv", "host": "gpc-uuid", "tv_addr": "10.0.0.5:5555"}, "Halo", run=run)
    assert res["ok"] is True
    assert ["adb", "connect", "10.0.0.5:5555"] in run.calls
    launch = run.calls[-1]
    assert "am" in launch and "start" in launch
    assert any("Halo" in str(part) for part in launch)


def test_connect_ios_returns_push_marker():
    res = game_stream.connect({"kind": "ios", "host": "gpc"}, "DOOM")
    assert res.get("push") is True
    assert res["app"] == "DOOM"


def test_running_session_streams_desktop_not_relaunch():
    run = FakeRun()
    game_stream.connect({"kind": "mac", "host": "gpc"}, "Cyberpunk 2077",
                        stream_running_session=True, run=run)
    cmd = run.calls[0]
    assert "Desktop" in cmd
    assert "Cyberpunk 2077" not in cmd


def test_missing_adb_returns_actionable_error():
    run = FakeRun(raise_exc=FileNotFoundError())
    res = game_stream.connect(
        {"kind": "androidtv", "host": "gpc", "tv_addr": "10.0.0.5:5555"}, "Halo", run=run)
    assert res["ok"] is False
    assert "adb" in res["detail"].lower()


def test_target_not_paired_clear_message():
    run = FakeRun(returncode=1, stderr="Pairing required")
    res = game_stream.connect({"kind": "mac", "host": "gpc"}, "Halo", run=run)
    assert res["ok"] is False
    assert "pairing required" in res["detail"].lower()


def test_register_adds_skills():
    game_stream.register()
    game_stream.register_host()
    names = {s["name"] for s in skills_registry.all_manifest()}
    assert "game_stream_connect" in names
    assert "game_stream_status" in names


# ── detect (localhost probe) ──────────────────────────────────────────────
class FakeClientRec:
    made = []

    def __init__(self, host, port, user, password, scheme="https"):
        FakeClientRec.made.append((host, port, user, password, scheme))
        self.probe_result = {"running": True, "needs_login": False}

    def probe(self):
        return self.probe_result


def test_detect_defaults_to_localhost(monkeypatch):
    FakeClientRec.made = []
    monkeypatch.setattr(game_stream, "SunshineClient", FakeClientRec)
    monkeypatch.setattr(game_stream, "sunshine_username", lambda *a, **k: "")
    res = game_stream._host_detect({"sunshine": {"user": "a", "password": "b"}})
    assert res["ok"] is True
    assert res["data"]["running"] is True and res["data"]["needs_login"] is False
    assert res["data"]["username"] == ""   # no state file reachable in the test env
    host, port, user, password, scheme = FakeClientRec.made[0]
    assert host == "127.0.0.1" and port == 47990 and user == "a" and password == "b"


def test_detect_reports_needs_login(monkeypatch):
    from jc_client.sunshine import SunshineAuthError

    class NeedsLogin(FakeClientRec):
        def probe(self):
            return {"running": True, "needs_login": True}

    monkeypatch.setattr(game_stream, "SunshineClient", NeedsLogin)
    res = game_stream._host_detect({"sunshine": {"user": "", "password": ""}})
    assert res["data"]["needs_login"] is True


def test_detect_registered_as_host_skill():
    game_stream.register_host()
    names = {s["name"] for s in skills_registry.all_manifest()}
    assert "game_stream_detect" in names



# ── host status: reachable vs needs-login vs offline ────────────────
class _StatusClient:
    def __init__(self, clients_exc=None, apps_exc=None):
        self.clients_exc = clients_exc
        self.apps_exc = apps_exc

    def get_clients(self):
        if self.clients_exc:
            raise self.clients_exc
        return [{"name": "Mac", "uuid": "u1"}]

    def get_apps(self):
        if self.apps_exc:
            raise self.apps_exc
        return [{"name": "Halo"}]


def _status_data(monkeypatch, client):
    monkeypatch.setattr(game_stream, "_client_from", lambda args: client)
    return game_stream._host_status({})["data"]


def test_status_reachable_when_login_works(monkeypatch):
    data = _status_data(monkeypatch, _StatusClient())
    assert data["reachable"] is True
    assert data["needs_login"] is False
    assert data["paired"] == [{"name": "Mac", "uuid": "u1"}]
    assert data["apps"] == [{"name": "Halo"}]


def test_status_auth_error_is_needs_login_not_offline(monkeypatch):
    from jc_client.sunshine import SunshineAuthError
    data = _status_data(monkeypatch, _StatusClient(clients_exc=SunshineAuthError("auth failed (401)")))
    assert data["reachable"] is False
    assert data["needs_login"] is True        # running, just the wrong login
    assert data["paired"] == [] and data["apps"] == []


def test_status_other_unavailable_is_offline(monkeypatch):
    from jc_client.sunshine import SunshineUnavailable
    data = _status_data(monkeypatch, _StatusClient(clients_exc=SunshineUnavailable("connection refused")))
    assert data["reachable"] is False
    assert data["needs_login"] is False       # genuinely down, not a login problem
    assert data["paired"] == [] and data["apps"] == []


# ── pairing: auth failure says "check your password", not "unavailable" ─────
def test_pair_auth_error_has_distinct_password_message(monkeypatch):
    from jc_client.sunshine import SunshineAuthError

    class C:
        def submit_pin(self, pin, name=None):
            raise SunshineAuthError("auth failed (401)")

    monkeypatch.setattr(game_stream, "_client_from", lambda args: C())
    res = game_stream._host_pair({"pin": "1234", "device": "TV"})
    assert res["ok"] is False
    assert "password" in res["detail"].lower()
    assert "unavailable" not in res["detail"].lower()


def test_pair_offline_message_distinct_from_auth(monkeypatch):
    from jc_client.sunshine import SunshineUnavailable

    class C:
        def submit_pin(self, pin, name=None):
            raise SunshineUnavailable("connection refused")

    monkeypatch.setattr(game_stream, "_client_from", lambda args: C())
    res = game_stream._host_pair({"pin": "1234"})
    assert res["ok"] is False
    assert "unavailable" in res["detail"].lower()


# ── username from the Sunshine state file ────────────────────
def test_sunshine_username_reads_state_next_to_log(tmp_path):
    (tmp_path / "sunshine_state.json").write_text(json.dumps({"username": "pranav"}))
    assert game_stream.sunshine_username(str(tmp_path / "sunshine.log")) == "pranav"


def test_sunshine_username_missing_file_is_blank(tmp_path):
    assert game_stream.sunshine_username(str(tmp_path / "gone" / "sunshine.log")) == ""


def test_sunshine_username_tolerates_nested_root(tmp_path):
    (tmp_path / "sunshine_state.json").write_text(json.dumps({"root": {"username": "neo"}}))
    assert game_stream.sunshine_username(str(tmp_path / "sunshine.log")) == "neo"


def test_sunshine_username_bad_json_is_blank(tmp_path):
    (tmp_path / "sunshine_state.json").write_text("not json at all")
    assert game_stream.sunshine_username(str(tmp_path / "sunshine.log")) == ""


def test_detect_includes_username(monkeypatch, tmp_path):
    (tmp_path / "sunshine_state.json").write_text(json.dumps({"username": "admin"}))
    monkeypatch.setattr(game_stream, "SunshineClient", FakeClientRec)
    res = game_stream._host_detect({"sunshine": {"user": "", "password": ""},
                                    "log_path": str(tmp_path / "sunshine.log")})
    assert res["data"]["running"] is True
    assert res["data"]["username"] == "admin"
