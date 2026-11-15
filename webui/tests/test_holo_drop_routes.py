"""Holo Drop over HTTP: devices, drops, delivery, offline hold + wake, landed, off gating."""
from __future__ import annotations

import io
import sys
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import parse_qs, urlparse

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
    monkeypatch.setattr(routes, "_push", lambda title, body, data, device=None: pushes.append((title, body, data)))
    monkeypatch.setattr(routes, "_wake_mac", lambda dev: wakes.append(dev))
    monkeypatch.setattr(routes, "_settings", lambda: {"max_mb": 1, "direct": True, "defaults": ""})
    return SimpleNamespace(st=st, frames=frames, pushes=pushes, wakes=wakes, connected=connected)


def call(method, path, body=None, caller="iphone-1", raw=None, host=False, headers=None):
    box = {}
    parsed = urlparse(path)
    handler = SimpleNamespace(rfile=io.BytesIO(raw or b""),
                              headers={"Content-Length": str(len(raw or b"")), **(headers or {})})
    req = SimpleNamespace(method=method, path=parsed.path, parsed=parsed, body=body, host_signed=host,
                          prefix="/api/holo-drop", handler=handler, sub=parsed.path[len("/api/holo-drop"):],
                          device={"id": caller} if caller else None, query=parse_qs(parsed.query))
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
    # A saved spot stays until he changes it: the Mac waking or switching Wi-Fi doesn't clear it.
    call("POST", "/api/holo-drop/moved", {}, caller="mac-1")
    status, body = call("GET", "/api/holo-drop/devices")
    assert [d for d in body["devices"] if d["id"] == "mac-1"][0]["bearing"]["deg"] == 30


def test_unknown_target_is_400(env):
    status, body = call("POST", "/api/holo-drop/drops", {"kind": "text", "target": "nope", "text": "x"})
    assert status == 400


@pytest.fixture()
def cards(env, monkeypatch):
    started, later = [], []
    monkeypatch.setattr(routes, "_start_card", lambda drop, from_name: started.append((drop["id"], from_name)) or 1)
    monkeypatch.setattr(routes, "_later", lambda seconds, fn, *args: later.append((seconds, fn, args)))
    return SimpleNamespace(started=started, later=later)


def test_held_drop_for_phone_starts_waiting_card(env, cards):
    env.connected.discard("iphone-1")
    status, body = call("POST", "/api/holo-drop/drops", {"kind": "text", "target": "iphone-1", "text": "hi"},
                        caller="mac-1")
    assert body["drop"]["state"] == "held"
    assert cards.started == [(body["drop"]["id"], "MacBook")]
    assert env.pushes == []                            # the island card, no notification on top


def test_delivered_phone_drop_nobody_opens_gets_card_later(env, cards):
    status, body = call("POST", "/api/holo-drop/drops", {"kind": "link", "target": "iphone-1", "url": "https://a.b"},
                        caller="mac-1")
    assert body["drop"]["state"] == "delivered" and cards.started == []
    seconds, fn, args = cards.later[-1]
    assert 1 <= seconds <= 3                           # right away, not after a long wait
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


def test_web_tab_sender_hears_its_landing(env, cards):
    import queue as _q
    q = _q.Queue()
    routes._streams["ab1"] = q
    try:
        status, body = call("POST", "/api/holo-drop/drops", {"kind": "link", "target": "mac-1", "url": "https://a.b"},
                            caller=None, headers={"X-Holo-Tab": "ab1"})
        assert status == 200 and body["drop"]["from"] == "web:ab1" and body["drop"]["from_name"] == "Web"
        call("POST", f"/api/holo-drop/drops/{body['drop']['id']}/landed", {"outcome": "opened"}, caller="mac-1")
        event, drop = q.get_nowait()
        assert event == "landed" and drop["outcome"] == "opened"
    finally:
        routes._streams.pop("ab1", None)


def test_web_sender_does_not_see_web_target(env):
    import queue as _q
    routes._streams["ab2"] = _q.Queue()
    routes._claimed["tab"] = "ab2"
    try:
        status, body = call("GET", "/api/holo-drop/devices", caller=None, headers={"X-Holo-Tab": "ab2"})
        assert "web" not in [d["id"] for d in body["devices"]]
        status, body = call("GET", "/api/holo-drop/devices")              # the iPhone does see it
        assert "web" in [d["id"] for d in body["devices"]]
    finally:
        routes._streams.pop("ab2", None)
        routes._claimed["tab"] = None


# ── bug sweep (2026-11-14) ─────────────────────────────────────────────────────
class _BodyTrap(SimpleNamespace):
    """A request whose JSON body must never be read (a raw-body route would lose its bytes)."""
    @property
    def body(self):
        raise AssertionError("route read req.body before the raw-body handler")


def test_upload_never_reads_the_json_body(env):
    raw = b"x" * 10
    parsed = urlparse("/api/holo-drop/drops/upload?kind=file&target=mac-1&name=a.bin&mime=application/octet-stream")
    box = {}
    handler = SimpleNamespace(rfile=io.BytesIO(raw), headers={"Content-Length": str(len(raw))})
    req = _BodyTrap(method="POST", path=parsed.path, parsed=parsed, host_signed=False, prefix="/api/holo-drop",
                    handler=handler, sub=parsed.path[len("/api/holo-drop"):], device={"id": "iphone-1"},
                    query={k: [v] for k, v in (p.split("=") for p in parsed.query.split("&"))})
    req.reply = lambda status, payload: box.update(status=status, body=payload) or True
    routes.route(req)
    assert box["status"] == 200 and box["body"]["drop"]["kind"] == "file"


def test_jc_client_mac_is_a_target_but_boards_are_not(env, monkeypatch):
    monkeypatch.setattr(routes, "_paired", lambda: [
        {"id": "mac-9", "name": "Pranavs-MacBook-Pro.local", "kind": "browser", "user_agent": "jc-client/0.1"},
        {"id": "pod-1", "name": "Jarvis Pod", "kind": "browser", "user_agent": "JarvisPod/2.5.0"},
        {"id": "web-9", "name": "Macbook Web", "kind": "browser", "user_agent": "Mozilla/5.0 (Macintosh)"},
    ])
    kinds = {d["id"]: d["kind"] for d in call("GET", "/api/holo-drop/devices")[1]["devices"]}
    assert kinds.get("mac-9") == "mac" and "pod-1" not in kinds and "web-9" not in kinds


def test_content_headers_survive_any_name_and_mime(env):
    sent = {}
    status, body = call("POST", "/api/holo-drop/drops/upload?kind=image&target=mac-1"
                        "&name=Screenshot%209.41.03%E2%80%AFPM%0D%0ASet-Cookie%3A%20x%3D1.png&mime=image/png%0D%0AX-Evil%3A%201",
                        raw=b"pngbytes")
    d = env.st.get(body["drop"]["id"])

    class H:
        wfile = io.BytesIO()
        def send_response(self, code): sent["status"] = code
        def send_header(self, k, v):
            v.encode("latin-1")                        # the real send_header encodes strictly
            assert "\r" not in v and "\n" not in v, (k, v)
            sent[k] = v
        def end_headers(self): pass

    req = SimpleNamespace(handler=H(), reply=lambda s, p: True)
    routes._content(req, d)
    assert sent["status"] == 200 and sent["Content-Type"] == "application/octet-stream"
    assert "attachment" in sent["Content-Disposition"]


def test_waiting_card_announced_once_and_only_to_the_target(env, monkeypatch):
    started, later = [], []
    monkeypatch.setattr(routes, "_start_card", lambda drop, from_name: started.append(drop["id"]))
    monkeypatch.setattr(routes, "_later", lambda s, fn, *a: later.append((fn, a)))
    pushed_to = []
    monkeypatch.setattr(routes, "_push", lambda title, body, data, device=None: pushed_to.append((device, body)))
    env.connected.discard("iphone-1")
    status, body = call("POST", "/api/holo-drop/drops", {"kind": "link", "target": "iphone-1",
                                                          "url": "https://a.b/" + "x" * 3000}, caller="mac-1")
    env.connected.add("iphone-1")
    routes.deliver_held()                              # phone back in the background
    for fn, a in later:
        fn(*a)                                         # nobody opened it
    assert started == [body["drop"]["id"]]             # one card, not two
    assert pushed_to and all(dev == "iphone-1" for dev, _ in pushed_to)
    assert all(len(b) <= 200 for _, b in pushed_to)


def test_upload_in_progress_is_not_pending(env):
    d = env.st.create("video", sender="iphone-1", target="mac-1", name="big.mov", mime="video/quicktime")
    status, body = call("GET", "/api/holo-drop/pending", caller="mac-1")
    assert d["id"] not in [x["id"] for x in body["drops"]]


def test_second_landed_report_does_not_tell_sender_again(env):
    status, body = call("POST", "/api/holo-drop/drops", {"kind": "text", "target": "mac-1", "text": "hi"})
    n0 = len(env.frames)
    call("POST", f"/api/holo-drop/drops/{body['drop']['id']}/landed", {"outcome": "copied"}, caller="mac-1")
    call("POST", f"/api/holo-drop/drops/{body['drop']['id']}/landed", {"outcome": "copied"}, caller="mac-1")
    landed = [f for _, f in env.frames[n0:] if f.get("event") == "landed"]
    assert len(landed) == 1


def test_held_redelivery_does_not_undo_a_landing(env):
    env.connected.discard("mac-1")
    status, body = call("POST", "/api/holo-drop/drops", {"kind": "text", "target": "mac-1", "text": "hi"})
    snapshot = env.st.held()
    call("POST", f"/api/holo-drop/drops/{body['drop']['id']}/landed", {"outcome": "copied"}, caller="mac-1")
    env.connected.add("mac-1")
    for d in snapshot:                                 # the sweeper's stale snapshot
        routes.deliver(d)
    assert env.st.get(body["drop"]["id"])["state"] == "landed"


def test_upload_finishing_after_switch_off_is_refused_and_removed(env, monkeypatch):
    monkeypatch.setattr(routes, "_power_on", lambda: False)
    status, body = call("POST", "/api/holo-drop/drops/upload?kind=file&target=mac-1&name=a.bin&mime=x/y",
                        raw=b"abc")
    assert status == 409
    assert list((env.st.root / "files").glob("*")) == []


def test_expired_held_drop_tells_the_sender(env):
    env.connected.discard("mac-1")
    status, body = call("POST", "/api/holo-drop/drops", {"kind": "text", "target": "mac-1", "text": "hi"})
    env.st.clock = lambda: 10 ** 10
    routes.sweep_and_tell()
    told = [f for d, f in env.frames if d == "iphone-1" and f.get("event") == "landed"]
    assert told and told[-1]["drop"]["state"] == "failed" and "expired" in (told[-1]["drop"]["error"] or "")


def test_bad_numbers_are_not_server_errors(env):
    req_status, body = call("GET", "/api/holo-drop/history?limit=abc")
    assert req_status == 200


def test_bearing_without_direction_is_not_stored_and_junk_is_not_500(env):
    status, _ = call("POST", "/api/holo-drop/bearings", {"bearings": [{"device": "mac-1", "confidence": 0.2,
                                                                         "distance_m": 2}]})
    assert status == 200
    mac = [d for d in call("GET", "/api/holo-drop/devices")[1]["devices"] if d["id"] == "mac-1"][0]
    assert mac["bearing"] is None
    status, _ = call("POST", "/api/holo-drop/bearings", {"bearings": [{"device": "mac-1", "deg": "north"}]})
    assert status in (200, 400)


def test_text_targets_use_the_real_pod_and_glasses_skills():
    picked = routes._pick_text_skills({
        "iphone-1": ["glasses_show_transcription", "glasses_show_answer", "add_calendar_event"],
        "pod-1": ["pod_status", "pod_show", "pod_reboot"],
    })
    by_kind = {t["kind"]: t for t in picked}
    assert by_kind["glasses"]["skill"] == "glasses_show_answer" and by_kind["glasses"]["via"] == "iphone-1"
    assert by_kind["pod"]["skill"] == "pod_show" and by_kind["pod"]["id"] == "pod:pod-1"
    pod_args = routes._text_args("pod", {"kind": "link", "url": "https://a.b", "title": "A page", "from_name": "iPhone"})
    texts = [c.get("value") for c in pod_args["page"]["root"]["children"]]
    assert "A page" in texts or "https://a.b" in texts
    assert routes._text_args("glasses", {"kind": "text", "text": "hi"})["text"] == "hi"


def test_banner_only_when_the_island_card_cannot_start(env, monkeypatch):
    monkeypatch.setattr(routes, "_start_card", lambda drop, from_name: 0)   # no push-to-start token
    monkeypatch.setattr(routes, "_later", lambda s, fn, *a: None)
    env.connected.discard("iphone-1")
    call("POST", "/api/holo-drop/drops", {"kind": "text", "target": "iphone-1", "text": "hi"}, caller="mac-1")
    assert env.pushes and "MacBook" in env.pushes[-1][1]


def test_history_names_the_sender_and_target(env):
    call("POST", "/api/holo-drop/drops", {"kind": "text", "target": "iphone-1", "text": "hi"}, caller="mac-1")
    status, body = call("GET", "/api/holo-drop/history?limit=5", caller="iphone-1")
    d = body["drops"][0]
    assert d["from_name"] == "MacBook" and d["target"] == "iphone-1" and "file" not in d


def _bearing(source, deg):
    call("POST", "/api/holo-drop/bearings", {"bearings": [{"device": "mac-1", "deg": deg, "confidence": .6,
                                                          "source": source}]})
    status, body = call("GET", "/api/holo-drop/devices")
    return [d for d in body["devices"] if d["id"] == "mac-1"][0]["bearing"]


def test_a_throw_teaches_a_direction_but_never_overrides_one_he_set(env):
    assert _bearing("throw", 90)["deg"] == 90          # nothing saved: the throw teaches it
    assert _bearing("throw", 100)["deg"] == 100        # a later throw updates what a throw taught
    assert _bearing("set", 30)["deg"] == 30            # he points at it: that wins
    assert _bearing("throw", 120)["deg"] == 30         # and throws don't move it
    assert _bearing("look", 40)["deg"] == 40           # locating again does
    assert _bearing("throw", 50)["deg"] == 40
    assert _bearing("ultrasonic", 60)["deg"] == 60     # so does listening for it
    assert _bearing("throw", 70)["deg"] == 60


@pytest.fixture()
def wearables(env, monkeypatch):
    shown = []
    monkeypatch.setattr(routes, "_text_targets", lambda: [
        {"id": "pod:pod-1", "kind": "pod", "via": "pod-1", "skill": "pod_show"},
        {"id": "glasses:iphone-1", "kind": "glasses", "via": "iphone-1", "skill": "glasses_show_answer"},
    ])
    monkeypatch.setattr(routes, "_invoke", lambda via, skill, args: shown.append((via, skill, args)) or True)
    return shown


def test_pod_and_glasses_show_up_for_every_kind(env, wearables):
    status, body = call("GET", "/api/holo-drop/devices")
    by_id = {d["id"]: d for d in body["devices"]}
    for target in ("pod:pod-1", "glasses:iphone-1"):
        assert {"link", "text", "image", "video", "file"} <= set(by_id[target]["accepts"])


def _jpeg(size=(1200, 900)):
    from PIL import Image
    out = io.BytesIO()
    Image.new("RGB", size, (200, 120, 40)).save(out, "JPEG", quality=95)
    return out.getvalue()


def test_a_photo_thrown_at_the_pod_shows_on_its_screen(env, wearables):
    status, body = call("POST", "/api/holo-drop/drops/upload?kind=image&target=pod:pod-1&name=IMG_1.jpg&mime=image/jpeg",
                        raw=_jpeg())
    assert status == 200 and body["drop"]["state"] == "landed"
    via, skill, args = wearables[-1]
    assert (via, skill) == ("pod-1", "pod_show")
    images = [c for c in args["page"]["root"]["children"] if c.get("type") == "image"]
    assert images and images[0]["source"].startswith("data:image/jpeg;base64,")
    assert len(images[0]["source"]) <= 140000            # the Pod's limit


def test_a_file_the_pod_cannot_draw_becomes_a_text_card(env, wearables):
    status, body = call("POST", "/api/holo-drop/drops/upload?kind=image&target=pod:pod-1&name=IMG_2.HEIC&mime=image/heic",
                        raw=b"not a picture the server can read")
    assert status == 200 and body["drop"]["state"] == "landed"
    children = wearables[-1][2]["page"]["root"]["children"]
    assert all(c.get("type") != "image" for c in children)
    assert any("IMG_2.HEIC" in str(c.get("value")) for c in children)


def test_a_photo_thrown_at_the_glasses_is_a_line_of_text(env, wearables):
    status, body = call("POST", "/api/holo-drop/drops/upload?kind=image&target=glasses:iphone-1&name=IMG_3.jpg&mime=image/jpeg",
                        raw=_jpeg())
    assert status == 200 and body["drop"]["state"] == "landed"
    via, skill, args = wearables[-1]
    assert skill == "glasses_show_answer"
    assert "Photo" in args["text"] and "IMG_3.jpg" in args["text"]


def test_a_video_thrown_at_the_pod_shows_its_first_frame(env, wearables):
    status, body = call("POST", "/api/holo-drop/drops/upload?kind=video&target=pod:pod-1&name=IMG_4.MOV&mime=image/jpeg",
                        raw=_jpeg((640, 360)))
    assert status == 200 and body["drop"]["state"] == "landed"
    children = wearables[-1][2]["page"]["root"]["children"]
    assert children[0]["type"] == "image"
    assert any("Video from" in str(c.get("value")) for c in children)

