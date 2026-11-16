"""Remote Desktop sessions (plan 2026-11-15-remote-desktop, Tasks 1–2): the PC's status, who may
start a session (asleep/offline/not ready → a code; a game or someone at the PC → a warning he
confirms), the Face ID approval and the per-session credential, which never leaves memory and is
never shown as plaintext."""
from __future__ import annotations

import logging
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from api.rdp_sessions import RdpSessions  # noqa: E402

READY = {"device_id": "pc-1", "edition": "Windows 11 Pro", "rdp_enabled": True, "firewall_scoped": True,
         "username": "MicrosoftAccount\\krish@example.com", "tailscale_ip": "100.119.223.124",
         "idle_s": 900.0, "locked": True, "game": None, "remote_session": False, "has_password": True}


class Clock:
    def __init__(self):
        self.t = 1_800_000_000.0

    def __call__(self):
        return self.t


@pytest.fixture()
def env(tmp_path):
    clock = Clock()
    sent = []
    asleep = set()
    settings = {"idle_minutes": 30, "warn_game": True, "allow_web": True, "transfer_folder": "Downloads\\Jarvis"}
    s = RdpSessions(clock=clock, send_frame=lambda d, f: sent.append((d, f)) or True,
                    sleeping=lambda d: d in asleep, game_name=lambda exe: {"cod.exe": "Call of Duty"}.get(exe, exe),
                    settings=lambda: settings, device_name=lambda d: "pranav-computer",
                    audit_path=tmp_path / "audit.json")
    return SimpleNamespace(s=s, clock=clock, sent=sent, asleep=asleep, settings=settings)


def _status(env, **over):
    env.s.put_status("pc-1", {**READY, **over})


# ── Task 1 ─────────────────────────────────────────────────────────────────
def test_session_refused_when_asleep_or_offline(env):
    _status(env)
    env.asleep.add("pc-1")
    assert env.s.create("pc-1", "web", False, None) == {
        "error": "pranav-computer is asleep", "code": "asleep"}
    env.asleep.clear()
    env.clock.t += 91          # no status for over 90 s
    out = env.s.create("pc-1", "web", False, None)
    assert out["code"] == "offline"
    assert env.s.create("pc-unknown", "web", False, None)["code"] == "offline"


def test_warn_game_then_confirm(env):
    _status(env, game="cod.exe")
    assert env.s.create("pc-1", "web", False, None) == {"warn": "game", "game_name": "Call of Duty"}
    out = env.s.create("pc-1", "web", True, None)
    assert out["session"]["state"] == "approving"
    assert out["session"]["expires_at"] == env.clock.t + 60
    # the warning can be switched off in the integration's settings
    env.settings["warn_game"] = False
    assert "session" in env.s.create("pc-1", "web", False, None)


def test_warn_in_use(env):
    _status(env, idle_s=30.0, locked=False)
    assert env.s.create("pc-1", "web", False, None) == {"warn": "in_use"}
    _status(env, idle_s=30.0, locked=True)
    assert "session" in env.s.create("pc-1", "web", False, None)
    _status(env, idle_s=200.0, locked=False)          # nobody there for over 2 minutes
    assert "session" in env.s.create("pc-1", "web", False, None)


def test_not_ready_codes(env):
    _status(env, edition="Windows 11 Home")
    assert env.s.create("pc-1", "web", True, None)["code"] == "edition"
    _status(env, rdp_enabled=False)
    assert env.s.create("pc-1", "web", True, None)["code"] == "not_ready"
    _status(env, has_password=False)
    assert env.s.create("pc-1", "web", True, None)["code"] == "no_password"
    _status(env)
    env.settings["allow_web"] = False
    assert env.s.create("pc-1", "web", True, None)["code"] == "web_off"
    assert "session" in env.s.create("pc-1", "ios", True, "BASE64KEY")


def test_session_fields_and_target(env):
    _status(env)
    sid = env.s.create("pc-1", "ios", True, "BASE64KEY")["session"]["id"]
    sess = env.s.get(sid)
    assert (sess.device_id, sess.client, sess.state) == ("pc-1", "ios", "approving")
    assert (sess.host, sess.port, sess.username) == ("100.119.223.124", 3389, READY["username"])
    assert sess.enc_pub == "BASE64KEY" and sess.credential is None


def test_get_never_returns_plaintext(env):
    _status(env)
    web = env.s.create("pc-1", "web", True, None)["session"]["id"]
    ios = env.s.create("pc-1", "ios", True, "BASE64KEY")["session"]["id"]
    env.s.on_credential("pc-1", {"session_id": web, "ok": True, "credential": {"password": "hunter2!"}})
    env.s.on_credential("pc-1", {"session_id": ios, "ok": True,
                                 "credential": {"ciphertext": "Y3Q=", "ephemeral_pub": "ZXA=", "nonce": "bm8="}})
    pub_web, pub_ios = env.s.public(web), env.s.public(ios)
    assert pub_web["state"] == pub_ios["state"] == "approved"
    assert "hunter2!" not in repr(pub_web) and "credential" not in pub_web
    assert pub_ios["credential"] == {"ciphertext": "Y3Q=", "ephemeral_pub": "ZXA=", "nonce": "bm8="}
    assert "hunter2!" not in repr(env.s.audit())


def test_end_and_off_cancel_everything(env):
    _status(env)
    a = env.s.create("pc-1", "web", True, None)["session"]["id"]
    b = env.s.create("pc-1", "ios", True, "K")["session"]["id"]
    env.s.end(a, "user")
    assert env.s.get(a).state == "ended"
    env.s.on_off()
    assert env.s.get(b).state == "cancelled"
    assert [e["client"] for e in env.s.audit()] == ["ios", "web"]   # newest first, no secrets


def test_idle_session_ends(env):
    _status(env)
    sid = env.s.create("pc-1", "web", True, None)["session"]["id"]
    env.s.on_credential("pc-1", {"session_id": sid, "ok": True, "credential": {"password": "x"}})
    env.s.mark_connected(sid)
    env.clock.t += 30 * 60 + 1
    env.s.sweep()
    assert env.s.get(sid).state == "ended" and env.s.get(sid).credential is None


# ── Task 2 ─────────────────────────────────────────────────────────────────
def test_create_sends_the_signed_context_to_the_pc(env):
    _status(env)
    sid = env.s.create("pc-1", "ios", True, "BASE64KEY")["session"]["id"]
    did, frame = env.sent[-1]
    assert did == "pc-1" and frame["type"] == "rdp_credential_request"
    assert frame["session_id"] == sid and frame["client"] == "ios"
    import json
    ctx = json.loads(frame["context"])
    assert ctx == {"session": sid, "client": "ios", "enc_pub": "BASE64KEY", "device": "pranav-computer"}
    # canonical: sorted keys, no spaces — byte-for-byte what his signature covers
    assert frame["context"] == json.dumps(ctx, sort_keys=True, separators=(",", ":"))
    assert len(frame["context"]) <= 2400


def test_denied_or_expired_approval_releases_nothing(env):
    _status(env)
    denied = env.s.create("pc-1", "web", True, None)["session"]["id"]
    env.s.on_credential("pc-1", {"session_id": denied, "ok": False, "error": "Not allowed"})
    assert env.s.get(denied).state == "cancelled" and env.s.public(denied)["error"] == "Not allowed"
    slow = env.s.create("pc-1", "web", True, None)["session"]["id"]
    env.clock.t += 61
    assert env.s.get(slow).state == "cancelled"
    assert env.s.public(slow)["error"] == "No answer on your iPhone in 60 seconds"
    # a late credential for a cancelled session is dropped
    env.s.on_credential("pc-1", {"session_id": slow, "ok": True, "credential": {"password": "late"}})
    assert env.s.get(slow).state == "cancelled" and env.s.get(slow).credential is None


def test_credential_only_for_matching_session(env):
    _status(env)
    sid = env.s.create("pc-1", "web", True, None)["session"]["id"]
    env.s.on_credential("pc-2", {"session_id": sid, "ok": True, "credential": {"password": "x"}})   # another device
    assert env.s.get(sid).state == "approving"
    env.s.on_credential("pc-1", {"session_id": "nope", "ok": True, "credential": {"password": "x"}})
    # the web gets a password, the iPhone only ciphertext: the wrong shape is refused
    env.s.on_credential("pc-1", {"session_id": sid, "ok": True,
                                 "credential": {"ciphertext": "a", "ephemeral_pub": "b", "nonce": "c"}})
    assert env.s.get(sid).state == "approving"
    env.s.on_credential("pc-1", {"session_id": sid, "ok": True, "credential": {"password": "right"}})
    assert env.s.get(sid).state == "approved" and env.s.get(sid).credential == {"password": "right"}
    # one release per session
    env.s.on_credential("pc-1", {"session_id": sid, "ok": True, "credential": {"password": "again"}})
    assert env.s.get(sid).credential == {"password": "right"}


def test_web_password_never_logged(env, caplog):
    caplog.set_level(logging.DEBUG)
    _status(env)
    sid = env.s.create("pc-1", "web", True, None)["session"]["id"]
    env.s.on_credential("pc-1", {"session_id": sid, "ok": True, "credential": {"password": "S3cret-Pass"}})
    env.s.end(sid, "user")
    assert "S3cret-Pass" not in caplog.text
    assert env.s.get(sid).credential is None          # gone from memory once the session ends
    assert "S3cret-Pass" not in (env.s._audit_path.read_text() if env.s._audit_path.exists() else "")


def test_face_id_push_reads_in_his_words():
    from api.mac_power import _rdp_text
    ctx = RdpSessions.context(SimpleNamespace(id="s", client="web", enc_pub=None), "pranav-computer")
    assert _rdp_text(ctx) == "Connect to pranav-computer from the web"
    ctx = RdpSessions.context(SimpleNamespace(id="s", client="ios", enc_pub="K"), "pranav-computer")
    assert _rdp_text(ctx) == "Connect to pranav-computer from your iPhone"


def test_unreachable_pc_cancels_at_once(tmp_path):
    s = RdpSessions(send_frame=lambda d, f: False, settings=lambda: {}, device_name=lambda d: "pranav-computer")
    s.put_status("pc-1", dict(READY))
    sid = s.create("pc-1", "web", True, None)["session"]["id"]
    assert s.get(sid).state == "cancelled" and s.public(sid)["error"] == "pranav-computer didn't answer"
