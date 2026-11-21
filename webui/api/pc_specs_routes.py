"""The PC's specs (/api/pc-specs, never gated: the Specs screen is a PC feature, not lighting)."""
from __future__ import annotations


def store():
    from api.pc_lighting_store import store as _store
    return _store()


def _invoke(did: str, skill: str, args: dict, timeout: float = 90.0) -> dict:
    from api import device_bridge
    return device_bridge.invoke_skill(did, skill, args, timeout=timeout)


def route(req) -> bool:
    from api.pc_lighting_routes import pc_device_id
    parts = [p for p in req.sub.strip("/").split("/") if p]
    body = req.body if isinstance(req.body, dict) else {}
    q = req.query.get("device_id", [""])[0] if req.method == "GET" else ""
    did = pc_device_id(str(body.get("device_id") or q or ""))
    if req.method == "GET" and parts == []:
        return req.reply(200, {"device_id": did or None, "specs": store().specs(did) if did else None})
    if req.method == "POST" and parts == ["refresh"]:
        r = _invoke(did, "pc_specs_read", {}, timeout=90.0)
        res = r.get("result") if r.get("ok") else None
        if not isinstance(res, dict) or not res.get("ok"):
            err = (res or {}).get("error") if isinstance(res, dict) else r.get("error")
            return req.reply(502, {"ok": False, "error": err or "The PC didn't answer"})
        store().set_specs(did, res["specs"])
        return req.reply(200, {"ok": True, "device_id": did, "specs": res["specs"]})
    return False
