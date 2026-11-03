"""Mac screen shares: signalling between a viewer and the Mac, TURN credentials, replays.

The server never carries video. What it must get right: a viewer's offer reaches
the Mac and the Mac's answer reaches that viewer (and only it), a long poll waits
without holding up anything else, a share ends cleanly from either side, TURN
passwords match coturn's REST scheme, and replays are MP4s served with Range.
"""
import base64
import hashlib
import hmac
import io
import json
import threading
import time
from types import SimpleNamespace
from urllib.parse import urlparse

import pytest
import yaml

from api import screen_share as ss


@pytest.fixture
def reg(tmp_path, monkeypatch):
    cfg = tmp_path / "config.yaml"
    monkeypatch.setenv("HERMES_CONFIG_PATH", str(cfg))
    return ss.reset_for_tests(tmp_path / "screen")


def _mp4(size=4096):
    return b"\x00\x00\x00\x18ftypisom" + b"\x00" * (size - 12)


class _Handler:
    """Just enough of BaseHTTPRequestHandler for api.helpers.j and the file server."""

    def __init__(self, body=b"", headers=None):
        self.rfile = io.BytesIO(body)
        self.wfile = io.BytesIO()
        self.headers = {"Content-Length": str(len(body)), **(headers or {})}
        self.status = None
        self.sent = {}

    def send_response(self, status):
        self.status = status

    def send_header(self, k, v):
        self.sent[k] = v

    def end_headers(self):
        pass

    def json(self):
        return json.loads(self.wfile.getvalue())


def _get(path):
    h = _Handler()
    assert ss.handle_get(h, urlparse(path))
    return h


def _post(path, body=None, raw=None):
    data = raw if raw is not None else json.dumps(body or {}).encode()
    h = _Handler(data)
    assert ss.handle_post(h, urlparse(path))
    return h


def test_a_viewer_offer_reaches_the_mac_and_the_answer_comes_back(reg):
    share = _post("/api/screen/shares", {"reason": "anytime"}).json()
    sid = share["id"]
    assert share["status"] == "requested" and "ice_servers" in share
    assert _get("/api/screen/shares?active=1&from=mac").json()["shares"][0]["id"] == sid

    seq = _post(f"/api/screen/shares/{sid}/signal", {"from": "viewer", "type": "offer", "sdp": "v=0 offer"}).json()
    assert seq["ok"] and seq["seq"] == 1
    got = _get(f"/api/screen/shares/{sid}/signal?for=mac&after=0&wait=0").json()
    assert [m["type"] for m in got["messages"]] == ["offer"]
    assert reg.get(sid)["status"] == "live"  # the Mac polling its signals = capturing

    _post(f"/api/screen/shares/{sid}/signal", {"from": "mac", "type": "answer", "sdp": "v=0 answer"})
    _post(f"/api/screen/shares/{sid}/signal", {"from": "mac", "type": "candidate",
                                              "candidate": {"candidate": "candidate:1 1 udp 1 1.2.3.4 5 typ host",
                                                            "sdpMid": "0", "sdpMLineIndex": 0}})
    back = _get(f"/api/screen/shares/{sid}/signal?for=viewer&after=1&wait=0").json()["messages"]
    assert [m["type"] for m in back] == ["answer", "candidate"]
    assert back[1]["candidate"]["sdpMLineIndex"] == 0
    # A viewer never gets its own messages back, and `after` skips what it has seen.
    again = _get(f"/api/screen/shares/{sid}/signal?for=viewer&after={back[-1]['seq']}&wait=0").json()
    assert again["messages"] == []


def test_two_viewers_each_get_only_their_own_answer(reg):
    sid = reg.create("anytime")["id"]
    reg.post_signal(sid, {"from": "viewer", "type": "offer", "sdp": "a", "viewer": "web1"})
    reg.post_signal(sid, {"from": "viewer", "type": "offer", "sdp": "b"})  # the phone: no viewer id
    reg.post_signal(sid, {"from": "mac", "type": "answer", "sdp": "for-web", "viewer": "web1"})
    reg.post_signal(sid, {"from": "mac", "type": "answer", "sdp": "for-phone"})
    web = reg.wait_signal(sid, "viewer", 0, viewer="web1", timeout=0)["messages"]
    phone = reg.wait_signal(sid, "viewer", 0, timeout=0)["messages"]
    assert [m["sdp"] for m in web] == ["for-web"]
    assert [m["sdp"] for m in phone] == ["for-phone"]
    assert reg.get(sid)["viewers"] == 2


def test_a_long_poll_wakes_on_a_message_and_blocks_nothing_else(reg):
    sid = reg.create("anytime")["id"]
    other = reg.create("task", "open Calculator")["id"]
    out = {}

    def wait():
        out["r"] = reg.wait_signal(sid, "mac", 0, timeout=10)

    t = threading.Thread(target=wait)
    t0 = time.monotonic()
    t.start()
    time.sleep(0.2)
    # Other requests go through while the poll waits.
    assert reg.get(other)["status"] == "requested"
    assert len(reg.list(active=True)) == 2
    reg.post_signal(sid, {"from": "viewer", "type": "offer", "sdp": "x"})
    t.join(5)
    assert not t.is_alive() and time.monotonic() - t0 < 3
    assert [m["type"] for m in out["r"]["messages"]] == ["offer"]


def test_a_long_poll_times_out_empty_and_is_capped(reg, monkeypatch):
    sid = reg.create("anytime")["id"]
    t0 = time.monotonic()
    assert reg.wait_signal(sid, "mac", 0, timeout=0.3)["messages"] == []
    assert 0.25 < time.monotonic() - t0 < 2
    monkeypatch.setattr(ss, "LONG_POLL_MAX", 0.2)
    t0 = time.monotonic()
    reg.wait_signal(sid, "mac", 0, timeout=60)
    assert time.monotonic() - t0 < 1.5


def test_stop_ends_the_share_and_wakes_both_sides(reg):
    sid = reg.create("task", "x")["id"]
    out = {}
    t = threading.Thread(target=lambda: out.setdefault("mac", reg.wait_signal(sid, "mac", 0, timeout=10)))
    t.start()
    time.sleep(0.1)
    assert _post(f"/api/screen/shares/{sid}/stop").json() == {"ok": True}
    t.join(5)
    assert out["mac"]["status"] == "ended"
    viewer = reg.wait_signal(sid, "viewer", 0, timeout=0)
    assert viewer["messages"][-1]["type"] == "bye"
    share = _get(f"/api/screen/shares/{sid}").json()
    assert share["status"] == "ended" and share["ended_at"]
    assert _get("/api/screen/shares?active=1").json()["shares"] == []
    assert _post(f"/api/screen/shares/{sid}/signal", {"from": "viewer", "type": "offer", "sdp": "x"}).status == 410


def test_bad_signals_are_refused(reg):
    sid = reg.create("anytime")["id"]
    for body in ({"from": "x", "type": "offer", "sdp": "a"}, {"from": "viewer", "type": "nope"},
                 {"from": "viewer", "type": "offer"}, {"from": "mac", "type": "candidate", "candidate": "x"},
                 {"from": "viewer", "type": "bye", "viewer": "has spaces"}):
        assert _post(f"/api/screen/shares/{sid}/signal", body).status == 400
    assert _post("/api/screen/shares/scr_nope00/signal", {"from": "viewer", "type": "bye"}).status == 404
    assert _post("/api/screen/shares", {"reason": "spy"}).status == 400


def test_an_anytime_share_nobody_watches_ends(reg, monkeypatch):
    sid = reg.create("anytime")["id"]
    later = time.time() + ss.ANYTIME_IDLE_END + 5
    monkeypatch.setattr(ss, "_now", lambda: later)
    share = reg.get(sid)
    assert share["status"] == "ended" and share["error"] == "no one is watching"


def test_mac_online_follows_its_list_polls(reg, monkeypatch):
    sid = reg.create("task", "x")["id"]
    assert reg.get(sid)["mac_online"] is False
    reg.list(active=True, from_mac=True)
    assert reg.get(sid)["mac_online"] is True
    later = time.time() + ss.MAC_FRESH + 1
    monkeypatch.setattr(ss, "_now", lambda: later)
    assert reg.get(sid)["mac_online"] is False


def test_turn_credentials_match_coturns_rest_scheme(reg, tmp_path):
    user, cred = ss.turn_credentials("s3cret", now=1000, ttl=60)
    assert user == "1060:jarvis"
    want = base64.b64encode(hmac.new(b"s3cret", b"1060:jarvis", hashlib.sha1).digest()).decode()
    assert cred == want


def test_ice_servers_make_the_secret_once_and_list_turn_when_a_host_is_set(reg, tmp_path):
    cfg = tmp_path / "config.yaml"
    cfg.write_text(yaml.safe_dump({"model": {"default": "x"}, "screen": {"turn_host": "203.0.113.7"}}))
    servers = _get("/api/screen/ice").json()["ice_servers"]
    stored = yaml.safe_load(cfg.read_text())
    secret = stored["screen"]["turn_secret"]
    assert len(secret) >= 32 and stored["model"] == {"default": "x"}  # the rest of config.yaml kept
    turn = next(s for s in servers if "username" in s)
    assert turn["urls"] == ["turn:203.0.113.7:3478?transport=udp", "turn:203.0.113.7:3478?transport=tcp"]
    expiry, name = turn["username"].split(":")
    assert name == "jarvis" and int(expiry) > time.time() + 11 * 3600
    assert turn["credential"] == ss.turn_credentials(secret, now=int(expiry) - ss.TURN_TTL)[1]
    ss.ice_servers()
    assert yaml.safe_load(cfg.read_text())["screen"]["turn_secret"] == secret  # made once


def test_without_a_turn_host_only_stun_is_offered(reg):
    servers = ss.ice_servers()
    assert servers and all("username" not in s for s in servers)


def test_a_replay_is_stored_and_served_with_range(reg):
    sid = reg.create("task", "x")["id"]
    data = _mp4(5000)
    up = _post(f"/api/screen/shares/{sid}/replay", raw=data).json()
    assert up == {"ok": True, "replay_url": f"/api/screen/replays/{sid}.mp4"}
    assert reg.get(sid)["replay_url"] == up["replay_url"]
    h = _Handler(headers={"Range": "bytes=0-99"})
    assert ss.handle_get(h, urlparse(up["replay_url"]))
    assert h.status == 206 and h.sent["Content-Type"] == "video/mp4"
    assert h.wfile.getvalue() == data[:100]
    assert _get("/api/screen/replays/scr_missing1.mp4").status == 404


def test_a_replay_that_is_not_an_mp4_or_too_big_is_refused(reg, monkeypatch):
    sid = reg.create("task", "x")["id"]
    assert _post(f"/api/screen/shares/{sid}/replay", raw=b"<html>" * 10).status == 400
    monkeypatch.setattr(ss, "MAX_REPLAY_BYTES", 100)
    assert _post(f"/api/screen/shares/{sid}/replay", raw=_mp4(200)).status == 400
    assert reg.get(sid)["replay_url"] is None
    assert not list((reg.root() / "replays").glob("*.part"))


def test_ended_shares_survive_a_restart_and_live_ones_end(reg, tmp_path):
    done = reg.create("task", "x")["id"]
    reg.store_replay(done, io.BytesIO(_mp4()), 4096)
    reg.stop(done)
    live = reg.create("anytime")["id"]
    fresh = ss.reset_for_tests(tmp_path / "screen")
    assert fresh.get(done)["replay_url"] and fresh.get(done)["status"] == "ended"
    assert fresh.get(live)["status"] == "ended" and fresh.get(live)["error"] == "the server restarted"


def test_cleanup_forgets_old_shares_and_their_replays(reg):
    old = reg.create("task", "x")["id"]
    reg.store_replay(old, io.BytesIO(_mp4()), 4096)
    reg.stop(old)
    keep = reg.create("task", "y")["id"]
    reg.store_replay(keep, io.BytesIO(_mp4()), 4096)
    removed = reg.cleanup(now=time.time() + ss.RETENTION + 60)
    assert removed == 1 and reg.get(old) is None and reg.get(keep) is not None
    assert not (reg.root() / "replays" / f"{old}.mp4").exists()


def test_the_router_hands_screen_paths_to_the_share_module():
    src = (__import__("pathlib").Path(ss.__file__).with_name("routes.py")).read_text()
    assert 'parsed.path.startswith("/api/screen/")' in src
    # The POST hook sits before the router reads a JSON body (the replay is raw MP4).
    assert src.index("screen_share.handle_post") < src.index('diag.stage("read_body")')


# ── Cloudflare TURN ──────────────────────────────────────────────────────────

class _FakeResp:
    def __init__(self, body):
        self._body = body

    def raise_for_status(self):
        pass

    def json(self):
        return self._body


def test_cloudflare_turn_mints_servers_drops_port_53_and_caches(monkeypatch):
    import httpx
    from api import screen_share as ss

    calls = []

    def fake_post(url, headers=None, json=None, timeout=None):
        calls.append((url, headers, json))
        return _FakeResp({"iceServers": [
            {"urls": ["stun:stun.cloudflare.com:3478", "stun:stun.cloudflare.com:53"]},
            {"urls": ["turn:turn.cloudflare.com:3478?transport=udp", "turn:turn.cloudflare.com:53?transport=udp",
                      "turns:turn.cloudflare.com:443?transport=tcp"],
             "username": "u1", "credential": "c1"}]})

    monkeypatch.setenv("CLOUDFLARE_TURN_KEY", "abc123:tok456")
    monkeypatch.setattr(httpx, "post", fake_post)
    ss._cf_cache.update(key="", servers=None, until=0.0, failed_until=0.0)
    servers = ss.ice_servers(now=1000.0)
    assert calls[0][0].endswith("/turn/keys/abc123/credentials/generate-ice-servers")
    assert calls[0][1]["Authorization"] == "Bearer tok456"
    urls = [u for s in servers for u in s["urls"]]
    assert not any(":53" in u for u in urls)
    turn = next(s for s in servers if s.get("username"))
    assert turn["credential"] == "c1"
    ss.ice_servers(now=1001.0)
    assert len(calls) == 1, "cached until half the ttl"


def test_cloudflare_failure_falls_back_to_stun(monkeypatch):
    import httpx
    from api import screen_share as ss

    def boom(*a, **k):
        raise httpx.ConnectError("down")

    monkeypatch.setenv("CLOUDFLARE_TURN_KEY", "abc123:tok456")
    monkeypatch.setattr(httpx, "post", boom)
    ss._cf_cache.update(key="", servers=None, until=0.0, failed_until=0.0)
    servers = ss.ice_servers(now=5000.0)
    assert servers and all(not s.get("username") or "turn:" in s["urls"][0] for s in servers)
    assert any(u.startswith("stun:") for s in servers for u in s["urls"])
