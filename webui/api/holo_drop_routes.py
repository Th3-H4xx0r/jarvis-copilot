"""Holo Drop over HTTP — mounted at /api/holo-drop (Power-gated: 409 while switched off).

The contract every client codes to is in docs/superpowers/plans/2026-11-14-holo-drop.md.
Drops go to devices over the device bridge (frame ``{"type": "holo_drop", "event": ...}``),
to the latest web tab over SSE, and to glasses / the Pod through their text skills. A target
that isn't reachable gets the drop held (a Mac is woken) and delivered when it's back.
"""
from __future__ import annotations

import json
import logging
import queue
import re
import secrets
import threading
import time
from typing import Optional

from api.holo_drop_store import TooLarge, store

logger = logging.getLogger(__name__)

ACTIONS = ("save", "open", "copy", "save_open", "save_copy")
KINDS = ("link", "text", "image", "video", "file")
_TEXT_SKILLS = {
    "glasses": re.compile(r"^(go3|glasses|inmo|lens)_(show|card|text|display)"),
    "pod": re.compile(r"^pod_(say|speak)"),
}

# Web tabs: one SSE queue per tab; the tab that claimed "Web" most recently answers.
_streams: dict[str, "queue.Queue"] = {}
_claimed: dict[str, Optional[str]] = {"tab": None}
_streams_lock = threading.Lock()
# Screen layout requests waiting for a Mac's answer.
_screen_waits: dict[str, dict] = {}


# ── seams (tests replace these) ─────────────────────────────────────────────────
def _paired() -> list[dict]:
    from api import pairing
    return pairing.list_devices()


def _connected() -> set:
    from api import device_bridge
    return set(device_bridge.connected_device_ids())


def _send_frame(device_id: str, frame: dict) -> bool:
    from api import device_bridge
    return bool(device_bridge.send_frame(device_id, frame))


def _push(title: str, body: str, data: dict) -> None:
    try:
        from api.coding_routes import _push_device_alert
        _push_device_alert(title, body, data=data)
    except Exception:
        logger.debug("holo drop push failed", exc_info=True)


def _wake_mac(device_id: str) -> None:
    try:
        from api import mac_power
        mac_power.store().wake(device_id)
    except Exception:
        logger.debug("holo drop: could not wake %s", device_id, exc_info=True)


def _start_card(drop: dict, from_name: str) -> None:
    """Push-to-start the phones' "Drop waiting" Live Activity (Lock Screen notifications are
    off on his iPhone, so a banner alone would go unseen while it's locked)."""
    try:
        from api import live_routes
        what = (drop.get("name") or drop.get("title") or drop.get("url") or drop.get("text") or "A drop")[:48]
        live_routes.start_activity(
            "holo", {"title": what, "from": from_name[:32], "kind": drop.get("kind") or "file", "count": 1},
            attributes_type="HoloDropActivityAttributes", attributes={"dropID": drop["id"]},
            alert={"title": "Holo Drop", "body": f"{what} from {from_name}"}, stale_after=24 * 3600)
    except Exception:
        logger.debug("holo drop: waiting card failed", exc_info=True)


def _later(seconds: float, fn, *args) -> None:
    t = threading.Timer(seconds, fn, args)
    t.daemon = True
    t.start()


def _settings() -> dict:
    try:
        from jarvis_power import discovery
        return discovery.get("holo-drop").read_settings()
    except Exception:
        return {"max_mb": 500, "direct": True, "defaults": ""}


def _invoke(device_id: str, skill: str, args: dict) -> bool:
    try:
        from api import device_bridge
        out = device_bridge.invoke_skill(device_id, skill, args, timeout=10.0)
        return not (isinstance(out, dict) and out.get("error"))
    except Exception:
        return False


def _text_targets() -> list[dict]:
    """Glasses / Pod reachable through a text skill on a connected device."""
    try:
        from api import device_bridge
        out = []
        for device_id in device_bridge.connected_device_ids():
            for s in device_bridge.skills_for_device(device_id):
                name = str(s.get("name") or "")
                for kind, pattern in _TEXT_SKILLS.items():
                    if pattern.match(name) and not any(t["kind"] == kind for t in out):
                        out.append({"id": f"{kind}:{device_id}", "via": device_id, "skill": name, "kind": kind})
        return out
    except Exception:
        return []


# ── devices ────────────────────────────────────────────────────────────────────
def _kind(d: dict) -> Optional[str]:
    raw = str(d.get("kind") or "").lower()
    name = str(d.get("name") or "").lower()
    if raw == "desktop":
        return "mac"
    if raw.startswith("mobile"):
        return "ipad" if "ipad" in name or "ipad" in raw else "iphone"
    return None


def _defaults() -> dict:
    raw = _settings().get("defaults") or ""
    try:
        parsed = json.loads(raw) if isinstance(raw, str) and raw.strip() else (raw or {})
        return parsed if isinstance(parsed, dict) else {}
    except ValueError:
        return {}


_DEFAULT_ACTION = {"mac": "open", "web": "open", "iphone": "save", "ipad": "save", "glasses": "open", "pod": "open"}


def devices(caller: str) -> list[dict]:
    st = store()
    online = _connected()
    defaults = _defaults()
    bearings = st.bearings_for(caller) if caller else {}
    out = []
    for d in _paired():
        kind = _kind(d)
        if kind is None or d.get("id") == caller:
            continue
        b = bearings.get(d["id"])
        out.append({
            "id": d["id"], "name": d.get("name") or kind.title(), "kind": kind,
            "online": d["id"] in online,
            "accepts": list(KINDS), "aim": kind == "mac",
            "default_action": defaults.get(d["id"]) or _DEFAULT_ACTION[kind],
            "lan": st.lan_for(d["id"]) if _settings().get("direct", True) else None,
            "bearing": ({k: b[k] for k in ("deg", "confidence", "source", "at")} if b else None),
            "distance_m": b.get("distance_m") if b else None,
        })
    with _streams_lock:
        if _claimed["tab"] in _streams and not caller.startswith("web:"):
            out.append({"id": "web", "name": "Web", "kind": "web", "online": True, "accepts": list(KINDS),
                        "aim": False, "default_action": defaults.get("web") or "open", "lan": None,
                        "bearing": None, "distance_m": None})
    for t in _text_targets():
        out.append({"id": t["id"], "name": "Glasses" if t["kind"] == "glasses" else "Pod", "kind": t["kind"],
                    "online": True, "accepts": ["link", "text"], "aim": False,
                    "default_action": "open", "lan": None, "bearing": None, "distance_m": None})
    return out


def _target(target: str, caller: str) -> Optional[dict]:
    for d in devices(caller):
        if d["id"] == target:
            return d
    return None


# ── delivery ───────────────────────────────────────────────────────────────────
def public(d: dict) -> dict:
    out = {k: v for k, v in d.items() if k not in ("file",)}
    out["from_name"] = _name_of(d.get("sender") or "")
    return out


def deliver(drop: dict) -> dict:
    """Send a drop to its target now, or hold it (waking a Mac)."""
    st = store()
    target = drop["target"]
    if target == "web":
        with _streams_lock:
            q = _streams.get(_claimed["tab"] or "")
        if q is None:
            return st.set_state(drop["id"], "held")
        q.put(("drop", public(drop)))
        return st.set_state(drop["id"], "delivered")
    if ":" in target:                                         # glasses:<via> / pod:<via>
        for t in _text_targets():
            if t["id"] == target:
                text = drop.get("url") or drop.get("text") or ""
                ok = _invoke(t["via"], t["skill"], {"text": text, "title": drop.get("title") or "Holo Drop"})
                return st.set_state(drop["id"], "landed" if ok else "failed",
                                    outcome="shown" if ok else "failed",
                                    error=None if ok else "the device didn't take it")
        return st.set_state(drop["id"], "failed", error="that device isn't reachable")
    kind = next((_kind(d) for d in _paired() if d.get("id") == target), None)
    if target in _connected() and _send_frame(target, {"type": "holo_drop", "event": "drop", "drop": public(drop)}):
        out = st.set_state(drop["id"], "delivered")
        if kind in PHONES:
            _later(WAITING_AFTER_S, _check_waiting, drop["id"])
        return out
    if kind == "mac":
        _wake_mac(target)
    out = st.set_state(drop["id"], "held")
    if kind in PHONES and drop.get("state") != "held":
        _waiting(out)
    return out


PHONES = ("iphone", "ipad")
WAITING_AFTER_S = 8.0
_seen: set = set()          # drop ids their phone has picked up (record, content or pending)


def _name_of(device_id: str) -> str:
    if device_id == "jarvis":
        return "Jarvis"
    if device_id.startswith("web:"):
        return "Web"
    return next((d.get("name") for d in _paired() if d.get("id") == device_id), None) or "your device"


def _waiting(drop: dict) -> None:
    """A phone drop nobody picked up: the Lock Screen card + a banner (seen when unlocked)."""
    who = _name_of(drop.get("sender") or "")
    what = drop.get("name") or drop.get("title") or drop.get("url") or "Something"
    _start_card(drop, who)
    _push("Holo Drop", f"{who} dropped {what} — open Jarvis to get it",
          {"type": "holo_drop", "id": drop["id"], "url": f"jarviscopilot://holo-drop?drop={drop['id']}"})


def _check_waiting(drop_id: str) -> None:
    d = store().get(drop_id)
    if d is not None and d["state"] == "delivered" and drop_id not in _seen:
        _waiting(d)


def deliver_held() -> int:
    """Retry held drops whose device is back (the Power integration's sweeper calls this)."""
    online = _connected()
    sent = 0
    for d in store().held():
        if d["target"] in online or d["target"] == "web":
            if deliver(d)["state"] != "held":
                sent += 1
    return sent


def _tell_sender(drop: dict) -> None:
    sender = drop.get("sender") or ""
    if sender.startswith("web:"):
        with _streams_lock:
            q = _streams.get(sender[4:])
        if q is not None:
            q.put(("landed", public(drop)))
        return
    if sender in ("", "jarvis"):
        return
    if sender in _connected() and _send_frame(sender, {"type": "holo_drop", "event": "landed", "drop": public(drop)}):
        return
    target_name = next((d.get("name") for d in _paired() if d.get("id") == drop["target"]), drop["target"])
    what = drop.get("name") or drop.get("title") or drop.get("url") or "Your drop"
    _push("Holo Drop", f"{what} landed on {target_name} · {drop.get('outcome') or 'done'}",
          {"type": "holo_drop_landed", "id": drop["id"]})


# ── HTTP ───────────────────────────────────────────────────────────────────────
def _caller(req) -> str:
    if req.host_signed:
        return "jarvis"
    device = getattr(req, "device", None) or {}
    if device.get("id"):
        return str(device["id"])
    # A browser tab (signed in, not a paired device) names itself with its stream's tab id.
    headers = getattr(getattr(req, "handler", None), "headers", None) or {}
    tab = re.sub(r"[^0-9a-f]", "", str(headers.get("X-Holo-Tab") or "").lower())[:32]
    return f"web:{tab}" if tab else ""


def route(req) -> bool:
    sub = req.sub.strip("/")
    parts = sub.split("/") if sub else []
    body = req.body if isinstance(req.body, dict) else {}
    caller = _caller(req)
    st = store()
    m = req.method

    if parts == ["devices"] and m == "GET":
        return req.reply(200, {"devices": devices(caller)})
    if parts == ["drops"] and m == "POST":
        return _create(req, body, caller)
    if parts == ["drops", "upload"] and m == "POST":
        return _upload(req, caller)
    if len(parts) >= 2 and parts[0] == "drops":
        d = st.get(parts[1])
        if d is None:
            return req.reply(404, {"error": "no such drop"})
        if caller and caller == d["target"] and m == "GET":
            _seen.add(d["id"])
        if len(parts) == 2 and m == "GET":
            return req.reply(200, public(d))
        if parts[2:] == ["content"] and m == "GET":
            return _content(req, d)
        if parts[2:] == ["landed"] and m == "POST":
            outcome = str(body.get("outcome") or "")
            state = "failed" if outcome == "failed" else "landed"
            d = st.set_state(d["id"], state, outcome=outcome, error=body.get("error"))
            _tell_sender(d)
            return req.reply(200, {"ok": True, "drop": public(d)})
        if parts[2:] == ["again"] and m == "POST":
            again = st.create(d["kind"], sender=caller, target=str(body.get("target") or d["target"]),
                              action=d["action"], position=d.get("position"), name=d["name"], mime=d["mime"],
                              text=d.get("text") or "", url=d.get("url") or "", title=d.get("title") or "")
            src = st.content_path(d["id"])
            if src is not None:
                with open(src, "rb") as fh:
                    st.attach_file(again["id"], fh, src.stat().st_size, max_bytes=src.stat().st_size + 1)
            return req.reply(200, {"drop": public(deliver(st.get(again["id"])))})
    if parts == ["pending"] and m == "GET":
        drops = st.pending_for(caller)
        for d in drops:
            _seen.add(d["id"])
            if d["state"] == "held":
                st.set_state(d["id"], "delivered")
        return req.reply(200, {"drops": [public(d) for d in drops]})
    if parts == ["history"] and m == "GET":
        limit = int((req.query.get("limit") or ["50"])[0]) if hasattr(req, "query") else 50
        return req.reply(200, {"drops": st.history(min(200, max(1, limit)))})
    if parts == ["lan"]:
        if m == "POST":
            st.set_lan(caller, str(body.get("url") or ""), str(body.get("token") or ""),
                       float(body.get("expires") or time.time() + 900))
            return req.reply(200, {"ok": True})
        if m == "DELETE":
            st.clear_lan(caller)
            return req.reply(200, {"ok": True})
    if parts == ["bearings"] and m == "POST":
        st.put_bearings(caller, body.get("bearings") or [])
        return req.reply(200, {"ok": True})
    if len(parts) == 2 and parts[0] == "bearings" and m == "DELETE":
        st.clear_bearing(caller, parts[1])
        return req.reply(200, {"ok": True})
    if parts == ["moved"] and m == "POST":
        st.clear_bearings_to(caller)
        return req.reply(200, {"ok": True})
    if len(parts) == 3 and parts[0] == "devices" and parts[2] == "screen" and m == "GET":
        return _screen(req, parts[1])
    if len(parts) == 2 and parts[0] == "screen" and m == "POST":
        wait = _screen_waits.get(parts[1])
        if wait:
            wait["answer"] = body
            wait["event"].set()
        return req.reply(200, {"ok": True})
    if len(parts) == 2 and parts[0] == "beacon" and m == "POST":
        frame = {"type": "holo_drop", "event": "beacon", "mode": str(body.get("mode") or ""),
                 "nonce": str(body.get("nonce") or ""), "from": caller, "token": body.get("token")}
        return req.reply(200, {"ok": _send_frame(parts[1], frame)})
    if parts == ["screen-guess"] and m == "POST":
        return _guess(req)
    if parts == ["stream"] and m == "GET":
        return _stream(req)
    if parts == ["web-claim"] and m == "POST":
        with _streams_lock:
            _claimed["tab"] = str(body.get("tab") or "") or None
        return req.reply(200, {"ok": True})
    return req.reply(404, {"error": "not found"})


def _action(body_action, target: dict, kind: str) -> str:
    a = str(body_action or "")
    if a in ACTIONS:
        return a
    return target.get("default_action") or "open"


def _create(req, body: dict, caller: str) -> bool:
    kind = str(body.get("kind") or "")
    direct = bool(body.get("delivered_direct"))
    if kind not in ("link", "text") and not (direct and kind in ("image", "video", "file")):
        return req.reply(400, {"error": "kind must be link or text here (files use /drops/upload)"})
    target = _target(str(body.get("target") or ""), caller)
    if target is None:
        return req.reply(400, {"error": "that device isn't one of yours (or isn't reachable)"})
    if kind == "link" and not str(body.get("url") or "").strip():
        return req.reply(400, {"error": "url is required"})
    d = store().create(kind, sender=caller, target=target["id"], action=_action(body.get("action"), target, kind),
                       position=body.get("position"), text=str(body.get("text") or ""),
                       url=str(body.get("url") or ""), title=str(body.get("title") or ""),
                       name=str(body.get("name") or "")[:200], mime=str(body.get("mime") or "")[:100],
                       direct=direct)
    if direct:                         # the receiver already answered over the LAN
        outcome = str(body.get("outcome") or "") or None
        d = store().set_state(d["id"], "failed" if outcome == "failed" else "landed", outcome=outcome)
    else:
        d = deliver(d)
    return req.reply(200, {"drop": public(d)})


def _upload(req, caller: str) -> bool:
    q = getattr(req, "query", None) or {}
    if not q:
        from urllib.parse import parse_qs
        q = parse_qs(req.parsed.query)
    get = lambda k: (q.get(k) or [""])[0]
    kind = get("kind")
    if kind not in ("image", "video", "file"):
        return req.reply(400, {"error": "kind must be image, video or file"})
    target = _target(get("target"), caller)
    if target is None or target["kind"] in ("glasses", "pod"):
        return req.reply(400, {"error": "that device can't take files"})
    try:
        length = int(req.handler.headers.get("Content-Length") or 0)
    except (TypeError, ValueError):
        length = 0
    max_bytes = int(float(_settings().get("max_mb") or 500) * 1024 * 1024)
    if length <= 0:
        return req.reply(411, {"error": "Content-Length is required"})
    if length > max_bytes:
        return req.reply(413, {"error": f"That's over the {max_bytes // (1024 * 1024)} MB limit for drops through Jarvis"})
    pos = {"x": get("x"), "y": get("y")} if get("x") and get("y") else None
    st = store()
    d = st.create(kind, sender=caller, target=target["id"], action=_action(get("action"), target, kind),
                  position=pos, name=get("name") or "drop", mime=get("mime"))
    try:
        st.attach_file(d["id"], req.handler.rfile, length, max_bytes)
    except TooLarge as exc:
        st.set_state(d["id"], "failed", error=str(exc))
        return req.reply(413, {"error": str(exc)})
    except Exception as exc:
        st.set_state(d["id"], "failed", error=str(exc))
        return req.reply(400, {"error": f"the upload didn't finish: {exc}"})
    return req.reply(200, {"drop": public(deliver(st.get(d["id"])))})


def _content(req, d: dict) -> bool:
    path = store().content_path(d["id"])
    if path is None:
        return req.reply(410 if d.get("expired") else 404, {"error": "the file is gone (drops last 24 hours)"})
    h = req.handler
    if not hasattr(h, "send_response"):                     # tests
        return req.reply(200, {"ok": True, "size": path.stat().st_size})
    h.send_response(200)
    h.send_header("Content-Type", d.get("mime") or "application/octet-stream")
    h.send_header("Content-Length", str(path.stat().st_size))
    h.send_header("Content-Disposition", f'attachment; filename="{(d.get("name") or "drop").replace(chr(34), "")}"')
    h.end_headers()
    with open(path, "rb") as fh:
        while True:
            chunk = fh.read(1024 * 1024)
            if not chunk:
                break
            h.wfile.write(chunk)
    return True


def _screen(req, device_id: str) -> bool:
    request = secrets.token_hex(6)
    wait = {"event": threading.Event(), "answer": None}
    _screen_waits[request] = wait
    try:
        if not _send_frame(device_id, {"type": "holo_drop", "event": "screen_request", "request": request}):
            return req.reply(404, {"error": "that device isn't connected"})
        if not wait["event"].wait(3.0) or not isinstance(wait["answer"], dict):
            return req.reply(504, {"error": "the device didn't answer"})
        a = wait["answer"]
        return req.reply(200, {"width": a.get("width"), "height": a.get("height"), "windows": a.get("windows") or []})
    finally:
        _screen_waits.pop(request, None)


def _guess(req) -> bool:
    """Best-guess link for a screenshot: a visible URL, or domain + page title."""
    import os
    import tempfile
    try:
        length = int(req.handler.headers.get("Content-Length") or 0)
    except (TypeError, ValueError):
        length = 0
    if length <= 0 or length > 20 * 1024 * 1024:
        return req.reply(400, {"error": "send the screenshot as the body"})
    data = req.handler.rfile.read(length)
    fd, path = tempfile.mkstemp(suffix=".png")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
        guess = _vision_guess(path)
    finally:
        os.unlink(path)
    return req.reply(200, guess)


def _vision_guess(path: str) -> dict:
    prompt = ("This is an iPhone screenshot. If it shows a web page, reply with JSON only: "
              '{"url": "<the full URL if visible, else the most likely URL of this exact page>", '
              '"title": "<page title>", "confidence": <0-1>}. If it is not a web page reply {"confidence": 0}.')
    try:
        import asyncio
        from tools.vision_tools import vision_analyze_tool
        raw = asyncio.run(vision_analyze_tool(path, prompt))
        text = raw if isinstance(raw, str) else json.dumps(raw)
        m = re.search(r"\{.*\}", text, re.S)
        parsed = json.loads(m.group(0)) if m else {}
        if isinstance(parsed.get("analysis"), str):
            m2 = re.search(r"\{.*\}", parsed["analysis"], re.S)
            parsed = json.loads(m2.group(0)) if m2 else {}
    except Exception:
        logger.debug("holo drop guess failed", exc_info=True)
        return {"confidence": 0, "best_guess": True}
    conf = float(parsed.get("confidence") or 0)
    out = {"confidence": conf, "best_guess": True, "title": parsed.get("title")}
    if conf >= 0.6 and str(parsed.get("url") or "").startswith(("http://", "https://")):
        out["url"] = parsed["url"]
    return out


def _stream(req) -> bool:
    from api import sse
    tab = secrets.token_hex(6)
    q: "queue.Queue" = queue.Queue()
    with _streams_lock:
        _streams[tab] = q
        if _claimed["tab"] is None:
            _claimed["tab"] = tab
    try:
        sse.open_stream(req.handler)
        sse.send(req.handler, "hello", {"tab": tab})
        while True:
            try:
                event, data = q.get(timeout=20)
            except queue.Empty:
                sse.keepalive(req.handler)
                continue
            sse.send(req.handler, event, data)
    except Exception:
        pass
    finally:
        with _streams_lock:
            _streams.pop(tab, None)
            if _claimed["tab"] == tab:
                _claimed["tab"] = next(iter(_streams), None)
    return True
