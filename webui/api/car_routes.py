"""HTTP API for the Car page's Toyota parts: ``/api/car/*`` (normal session-cookie auth, like /api).

``handle_car_request(method, path, body, ha=None)`` returns ``(status, payload)`` for
``j(handler, payload, status=status)``. Everything goes to Pranav's Home Assistant, which runs the
Toyota integration; nothing here talks to Toyota. The sign-in body (email, password, code) is
handed to Home Assistant's sign-in flow and never stored or logged. GET/POST only::

    GET  /state                          -> {account, car|null, error?}
    POST /refresh                        -> {ok}                       (wakes the car)
    POST /command {command, nonce?, ts?, signature?} -> {ok, command, result}
                                         (every command but stop: a Face ID signature — approver.py)
    GET  /approver                       -> {registered, public_key?}
    POST /approver {public_key, ts?, signature?}   -> {ok}   (a new key needs the old key's signature)
    GET  /approvals                      -> {approvals: [...]}           (Jarvis's, waiting for Face ID)
    POST /approvals {command}            -> {ok, approval}               (the toyota_command tool)
    POST /approvals/<id>/approve {ts, signature} -> {ok, command, result}
    POST /approvals/<id>/deny            -> {ok}
    POST /climate {custom?, temp?, defrost_front?, defrost_rear?} -> {ok, climate}
    POST /signin {email, password}       -> {ok, step: code|done, flow_id?}
    POST /signin/code {flow_id, code}    -> {ok, step: done}
    POST /signout                        -> {ok}

Errors are ``{ok: false, error}``: 400 a request or sign-in Toyota refused, 403 Face ID approval
missing or refused (with ``code``), 409 not signed in,
502 Home Assistant or Toyota failed, 503 Home Assistant unreachable, 504 a command Toyota hasn't
confirmed in time (the car may still carry it out — the phone shows "check the car", no retry).
"""
from __future__ import annotations

CAR_PATH_PREFIX = "/api/car"


def _notify_phone(item):
    """Tell his iPhone an approval is waiting: a visible push (tap → the app opens on it), and, if
    the app is connected, its car skill shows the approval sheet straight away. Best effort, off the
    request thread."""
    import logging
    import threading

    log = logging.getLogger(__name__)

    def send():
        try:
            from api.coding_routes import _push_device_alert
            _push_device_alert(f"{item['title']}?", "Jarvis asked. Approve it with Face ID.")
        except Exception as exc:
            log.warning("car approval push failed: %s", exc)
        try:
            from api import device_bridge
            device = device_bridge.device_offering("car_show_approvals")
            if device and device in device_bridge.connected_device_ids():
                device_bridge.invoke_skill(device, "car_show_approvals", {}, timeout=8.0)
        except Exception as exc:
            log.debug("car approval sheet nudge failed: %s", exc)

    threading.Thread(target=send, name="car-approval-notify", daemon=True).start()


def handle_car_request(method, path, body, ha=None, approver=None, approvals=None, notify=None,
                       host_signed=False):
    """``host_signed``: the request came over the host-signed loopback — the agent's side. It may ask
    for an approval, never register a key or answer one."""
    from plugins.toyota import approver as approval
    from plugins.toyota import service
    from plugins.toyota.account import SignInError, ToyotaAccount
    from plugins.toyota.car import CarError, CommandPending, FaceIdRequired, NotSignedIn, ToyotaCar
    from plugins.toyota.commands import SERVICES, needs_face_id
    from plugins.toyota.ha import HAClient, HAError, HAUnreachable

    ha = ha if ha is not None else HAClient()
    keys = approver if approver is not None else approval.approver()
    waiting = approvals if approvals is not None else approval.approvals()
    notify = notify if notify is not None else _notify_phone
    body = body if isinstance(body, dict) else {}
    p = path.split("?", 1)[0].rstrip("/") or "/"
    parts = p.strip("/").split("/")

    async def signed_in_car():
        await service.require_signed_in(ha)
        return ToyotaCar(ha)

    async def run_command(name, proof_nonce=None, proof=None):
        if name not in SERVICES:
            raise CarError(f"Unknown car command '{name}'.")
        approved = False
        if needs_face_id(name):
            keys.verify(name, proof_nonce, proof.get("ts"), proof.get("signature"))
            approved = True
        car = await signed_in_car()
        return await car.command(name, approved=approved)

    async def dispatch():
        if method == "GET":
            if p == "/state":
                return 200, await service.car_state(ha)
            if p == "/approver":
                key = keys.registered()
                return 200, {"registered": key is not None, "public_key": key}
            if p == "/approvals":
                return 200, {"approvals": waiting.pending()}
            return 404, {"ok": False, "error": "unknown car endpoint"}
        if method != "POST":
            return 405, {"ok": False, "error": f"method {method} not allowed"}
        if p == "/refresh":
            return 200, await (await signed_in_car()).refresh()
        if p == "/command":
            name = str(body.get("command") or "")
            return 200, await run_command(name, body.get("nonce"), body)
        if p == "/approver":
            keys.register(body.get("public_key"), body.get("ts"), body.get("signature"), from_host=host_signed)
            return 200, {"ok": True}
        if p == "/approvals":
            if not host_signed:
                return 403, {"ok": False, "error": "Only Jarvis asks for car approvals.", "code": "forbidden"}
            name = str(body.get("command") or "")
            if not needs_face_id(name):
                return 400, {"ok": False, "error": f"'{name}' doesn't need an approval."}
            await service.require_signed_in(ha)
            item = waiting.create(name)
            notify(item)
            return 200, {"ok": True, "approval": item}
        if len(parts) == 3 and parts[0] == "approvals" and parts[2] in ("approve", "deny"):
            if host_signed:
                return 403, {"ok": False, "error": "Approvals are answered on the iPhone.", "code": "forbidden"}
            approval_id = parts[1]
            if parts[2] == "deny":
                waiting.take(approval_id)
                return 200, {"ok": True}
            item = waiting.peek(approval_id)
            keys.verify(item["command"], approval_id, body.get("ts"), body.get("signature"))
            waiting.take(approval_id)
            car = await signed_in_car()
            return 200, await car.command(item["command"], approved=True)
        if p == "/climate":
            car = await signed_in_car()
            return 200, await car.set_climate(custom=body.get("custom"), temp=body.get("temp"),
                                              defrost_front=body.get("defrost_front"),
                                              defrost_rear=body.get("defrost_rear"))
        if p == "/signin":
            step = await ToyotaAccount(ha).sign_in(body.get("email"), body.get("password"))
            return 200, {"ok": True, **step}
        if p == "/signin/code":
            step = await ToyotaAccount(ha).submit_code(body.get("flow_id"), body.get("code"))
            return 200, {"ok": True, **step}
        if p == "/signout":
            return 200, await ToyotaAccount(ha).sign_out()
        return 404, {"ok": False, "error": "unknown car endpoint"}

    try:
        return service.run(dispatch())
    except approval.ApprovalError as exc:
        status = {"gone": 410, "bad_request": 400, "bad_key": 400, "rate_limited": 429}.get(exc.code, 403)
        return status, {"ok": False, "error": str(exc), "code": exc.code}
    except FaceIdRequired as exc:
        return 403, {"ok": False, "error": str(exc), "code": "approval_required"}
    except NotSignedIn as exc:
        return 409, {"ok": False, "error": str(exc)}
    except (SignInError, CarError) as exc:
        return 400, {"ok": False, "error": str(exc)}
    except CommandPending as exc:
        return 504, {"ok": False, "error": str(exc)}
    except HAUnreachable as exc:
        return 503, {"ok": False, "error": str(exc)}
    except HAError as exc:
        return 502, {"ok": False, "error": str(exc)}
