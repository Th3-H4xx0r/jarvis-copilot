"""Paired devices over HTTP: the roster, pairing, a device's token/poll/result/energy/location
reports, Pod recordings, rename, sign-out and revoke."""
import logging
import time
from urllib.parse import parse_qs

from api.config import STATE_DIR
from api.helpers import bad, j

logger = logging.getLogger(__name__)

_ENERGY_FILE = "energy.jsonl"
_ENERGY_KEEP = 400
_ENERGY_FIELDS = ("received", "cpuSeconds", "foregroundSeconds", "backgroundSeconds",
                  "backgroundAudioSeconds", "backgroundLocationSeconds", "app_version",
                  # the app's own hourly reading (kind "probe"): CPU over wallSeconds
                  "kind", "wallSeconds", "background",
                  # MetricKit's day: what went over which radio
                  "wifiUpBytes", "wifiDownBytes", "cellularUpBytes", "cellularDownBytes")


_ENERGY_MAP_KEYS = 120


def _energy_map(raw, cast) -> dict:
    """A small {name: number} map from the phone, keys and size bounded."""
    if not isinstance(raw, dict):
        return {}
    out = {}
    for key, value in list(raw.items())[:_ENERGY_MAP_KEYS]:
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            out[str(key)[:80]] = cast(value)
    return out


def _energy_hour(raw) -> dict | None:
    """The phone ledger's hour (Settings → Battery usage): states, CPU, counts, battery at each end."""
    if not isinstance(raw, dict):
        return None
    hour = {k: float(raw[k]) for k in ("start", "end", "batteryStart", "batteryEnd")
            if isinstance(raw.get(k), (int, float)) and not isinstance(raw.get(k), bool)}
    hour["seconds"] = _energy_map(raw.get("seconds"), float)
    hour["cpu"] = _energy_map(raw.get("cpu"), float)
    hour["counts"] = _energy_map(raw.get("counts"), int)
    return hour


def _energy_hour_line(hour: dict) -> str:
    """One line for the journal: battery, screen vs pocket, network, keepalive, the busiest place."""
    secs, cpu, counts = hour.get("seconds", {}), hour.get("cpu", {}), hour.get("counts", {})
    parts = []
    if "batteryStart" in hour and "batteryEnd" in hour:
        delta = (hour["batteryEnd"] - hour["batteryStart"]) * 100
        parts.append(f"battery {delta:+.0f}%" + (" (charging)" if secs.get("charging", 0) >= 60 else ""))
    parts.append(f"screen {secs.get('foreground', 0) / 60:.0f} min / {cpu.get('foreground', 0):.0f} s CPU")
    bg = secs.get("background", 0)
    if bg:
        parts.append(f"pocket {bg / 60:.0f} min (kept alive {secs.get('bg.keepalive', 0) / 60:.0f}, "
                     f"cellular {secs.get('bg.cellular', 0) / 60:.0f}) / {cpu.get('background', 0):.0f} s CPU")
    places = sorted(((k[6:], v) for k, v in cpu.items() if k.startswith("where.")), key=lambda kv: -kv[1])
    if places:
        parts.append("top " + ", ".join(f"{k.replace('|', ' › ').rstrip(' › ')} {v:.0f} s" for k, v in places[:2]))
    frames = counts.get("bridge.in", 0) + counts.get("bridge.out", 0)
    requests = sum(v for k, v in counts.items() if k.startswith("net.") and not k.startswith("net.bg."))
    parts.append(f"link {frames} frames, {counts.get('bridge.drop', 0)} drops; {requests} requests")
    if counts.get("keepalive.restart"):
        parts.append(f"keepalive restarted {counts['keepalive.restart']}x")
    return "; ".join(parts)


def _append_energy_report(device_id: str, body: dict, state_dir=None) -> dict:
    """One MetricKit day from a phone, kept so a battery change can be checked without a cable."""
    import json as _json
    from pathlib import Path as _Path

    row = {"device_id": device_id, "at": time.time()}
    for key in _ENERGY_FIELDS:
        value = body.get(key)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            row[key] = float(value)
        elif isinstance(value, str):
            row[key] = value[:40]
    threads = body.get("threads")
    if isinstance(threads, dict):
        row["threads"] = {str(k)[:40]: float(v) for k, v in list(threads.items())[:8]
                          if isinstance(v, (int, float)) and not isinstance(v, bool)}
    hour = _energy_hour(body.get("hour"))
    if hour:
        row["hour"] = hour
    exits = _energy_map(body.get("backgroundExits"), int)
    if exits:
        row["backgroundExits"] = dict(list(exits.items())[:12])
    path = _Path(state_dir or STATE_DIR) / _ENERGY_FILE
    lines = path.read_text().splitlines()[-(_ENERGY_KEEP - 1):] if path.exists() else []
    lines.append(_json.dumps(row, sort_keys=True))
    path.write_text("\n".join(lines) + "\n")
    return row


def _device(device_id: str):
    from api.pairing import list_devices
    return next((d for d in list_devices() if d.get("id") == device_id), None)


def _sign_out(device: dict) -> int:
    """Drop every session token the device's pairing issued and its live bridge link.
    Returns how many tokens went."""
    from api.auth import _save_sessions, _sessions
    prefix = device.get("session_prefix") or ""
    removed = 0
    if prefix:   # an empty prefix would match every session, the browser's included
        for tok in list(_sessions):
            if tok.startswith(prefix):
                _sessions.pop(tok, None)
                removed += 1
        if removed:
            _save_sessions(_sessions)
    try:
        from api.device_bridge import disconnect_device
        disconnect_device(device["id"])
    except Exception:
        logger.debug("device %s: bridge not disconnected", device.get("id"), exc_info=True)
    return removed


def route(req):
    """Mounted at /api/devices (api/mounts.py)."""
    handler, parsed = req.handler, req.parsed
    if req.method == "GET":
        if parsed.path in ("/api/devices/pod/recordings", "/api/devices/pod/recordings/audio"):
            # The Jarvis Pod's saved voice turns (list / WAV), for the phone's pod page.
            from api.voice_recordings import handle_get as _recordings_get
            return _recordings_get(handler, parsed)
        if parsed.path == "/api/devices/pod/voice":
            # The chat and model this pod talks to (the phone's Pod page).
            from api.pod_voice import handle_get as _pod_voice_get
            return _pod_voice_get(handler, parsed)
        if parsed.path == "/api/devices/pod/image":
            # Web pictures re-encoded for the Jarvis Pod's screen (baseline JPEG, square).
            from api.pod_image import handle_pod_image
            return handle_pod_image(handler, parsed)
        if parsed.path == "/api/devices":
            # Authed callers (sidebar Devices tab) get the full list.
            from api.pairing import list_devices
            rows = list_devices()
            # Two flavours of "online":
            #   (1) Desktop clients holding a live WS bridge connection —
            #       authoritative.
            #   (2) Browser-paired devices — no bridge, but ``last_seen``
            #       is bumped every authed request by auth.check_auth.
            #       Within the freshness window we still call them online.
            try:
                from api.device_bridge import connected_device_ids, skills_for_device
                connected = set(connected_device_ids())
            except Exception:
                connected = set()
                skills_for_device = None
            _ONLINE_WINDOW_SECONDS = 60.0
            _now = time.time()
            # ?skills=0 leaves out each device's skill catalogue (the phone's own is ~90 KB): the
            # phone's dashboard, voice strip, pod list and desktop picker read names, kinds and
            # who's online, ~40 times an hour.
            with_skills = parse_qs(parsed.query).get("skills", ["1"])[0].strip().lower() not in ("0", "false", "no")
            out = []
            for d in rows:
                dd = dict(d)
                last_seen = float(d.get("last_seen", 0) or 0)
                recently_active = (_now - last_seen) <= _ONLINE_WINDOW_SECONDS
                dd["online"] = (d.get("id") in connected) or recently_active
                # bridge_connected = holds a live device-bridge WS. NOTE: mobile
                # clients hold one too (notifications / phone-control), so this alone
                # does NOT mean "desktop sync agent".
                dd["bridge_connected"] = d.get("id") in connected
                # invokable = a skill call will actually be delivered. invoke_skill()
                # falls back to a silent push for mobile clients, which cannot hold a WS
                # while suspended — so gating on bridge_connected alone makes a perfectly
                # reachable phone look unusable.
                try:
                    from api.device_bridge import _push_reachable
                    dd["invokable"] = dd["bridge_connected"] or _push_reachable(d)
                except Exception:
                    dd["invokable"] = dd["bridge_connected"]
                # sync_capable = can actually run Mutagen file sync (a desktop
                # jc-client). The Coding sync device picker filters on this so mobile
                # devices never appear as sync targets even though they're connected.
                try:
                    from api.coding_desktop import is_sync_capable_kind
                    dd["sync_capable"] = bool(dd["bridge_connected"]) and \
                        is_sync_capable_kind(d.get("kind"))
                except Exception:
                    dd["sync_capable"] = (str(d.get("kind") or "").lower() == "desktop")
                if not with_skills:
                    dd.pop("skills", None)
                elif skills_for_device is not None:
                    dd["skills"] = skills_for_device(d.get("id", "")) or []
                else:
                    dd["skills"] = []
                # The wearables the phone last reported (the Mac's menu reads these instead of
                # asking the phone every 45 s).
                try:
                    from api.device_bridge import wearables_for
                    held = wearables_for(d.get("id", ""))
                    if held is not None:
                        dd["wearables"], dd["wearables_at"] = held
                except Exception:
                    pass
                out.append(dd)
            return j(handler, {"devices": out})
        if parsed.path == "/api/devices/skills":
            from api.device_bridge import all_device_skills
            return j(handler, {"skills": all_device_skills()})
    elif req.method == "POST":
        body = req.body
        if parsed.path == "/api/devices/pod/recordings/delete":
            from api.voice_recordings import handle_delete as _recordings_delete
            return _recordings_delete(handler, body)
        if parsed.path == "/api/devices/pod/voice":
            from api.pod_voice import handle_post as _pod_voice_post
            return _pod_voice_post(handler, body)
        if parsed.path == "/api/devices/skills/invoke":
            from api.device_bridge import invoke_skill
            device_id = (body.get("device_id") or "").strip()
            skill = (body.get("skill") or "").strip()
            args = body.get("args") or {}
            timeout = body.get("timeout")
            try:
                timeout = float(timeout) if timeout is not None else 30.0
            except (TypeError, ValueError):
                timeout = 30.0
            if not skill:
                return bad(handler, "skill is required")
            from api.device_bridge import SERVER_ONLY_SKILLS
            if skill in SERVER_ONLY_SKILLS:
                return j(handler, {"ok": False, "error": f"'{skill}' is only run by the server itself"}, status=403)
            if not device_id:
                # Callers that only know the skill — an ESP32 script's jarvis.invoke —
                # get the device offering it. A 404 tells them it isn't a device skill,
                # so they can hand the request to the agent instead.
                from api.auth import parse_cookie
                from api.device_bridge import device_offering
                from api.pairing import find_device_by_session
                caller = find_device_by_session(parse_cookie(handler) or "") or {}
                device_id = device_offering(skill, caller.get("id")) or ""
                if not device_id:
                    return j(handler, {"ok": False, "error": f"no device offers skill '{skill}'"}, status=404)
            if not isinstance(args, dict):
                return bad(handler, "args must be an object")
            result = invoke_skill(device_id, skill, args, timeout=max(1.0, min(timeout, 120.0)))
            status = 200 if result.get("ok") else 502
            return j(handler, result, status=status)
        # ── Mobile client: register push token + device kind ──
        # POST /api/devices/mobile/token
        # body: {"push_kind":"apns","push_token":"...","platform":"ios","app_version":"..."}
        # Caller is the mobile app, authed via the paired session cookie. We
        # match the cookie to the device record and update its push fields so
        # the bridge can fall back to silent push when the WS isn't live.
        if parsed.path == "/api/devices/mobile/token":
            from api.auth import parse_cookie
            from api.pairing import find_device_by_session, update_device_fields
            cookie_val = parse_cookie(handler)
            device = find_device_by_session(cookie_val or "")
            if not device:
                return j(handler, {"error": "no matching device for session"}, status=401)
            push_kind = (body.get("push_kind") or "").strip().lower()[:8]
            push_token = (body.get("push_token") or "").strip()[:512]
            platform = (body.get("platform") or "").strip().lower()[:16]
            # A second native client (e.g. JarvisWearables) has its own bundle ID, which
            # is the APNs topic. Omitted -> the configured default is used, so existing
            # paired clients are unaffected.
            push_topic = (body.get("bundle_id") or "").strip()[:128]
            push_env = (body.get("push_env") or "").strip().lower()[:16]
            if push_env not in ("", "development", "production"):
                return bad(handler, "push_env must be 'development' or 'production'")
            app_version = (body.get("app_version") or "").strip()[:32]
            if push_kind not in ("", "apns"):
                return bad(handler, "push_kind must be 'apns'")
            if push_kind and not push_token:
                return bad(handler, "push_token required when push_kind is set")
            kind = device.get("kind") or "browser"
            if platform == "ios":
                kind = "mobile-ios"
            update_device_fields(
                device["id"],
                kind=kind,
                push_kind=push_kind,
                push_token=push_token,
                push_topic=push_topic,
                push_env=push_env,
                app_version=app_version,
            )
            return j(handler, {"ok": True, "device_id": device["id"]})
        # ── Mobile client: poll queued invocations ──
        # POST /api/devices/mobile/poll
        # The app calls this after waking on a silent push. We drain whatever
        # invokes the bridge has queued for this device and return them.
        if parsed.path == "/api/devices/mobile/poll":
            from api.auth import parse_cookie
            from api.pairing import find_device_by_session
            from api.device_bridge import take_mobile_queue
            cookie_val = parse_cookie(handler)
            device = find_device_by_session(cookie_val or "")
            if not device:
                return j(handler, {"error": "no matching device for session"}, status=401)
            # Default True: a missing flag (older client) is treated as a foreground
            # poll so nothing is silently withheld. Be liberal in what we accept as
            # "background" so a non-bool ("false"/0/null) can't sneak foreground-
            # required invokes to a background isolate.
            _fg = body.get("foreground", True)
            include_foreground = _fg not in (False, "false", "False", 0, "0", None)
            queue_items = take_mobile_queue(device["id"], include_foreground=include_foreground)
            return j(handler, {"invokes": queue_items, "ts": time.time()})
        # ── Mobile client: MetricKit's daily energy numbers ──
        # POST /api/devices/mobile/energy  {"cpuSeconds":…, "backgroundSeconds":…, …}
        if parsed.path == "/api/devices/mobile/energy":
            from api.auth import parse_cookie
            from api.pairing import find_device_by_session
            device = find_device_by_session(parse_cookie(handler) or "")
            if not device:
                return j(handler, {"error": "no matching device for session"}, status=401)
            row = _append_energy_report(device["id"], body if isinstance(body, dict) else {})
            cpu = row.get("cpuSeconds") or 0
            if row.get("kind") == "probe":
                hours = (row.get("wallSeconds") or 0) / 3600
                where = "background" if row.get("background") else "foreground"
                top = ", ".join(f"{k} {v:.0f}" for k, v in sorted((row.get("threads") or {}).items(),
                                                                  key=lambda kv: -kv[1])[:5])
                print(f"[energy] {device.get('name') or device['id']}: {cpu:.0f} s CPU in {hours:.2f} h "
                      f"({cpu / hours if hours else 0:.0f} s/h, {where} now){' — ' + top if top else ''}", flush=True)
                if row.get("hour"):
                    print(f"[energy] {device.get('name') or device['id']} hour: {_energy_hour_line(row['hour'])}",
                          flush=True)
            else:
                bg_h = (row.get("backgroundSeconds") or 0) / 3600
                print(f"[energy] {device.get('name') or device['id']}: MetricKit day — {cpu:.0f} s CPU, "
                      f"{bg_h:.1f} h in the background ({cpu / bg_h if bg_h else 0:.0f} s/h)", flush=True)
            return j(handler, {"ok": True})
        # ── Mobile client: post a skill result ──
        # POST /api/devices/mobile/result
        # body: {"call_id":"...","result": <any>}   OR  {"call_id":"...","error":"..."}
        if parsed.path == "/api/devices/mobile/result":
            from api.auth import parse_cookie
            from api.pairing import find_device_by_session
            from api.device_bridge import resolve_mobile_result
            cookie_val = parse_cookie(handler)
            device = find_device_by_session(cookie_val or "")
            if not device:
                return j(handler, {"error": "no matching device for session"}, status=401)
            call_id = (body.get("call_id") or "").strip()
            if not call_id:
                return bad(handler, "call_id required")
            err = body.get("error")
            if err is not None and not isinstance(err, str):
                err = str(err)
            woke = resolve_mobile_result(
                call_id,
                result=body.get("result"),
                error=err,
            )
            return j(handler, {"ok": True, "delivered": woke})
        # ── Mobile client: report a location fix ──
        # POST /api/devices/mobile/location
        # body: {"lat": .., "lng": .., "accuracy"?: .., "ts"?: .., "address"?: ..}
        # The phone pushes periodic fixes here (it can't be pulled reliably when
        # backgrounded). We reverse-geocode + append to the device's history.
        if parsed.path == "/api/devices/mobile/location":
            from api.auth import parse_cookie
            from api.pairing import find_device_by_session
            from api.location_history import record_location
            cookie_val = parse_cookie(handler)
            device = find_device_by_session(cookie_val or "")
            if not device:
                return j(handler, {"error": "no matching device for session"}, status=401)
            try:
                lat = float(body.get("lat"))
                lng = float(body.get("lng"))
            except (TypeError, ValueError):
                return bad(handler, "lat and lng are required numbers")
            if not (-90 <= lat <= 90 and -180 <= lng <= 180):
                return bad(handler, "lat/lng out of range")
            def _num(v):
                try:
                    return float(v) if v is not None else None
                except (TypeError, ValueError):
                    return None
            addr = body.get("address")
            if addr is not None and not isinstance(addr, str):
                addr = None
            entry = record_location(
                device["id"], lat, lng,
                accuracy=_num(body.get("accuracy")),
                ts=_num(body.get("ts")),
                address=addr,
            )
            try:
                from plugins.memory.jarvis_memory import brief as _brief
                _brief.mark_dirty()  # "where he is" in the now brief
            except Exception:
                pass
            return j(handler, {"ok": True, "stored": entry})
        # ── Mobile client: calendar + reminders + time zone for the now brief ──
        # POST /api/devices/mobile/context
        if parsed.path == "/api/devices/mobile/context":
            from api.memory_map import handle_context_post
            return handle_context_post(handler, body)
        # ── JarvisCopilot pairing — issue a new code from inside the UI ──
        # Authed callers only (CSRF + session). Mirrors `jarviscopilot pair`
        # except it returns the code as JSON instead of rendering a TUI.
        if parsed.path == "/api/devices/pair/start":
            from api.pairing import create_pairing_code
            ttl = int(body.get("ttl") or 600)
            label = (body.get("label") or "").strip() or None
            info = create_pairing_code(label=label, ttl=ttl)
            # If behind a Cloudflare tunnel, surface the service token here (this
            # endpoint is authed — the browser is already past Access) so the QR /
            # deep-link can carry it. A tunnel-first device then sends the CF
            # headers on its pair/claim request, breaking the chicken-and-egg where
            # the token would otherwise only arrive *in* the claim response.
            try:
                from edge import get_manager
                cf = get_manager().cf_service_token_for_pairing()
                if cf.get("client_id") and cf.get("client_secret"):
                    info = dict(info)
                    info["cf_access"] = {
                        "client_id": cf["client_id"],
                        "client_secret": cf["client_secret"],
                    }
            except Exception:
                logger.debug("CF service token unavailable for pair/start", exc_info=True)
            return j(handler, info)
        # POST /api/devices/notify — a visible banner on every registered phone.
        # Used by paired devices (the JarvisWearables app, ESP32 boards) and by the
        # `notify_phone` tool so an automation can reach the user even when the
        # app is closed. Body: {title, body}, optionally {channel, app}: a device
        # channel ("glasses") routes the card to that wearable, labelled with `app`
        # (the Mac's iMessage relay sends channel=glasses, app=Messages).
        if parsed.path == "/api/devices/notify":
            title = (body.get("title") or "").strip()[:80]
            text = (body.get("body") or "").strip()[:400]
            if not title and not text:
                return bad(handler, "title or body is required")
            channel = (body.get("channel") or "").strip()[:32]
            if channel:
                from api.coding_routes import _send_coding_device_notify
                app = (body.get("app") or "").strip()[:40]
                return j(handler, {"ok": _send_coding_device_notify(channel, title or "Jarvis", text, app=app)})
            try:
                from api.coding_routes import _push_device_alert
                sent = _push_device_alert(title or "Jarvis", text)
            except Exception as e:
                logger.warning("devices/notify push failed: %s", e)
                sent = 0
            return j(handler, {"ok": sent > 0, "sent": sent})
        if parsed.path == "/api/devices/pair/cancel":
            from api.pairing import cancel_pairing_code
            code = (body.get("code") or "").strip().upper()
            return j(handler, {"removed": cancel_pairing_code(code)})
        if parsed.path.endswith("/rename"):
            rest = parsed.path[len("/api/devices/"):-len("/rename")].strip("/")
            name = " ".join(str(body.get("name") or "").split())[:64]
            if not rest or not name:
                return bad(handler, "device id and name are required")
            if _device(rest) is None:
                return j(handler, {"error": "device not found"}, status=404)
            from api.pairing import update_device_fields
            update_device_fields(rest, name=name)
            try:
                # A live bridge connection names the device's tools; follow the rename now.
                from api import device_bridge
                conn = device_bridge._REG.get(rest)
                if conn is not None:
                    conn.name = name
                    device_bridge._notify_registry_change()
            except Exception:
                logger.debug("device %s: live bridge not renamed", rest, exc_info=True)
            return j(handler, {"ok": True, "name": name})
        # POST /api/devices/<id>/logout — sign the device out but keep its record, so it
        # can re-auth (e.g. with a fresh pairing code) without losing its history.
        if parsed.path.endswith("/logout"):
            device = _device(parsed.path[len("/api/devices/"):-len("/logout")].strip("/"))
            if device is None:
                return j(handler, {"error": "device not found"}, status=404)
            return j(handler, {"ok": True, "sessions_invalidated": _sign_out(device)})
    elif req.method == "DELETE":
        body = req.body
        # DELETE /api/devices/<id> — sign it out and forget the pairing.
        rest = parsed.path[len("/api/devices/"):].strip("/")
        if rest and "/" not in rest:
            device = _device(rest)
            if device is None:
                return j(handler, {"error": "device not found"}, status=404)
            removed = _sign_out(device)
            from api.pairing import revoke_device
            revoke_device(rest)
            return j(handler, {"ok": True, "sessions_revoked": removed})
    return False
