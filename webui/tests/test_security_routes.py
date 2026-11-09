"""/api/security/* — who may change what, Face ID for Block/Allow, nothing secret leaks."""
import base64
import json
import time
import uuid

import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

from api.security_routes import handle_security_request
from plugins.security_advisor.rules import Decision
from plugins.toyota.approver import Approver, message, register_message
from security.blocklist import Blocklist
from security.events import EventLog

ACTOR = {"ip": "198.51.100.20", "device_id": "dev-1", "device_name": "Test Phone",
         "session_kind": "paired"}


class Phone:
    def __init__(self):
        self.key = ec.generate_private_key(ec.SECP256R1())
        raw = self.key.public_key().public_bytes(serialization.Encoding.X962,
                                                 serialization.PublicFormat.UncompressedPoint)
        self.public = base64.b64encode(raw).decode()

    def sign(self, data: bytes) -> str:
        return base64.b64encode(self.key.sign(data, ec.ECDSA(hashes.SHA256()))).decode()


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    monkeypatch.setenv("HERMES_CONFIG_PATH", str(tmp_path / "config.yaml"))
    import security.events as ev
    emitted = []
    monkeypatch.setattr(ev, "emit", lambda s, k, a=None, **d: emitted.append(k))
    log = EventLog(tmp_path / "e.db")
    blocks = Blocklist(tmp_path / "blocks.json")
    now = time.time()
    approver = Approver(path=tmp_path / "approver.json", clock=lambda: now)
    phone = Phone()
    approver.register(phone.public, int(now), phone.sign(register_message(phone.public, int(now))))

    def call(method, path, body=None, query=None, host=False, actor=ACTOR):
        return handle_security_request(method, path, body or {}, query or {}, host_signed=host,
                                       actor=actor, log=log, blocklist=blocks, approver=approver)
    return {"call": call, "log": log, "blocks": blocks, "phone": phone, "now": int(now),
            "emitted": emitted}


def make_alert(log, ip="203.0.113.50"):
    e = log.append("device", "auth.failed", {"ip": ip}, {"reason": "bad_cookie"})
    return log.add_alert(e.id, Decision("alert", "auth_burst", "Many failures", "s", f"auth_burst:{ip}"))


def proof(env, command):
    nonce = uuid.uuid4().hex
    return {"nonce": nonce, "ts": env["now"],
            "signature": env["phone"].sign(message(command, nonce, env["now"], "jarvis-security"))}


def test_host_signed_posts_are_refused(env):
    for path, body in (("/settings", {"settings": {"alert_cap_per_hour": 9}}),
                       ("/blocks/203.0.113.1/undo", {}), ("/alerts/1/resolve", {"action": "dismiss"})):
        status, payload = env["call"]("POST", path, body, host=True)
        assert status == 403, path


def test_session_settings_change_model_and_values(env):
    status, payload = env["call"]("POST", "/settings", {
        "settings": {"alert_cap_per_hour": 5, "disabled_rules": ["new_device"]},
        "model": {"provider": "openrouter", "model": "anthropic/claude-haiku-test"}})
    assert status == 200, payload
    status, got = env["call"]("GET", "/settings")
    assert got["settings"]["alert_cap_per_hour"] == 5
    assert got["model"] == {"provider": "openrouter", "model": "anthropic/claude-haiku-test"}
    rules = {r["id"]: r for r in got["rules"]}
    assert rules["new_device"]["enabled"] is False and rules["auth_burst"]["enabled"] is True
    assert all(r["title"] for r in got["rules"])
    assert "advisor.changed" in env["emitted"]


def test_bad_settings_are_400(env):
    assert env["call"]("POST", "/settings", {"settings": {"digest_hour": 99}})[0] == 400


def test_default_model_is_haiku_on_claude_code(env):
    _, got = env["call"]("GET", "/settings")
    assert got["model"] == {"provider": "claude-code", "model": "claude-haiku-5-5"}


def test_resolve_block_needs_face_id(env):
    aid = make_alert(env["log"])
    status, payload = env["call"]("POST", f"/alerts/{aid}/resolve", {"action": "block"})
    assert status == 403
    bad = proof(env, f"allow:{aid}")                     # signed for a different action
    assert env["call"]("POST", f"/alerts/{aid}/resolve", {"action": "block", **bad})[0] == 403
    status, payload = env["call"]("POST", f"/alerts/{aid}/resolve",
                                  {"action": "block", **proof(env, f"block:{aid}")})
    assert status == 200, payload
    assert env["blocks"].is_blocked("203.0.113.50")
    assert env["log"].get_alert(aid)["status"] == "blocked"


def test_resolve_allow_adds_exception_and_lifts_block(env):
    aid = make_alert(env["log"], ip="203.0.113.51")
    env["blocks"].block("203.0.113.51", "x", ttl_s=600)
    status, _ = env["call"]("POST", f"/alerts/{aid}/resolve",
                            {"action": "allow", **proof(env, f"allow:{aid}")})
    assert status == 200
    assert not env["blocks"].is_blocked("203.0.113.51")
    _, got = env["call"]("GET", "/settings")
    assert got["settings"]["exceptions"]["203.0.113.51"] > time.time() + 6 * 86400


def test_dismiss_needs_only_a_session(env):
    aid = make_alert(env["log"])
    assert env["call"]("POST", f"/alerts/{aid}/resolve", {"action": "dismiss"})[0] == 200
    assert env["log"].get_alert(aid)["status"] == "dismissed"
    assert env["call"]("POST", "/alerts/999/resolve", {"action": "dismiss"})[0] == 404


def test_undo_block(env):
    env["blocks"].block("2001:db8::9", "x", ttl_s=600)
    status, payload = env["call"]("POST", "/blocks/2001:db8::9/undo")
    assert status == 200 and payload["removed"] is True
    assert not env["blocks"].is_blocked("2001:db8::9")


def test_reads(env):
    env["log"].append("device", "config.password_changed", {"ip": "203.0.113.52"},
                      {"password": "hunter2-secret", "action": "set"})
    env["blocks"].block("203.0.113.53", "burst", ttl_s=600)
    make_alert(env["log"])
    _, events = env["call"]("GET", "/events", query={"limit": ["10"]})
    assert "hunter2-secret" not in json.dumps(events)
    assert events["events"][0]["kind"] == "auth.failed"
    assert isinstance(events["events"][0]["actor"], str) and "203.0.113.50" in events["events"][0]["actor"]
    _, filtered = env["call"]("GET", "/events", query={"kind": ["config.password_changed"]})
    assert [e["kind"] for e in filtered["events"]] == ["config.password_changed"]
    _, blocks = env["call"]("GET", "/blocks")
    assert blocks["blocks"][0]["ip"] == "203.0.113.53" and blocks["blocks"][0]["until"].endswith("Z")
    _, alerts = env["call"]("GET", "/alerts", query={"status": ["open"]})
    assert alerts["alerts"][0]["ip"] == "203.0.113.50"
    status, st = env["call"]("GET", "/status")
    assert status == 200 and st["open_alerts"] == 1 and st["blocks"] == 1
    assert env["call"]("GET", "/digests")[1] == {"digests": []}
    assert env["call"]("GET", "/nope")[0] == 404


def test_resolve_block_refuses_his_own_networks(env):
    for ip in ("127.0.0.1", "192.168.1.20", "10.0.0.5", "100.101.102.103", "169.254.1.1"):
        aid = make_alert(env["log"], ip=ip)
        status, payload = env["call"]("POST", f"/alerts/{aid}/resolve",
                                      {"action": "block", **proof(env, f"block:{aid}")})
        assert status == 409, ip
        assert payload["code"] == "protected" and payload["error"]
        assert not env["blocks"].is_blocked(ip)
        assert env["log"].get_alert(aid)["status"] == "open"


def test_resolve_block_refuses_an_ip_with_a_recent_session(env):
    env["log"].append("device", "session.seen", {"ip": "203.0.113.60", "session_kind": "paired"}, {})
    aid = make_alert(env["log"], ip="203.0.113.60")
    status, payload = env["call"]("POST", f"/alerts/{aid}/resolve",
                                  {"action": "block", **proof(env, f"block:{aid}")})
    assert status == 409 and payload["code"] == "protected"
    assert not env["blocks"].is_blocked("203.0.113.60")


def test_every_change_needs_a_paired_device(env):
    aid = make_alert(env["log"])
    env["blocks"].block("203.0.113.61", "x", ttl_s=600)
    for kind in ("unpaired", "none", "host", ""):
        actor = {**ACTOR, "session_kind": kind}
        for path, body in (("/settings", {"settings": {"alert_cap_per_hour": 9}}),
                           ("/blocks/203.0.113.61/undo", {}),
                           (f"/alerts/{aid}/resolve", {"action": "dismiss"})):
            status, payload = env["call"]("POST", path, body, actor=actor)
            assert status == 403 and payload["code"] == "forbidden", (kind, path)
    assert env["blocks"].is_blocked("203.0.113.61")
    assert env["log"].get_alert(aid)["status"] == "open"
    _, got = env["call"]("GET", "/settings")
    assert got["settings"]["alert_cap_per_hour"] == 3


def test_settings_post_cannot_write_exceptions_or_unknown_keys(env):
    for body in ({"settings": {"exceptions": {"203.0.113.62": time.time() + 600}}},
                 {"exceptions": {"203.0.113.62": time.time() + 600}},
                 {"settings": {"alert_cap_per_hour": 4}, "surprise": 1},
                 {"settings": {"nope": 1}},
                 {"settings": ["alert_cap_per_hour"]}):
        assert env["call"]("POST", "/settings", body)[0] == 400, body
    _, got = env["call"]("GET", "/settings")
    assert got["settings"]["exceptions"] == {} and got["settings"]["alert_cap_per_hour"] == 3
