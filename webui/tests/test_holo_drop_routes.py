"""Holo Drop over HTTP: devices, drops, delivery, offline hold + wake, landed, off gating."""
from __future__ import annotations

import io
import sys
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import urlparse

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import api.holo_drop_routes as routes  # noqa: E402
from api.holo_drop_store import HoloStore  # noqa: E402

DEVICES = [
    {"id": "iphone-1", "name": "Pranav's iPhone", "kind": "mobile-ios"},
    {"id": "mac-1", "name": "MacBook", "kind": "desktop"},
    {"id": "web-1", "name": "Chrome", "kind": "browser"},
]


@pytest.fixture()
def env(tmp_path, monkeypatch):
    st = HoloStore(tmp_path / "holo")
    frames, pushes, wakes = [], [], []
    connected = {"iphone-1", "mac-1"}
    monkeypatch.setattr(routes, "store", lambda: st)
    monkeypatch.setattr(routes, "_paired", lambda: list(DEVICES))
    monkeypatch.setattr(routes, "_connected", lambda: set(connected))
    monkeypatch.setattr(routes, "_send_frame", lambda dev, frame: frames.append((dev, frame)) or dev in connected)
    monkeypatch.setattr(routes, "_push", lambda title, body, data: pushes.append((title, body, data)))
    monkeypatch.setattr(routes, "_wake_mac", lambda dev: wakes.append(dev))
    monkeypatch.setattr(routes, "_settings", lambda: {"max_mb": 1, "direct": True, "defaults": ""})
    return SimpleNamespace(st=st, frames=frames, pushes=pushes, wakes=wakes, connected=connected)


def call(method, path, body=None, caller="iphone-1", raw=None, host=False):
    box = {}
    parsed = urlparse(path)
    handler = SimpleNamespace(rfile=io.BytesIO(raw or b""), headers={"Content-Length": str(len(raw or b""))})
    req = SimpleNamespace(method=method, path=parsed.path, parsed=parsed, body=body, host_signed=host,
                          prefix="/api/holo-drop", handler=handler, sub=parsed.path[len("/api/holo-drop"):],
                          device={"id": caller} if caller else None)
    req.reply = lambda status, payload: box.update(status=status, body=payload) or True
    assert routes.route(req) is not False
    return box["status"], box["body"]


def test_devices_excludes_caller_and_maps_kinds(env):
    status, body = call("GET", "/api/holo-drop/devices")
    kinds = {d["id"]: d["kind"] for d in body["devices"]}
    assert "iphone-1" not in kinds and kinds["mac-1"] == "mac"
    mac = [d for d in body["devices"] if d["id"] == "mac-1"][0]
    assert mac["online"] is True and mac["aim"] is True and mac["default_action"] == "open"


def test_link_drop_delivered_and_landed_notifies_sender(env):
    status, body = call("POST", "/api/holo-drop/drops",
                        {"kind": "link", "target": "mac-1", "url": "https://x.y", "position": {"x": .8, "y": .2}})
    drop = body["drop"]
    assert status == 200 and drop["state"] == "delivered"
    dev, frame = env.frames[-1]
    assert dev == "mac-1" and frame["event"] == "drop" and frame["drop"]["url"] == "https://x.y"
    assert frame["drop"]["position"] == {"x": 0.8, "y": 0.2}
    assert frame["drop"]["from_name"] == "Pranav's iPhone"
    call("POST", f"/api/holo-drop/drops/{drop['id']}/landed", {"outcome": "opened"}, caller="mac-1")
    dev, frame = env.frames[-1]
    assert dev == "iphone-1" and frame["event"] == "landed" and frame["drop"]["outcome"] == "opened"


def test_offline_target_is_held_then_delivered(env):
    env.connected.discard("mac-1")
    status, body = call("POST", "/api/holo-drop/drops", {"kind": "text", "target": "mac-1", "text": "hi"})
    assert body["drop"]["state"] == "held" and env.wakes == ["mac-1"]
    status, body = call("GET", "/api/holo-drop/pending", caller="mac-1")
    assert [d["text"] for d in body["drops"]] == ["hi"]
    env.connected.discard("iphone-1")                 # sender away: landing comes as a push
    call("POST", f"/api/holo-drop/drops/{body['drops'][0]['id']}/landed", {"outcome": "copied"}, caller="mac-1")
    assert env.pushes and "MacBook" in env.pushes[-1][1]


def test_upload_and_content_and_cap(env):
    status, body = call("POST", "/api/holo-drop/drops/upload?kind=image&target=mac-1&name=a.png&mime=image/png",
                        raw=b"PNGDATA")
    did = body["drop"]["id"]
    status, _ = call("GET", f"/api/holo-drop/drops/{did}/content", caller="mac-1")
    assert status == 200
    big = b"x" * (1024 * 1024 + 1)
    status, body = call("POST", "/api/holo-drop/drops/upload?kind=file&target=mac-1&name=b.bin", raw=big)
    assert status == 413


def test_bearings_round_trip_and_moved(env):
    call("POST", "/api/holo-drop/bearings", {"bearings": [{"device": "mac-1", "deg": 30, "confidence": .9,
                                                          "source": "look"}]})
    status, body = call("GET", "/api/holo-drop/devices")
    assert [d for d in body["devices"] if d["id"] == "mac-1"][0]["bearing"]["deg"] == 30
    call("POST", "/api/holo-drop/moved", {}, caller="mac-1")
    status, body = call("GET", "/api/holo-drop/devices")
    assert [d for d in body["devices"] if d["id"] == "mac-1"][0]["bearing"] is None


def test_unknown_target_is_400(env):
    status, body = call("POST", "/api/holo-drop/drops", {"kind": "text", "target": "nope", "text": "x"})
    assert status == 400


@pytest.fixture()
def cards(env, monkeypatch):
    started, later = [], []
    monkeypatch.setattr(routes, "_start_card", lambda drop, from_name: started.append((drop["id"], from_name)))
    monkeypatch.setattr(routes, "_later", lambda seconds, fn, *args: later.append((seconds, fn, args)))
    return SimpleNamespace(started=started, later=later)


def test_held_drop_for_phone_starts_waiting_card(env, cards):
    env.connected.discard("iphone-1")
    status, body = call("POST", "/api/holo-drop/drops", {"kind": "text", "target": "iphone-1", "text": "hi"},
                        caller="mac-1")
    assert body["drop"]["state"] == "held"
    assert cards.started == [(body["drop"]["id"], "MacBook")]
    assert env.pushes and "MacBook" in env.pushes[-1][1]


def test_delivered_phone_drop_nobody_opens_gets_card_later(env, cards):
    status, body = call("POST", "/api/holo-drop/drops", {"kind": "link", "target": "iphone-1", "url": "https://a.b"},
                        caller="mac-1")
    assert body["drop"]["state"] == "delivered" and cards.started == []
    seconds, fn, args = cards.later[-1]
    assert 4 <= seconds <= 15
    fn(*args)                                          # the phone never picked it up
    assert cards.started == [(body["drop"]["id"], "MacBook")]


def test_delivered_phone_drop_picked_up_gets_no_card(env, cards):
    status, body = call("POST", "/api/holo-drop/drops", {"kind": "link", "target": "iphone-1", "url": "https://a.b"},
                        caller="mac-1")
    call("GET", f"/api/holo-drop/drops/{body['drop']['id']}", caller="iphone-1")
    seconds, fn, args = cards.later[-1]
    fn(*args)
    assert cards.started == []


def test_mac_target_never_gets_phone_card(env, cards):
    env.connected.discard("mac-1")
    call("POST", "/api/holo-drop/drops", {"kind": "text", "target": "mac-1", "text": "hi"})
    assert cards.started == [] and cards.later == []


def test_direct_drop_is_recorded_as_landed(env, cards):
    status, body = call("POST", "/api/holo-drop/drops",
                        {"kind": "link", "target": "mac-1", "url": "https://a.b", "delivered_direct": True,
                         "outcome": "opened"})
    assert body["drop"]["state"] == "landed" and body["drop"]["outcome"] == "opened"
    assert env.frames == [] and cards.later == []


def test_direct_file_drop_records_kind_and_name(env, cards):
    status, body = call("POST", "/api/holo-drop/drops",
                        {"kind": "image", "target": "mac-1", "name": "IMG_1.HEIC", "mime": "image/heic",
                         "size": 2048, "delivered_direct": True, "outcome": "saved"})
    assert status == 200 and body["drop"]["kind"] == "image" and body["drop"]["name"] == "IMG_1.HEIC"
    status, body = call("POST", "/api/holo-drop/drops", {"kind": "image", "target": "mac-1", "name": "x"})
    assert status == 400                               # files without bytes only when delivered direct
