"""HTTP API for the Door Alarm page and the door_* tools: ``/api/door/*``.

``handle_door_request(method, path, body, host_signed=False, service=None, caller=None)`` →
``(status, payload)``. Who may do what:
- ``host_signed`` = Jarvis's tools over the host-signed loopback. Jarvis may arm a DISARMED alarm
  (bypassing only doors that are actually open), change hub settings while disarmed, rename doors,
  and ASK for a disarm/silence approval. Never disarm, answer an approval, re-arm or switch modes,
  touch the alarm's settings or a door's on-open prompt, or change setup — an injected or
  overheard request (the Pod is in the house) must not be able to weaken the alarm.
- ``caller == "board"`` = a paired ESP32 or the Pod (they advertise esp32_/pod_ skills): read only.
- anyone else with a paired session = Pranav's phone or browser.
The local key never leaves the server. Routes::

    GET  /state | /settings | /approvals | /setup | /setup/devices | /proxies | /network | /firmware
    GET  /history?limit=&contact=
    POST /arm {mode, bypass?, source?}            409 {open_contacts} when a watched door is open
    POST /disarm | /silence {nonce, ts, signature}           (phone, Face ID, jarvis-home domain)
    POST /approvals {action}                                  (Jarvis only)
    POST /approvals/<id>/approve {ts, signature} | /approvals/<id>/deny     (phone only)
    POST /set {code, value}                       504 when the hub doesn't confirm
    POST /settings {alarm?, contacts?, siren?}    POST /rename {name}
    POST /setup/credentials {access_id, secret, region} | /setup/pick {dev_id} | /setup/proxy {board_id}
    POST /firmware/upgrade {firmware_id}                      (phone only)
"""
from __future__ import annotations

import logging
from urllib.parse import parse_qs

DOOR_PATH_PREFIX = "/api/door"
log = logging.getLogger(__name__)

_PHONE_ONLY = ("/disarm", "/silence", "/setup/credentials", "/setup/pick", "/setup/proxy", "/firmware/upgrade")


def caller_kind(device: dict, skills: list[str]) -> str | None:
    """"board" for a session that IS an ESP32 or the Pod: it advertises only esp32_*/pod_* skills.
    A phone is never one, even though it relays its boards' esp32_* skills over Bluetooth."""
    if str(device.get("kind") or "").startswith("mobile"):
        return None
    names = [n for n in skills if n]
    if names and all(n.startswith(("esp32_", "pod_")) for n in names):
        return "board"
    return None


def door_caller(handler) -> str | None:
    """caller_kind() for the request's paired session."""
    try:
        from api import device_bridge
        from api.auth import parse_cookie
        from api.pairing import find_device_by_session
        device = find_device_by_session(parse_cookie(handler) or "") or {}
        if device.get("id"):
            skills = [str(s.get("name") or "") for s in device_bridge.skills_for_device(device["id"])]
            return caller_kind(device, skills)
    except Exception:
        log.debug("door caller lookup failed", exc_info=True)
    return None


def _proxies() -> list[dict]:
    """Paired, connected boards that can be the door proxy (they advertise esp32_door_configure)."""
    try:
        from api import device_bridge
        from api.pairing import list_devices
        names = {d.get("id"): d.get("name") for d in list_devices()}
        out = []
        for device_id in device_bridge.connected_device_ids():
            skills = {s.get("name") for s in device_bridge.skills_for_device(device_id)}
            if "esp32_door_configure" in skills:
                out.append({"id": device_id, "name": names.get(device_id) or device_id})
        return out
    except Exception:
        log.debug("door proxies lookup failed", exc_info=True)
        return []


def handle_door_request(method, path, body, host_signed=False, service=None, caller=None):
    from plugins.door_alarm.alarm import ArmRefused
    from plugins.door_alarm.service import CommandFailed, DoorService, NotSetUp
    from plugins.door_alarm.tuya_cloud import TuyaError, regions
    from plugins.toyota.approver import ApprovalError

    svc = service or DoorService.instance()
    body = body if isinstance(body, dict) else {}
    raw_path, _, query = (path or "").partition("?")
    p = raw_path.rstrip("/") or "/"
    params = {k: v[-1] for k, v in parse_qs(query).items()}
    parts = p.strip("/").split("/")

    def forbid(msg):
        return 403, {"ok": False, "error": msg, "code": "forbidden"}

    try:
        if method == "GET":
            if p == "/state":
                return 200, svc.state()
            if p == "/settings":
                return 200, svc.settings()
            if p == "/approvals":
                return 200, {"approvals": svc.approvals.pending()}
            if p == "/history":
                limit = int(params.get("limit") or 100)
                return 200, {"events": svc.history(limit, params.get("contact") or None)}
            if p == "/setup":
                return 200, {**svc.setup_status(), "regions": regions()}
            if p == "/setup/devices":
                return 200, {"devices": svc.list_cloud_devices()}
            if p == "/proxies":
                return 200, {"proxies": _proxies(), "current": svc.hub.cfg.get("proxy")}
            if p == "/network":
                return 200, svc.network()
            if p == "/firmware":
                return 200, svc.firmware()
            return 404, {"ok": False, "error": "unknown door endpoint"}
        if method != "POST":
            return 405, {"ok": False, "error": f"method {method} not allowed"}

        if caller == "board":
            return forbid("Devices can read the door alarm, not change it.")
        if host_signed and p in _PHONE_ONLY:
            return forbid("Only Pranav's iPhone can do that.")
        armed = svc.alarm.state != "disarmed"
        if p == "/arm":
            bypass = [str(b) for b in body.get("bypass") or []]
            if host_signed:
                if armed:
                    return forbid("The alarm is already on. Only the iPhone can change how it's armed.")
                open_ids = {c["id"] for c in svc.hub.open_contacts()}
                if any(b not in open_ids for b in bypass):
                    return 400, {"ok": False, "error": "Jarvis can only bypass a door that is open right now."}
            source = "Jarvis" if host_signed else str(body.get("source") or "app")[:40]
            return 200, svc.arm(str(body.get("mode") or ""), bypass, source=source)
        if p == "/disarm":
            return 200, svc.disarm(body)
        if p == "/silence":
            return 200, svc.silence(body)
        if p == "/approvals":
            if not host_signed:
                return forbid("Only Jarvis asks for door alarm approvals.")
            return 200, {"ok": True, "approval": svc.create_approval(str(body.get("action") or ""))}
        if len(parts) == 3 and parts[0] == "approvals" and parts[2] in ("approve", "deny"):
            if host_signed:
                return forbid("Approvals are answered on the iPhone.")
            if parts[2] == "deny":
                svc.deny_approval(parts[1])
                return 200, {"ok": True}
            return 200, svc.answer_approval(parts[1], body)
        if p == "/set":
            if host_signed and armed:
                return forbid("The alarm is on: change the hub's settings on the iPhone.")
            return 200, svc.set_value(str(body.get("code") or ""), body.get("value"))
        if p == "/settings":
            if host_signed:
                contacts = body.get("contacts")
                names_only = (set(body) <= {"contacts"} and isinstance(contacts, dict)
                              and all(isinstance(v, dict) and set(v) <= {"name"} for v in contacts.values()))
                if not names_only:
                    return forbid("Jarvis can rename doors; the alarm's settings change on the iPhone.")
            return 200, svc.update_settings(body)
        if p == "/rename":
            return 200, svc.rename(str(body.get("name") or ""))
        if p == "/setup/credentials":
            return 200, svc.save_credentials(body.get("access_id"), body.get("secret"), body.get("region") or "us")
        if p == "/setup/pick":
            return 200, svc.pick(str(body.get("dev_id") or ""))
        if p == "/setup/proxy":
            return 200, svc.set_proxy(body.get("board_id"), allowed={b["id"] for b in _proxies()})
        if p == "/firmware/upgrade":
            return 200, svc.upgrade(body.get("firmware_id"))
        return 404, {"ok": False, "error": "unknown door endpoint"}
    except ArmRefused as exc:
        return 409, {"ok": False, "error": str(exc),
                     "open_contacts": [{"id": c["id"], "name": c.get("name")} for c in exc.open_contacts]}
    except NotSetUp as exc:
        return 409, {"ok": False, "error": str(exc), "code": "not_set_up"}
    except ApprovalError as exc:
        status = {"gone": 410, "bad_request": 400, "bad_key": 400, "rate_limited": 429}.get(exc.code, 403)
        return status, {"ok": False, "error": str(exc), "code": exc.code}
    except CommandFailed as exc:
        return 504, {"ok": False, "error": str(exc)}
    except TuyaError as exc:
        status = {"auth": 400, "refused": 400}.get(exc.kind, 503)
        return status, {"ok": False, "error": str(exc), "code": f"tuya_{exc.kind}"}
    except ValueError as exc:
        return 400, {"ok": False, "error": str(exc)}
