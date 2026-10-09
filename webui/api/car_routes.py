"""HTTP API for the Car page's Toyota parts: ``/api/car/*`` (normal session-cookie auth, like /api).

``handle_car_request(method, path, body, ha=None)`` returns ``(status, payload)`` for
``j(handler, payload, status=status)``. Everything goes to Pranav's Home Assistant, which runs the
Toyota integration; nothing here talks to Toyota. The sign-in body (email, password, code) is
handed to Home Assistant's sign-in flow and never stored or logged. GET/POST only::

    GET  /state                          -> {account, car|null, error?}
    POST /refresh                        -> {ok}                       (wakes the car)
    POST /command {command, confirmed?} -> {ok, command, result} | {ok:false, needs_confirmation, ask}
    POST /climate {custom?, temp?, defrost_front?, defrost_rear?} -> {ok, climate}
    POST /signin {email, password}       -> {ok, step: code|done, flow_id?}
    POST /signin/code {flow_id, code}    -> {ok, step: done}
    POST /signout                        -> {ok}

Errors are ``{ok: false, error}``: 400 a request or sign-in Toyota refused, 409 not signed in,
502 Home Assistant or Toyota failed, 503 Home Assistant unreachable.
"""
from __future__ import annotations

CAR_PATH_PREFIX = "/api/car"


def handle_car_request(method, path, body, ha=None):
    from plugins.toyota import service
    from plugins.toyota.account import SignInError, ToyotaAccount
    from plugins.toyota.car import CarError, NotSignedIn, ToyotaCar
    from plugins.toyota.commands import CONFIRM, is_confirmed
    from plugins.toyota.ha import HAClient, HAError, HAUnreachable

    ha = ha if ha is not None else HAClient()
    body = body if isinstance(body, dict) else {}
    p = path.split("?", 1)[0].rstrip("/") or "/"

    async def signed_in_car():
        await service.require_signed_in(ha)
        return ToyotaCar(ha)

    async def dispatch():
        if method == "GET":
            if p == "/state":
                return 200, await service.car_state(ha)
            return 404, {"ok": False, "error": "unknown car endpoint"}
        if method != "POST":
            return 405, {"ok": False, "error": f"method {method} not allowed"}
        if p == "/refresh":
            return 200, await (await signed_in_car()).refresh()
        if p == "/command":
            name = str(body.get("command") or "")
            if name in CONFIRM and not is_confirmed(body.get("confirmed")):
                return 200, await ToyotaCar(ha).command(name)
            return 200, await (await signed_in_car()).command(name, body.get("confirmed"))
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
    except NotSignedIn as exc:
        return 409, {"ok": False, "error": str(exc)}
    except (SignInError, CarError) as exc:
        return 400, {"ok": False, "error": str(exc)}
    except HAUnreachable as exc:
        return 503, {"ok": False, "error": str(exc)}
    except HAError as exc:
        return 502, {"ok": False, "error": str(exc)}
