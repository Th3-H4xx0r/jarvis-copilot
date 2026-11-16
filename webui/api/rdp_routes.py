"""Remote Desktop over HTTP, mounted at /api/rdp (api/mounts.py); 409 while the remote-desktop
Power integration is off (jarvis_power.gate, before this runs).

    POST   /api/rdp/status            the PC's RdpStatus (its Jarvis app, every 60 s and on change)
    POST   /api/rdp/sessions          {device_id, client: "ios"|"web", confirm?, enc_pub?}
    GET    /api/rdp/sessions/<id>     state; the iPhone's ciphertext once approved, never plaintext
    DELETE /api/rdp/sessions/<id>     Disconnect
    GET    /api/rdp/audit             who connected from which client, when (no secrets)

The iPhone relay (/api/rdp/relay/<id>) and the web gateway (/api/rdp/guac/<id>) are WebSockets,
dispatched from server.py (api.rdp_relay, api.rdp_guac).
"""
from __future__ import annotations

from api import rdp_sessions


def _caller_device(req, body: dict) -> str:
    return str(body.get("device_id") or (getattr(req, "device", None) or {}).get("id") or "")


def route(req) -> bool:
    parts = [p for p in req.sub.strip("/").split("/") if p]
    body = req.body if isinstance(req.body, dict) else {}
    s = rdp_sessions.store()
    if parts == ["status"] and req.method == "POST":
        did = _caller_device(req, body)
        if not did:
            return req.reply(400, {"ok": False, "error": "device_id required"})
        s.put_status(did, body)
        return req.reply(200, {"ok": True, "settings": s.settings()})
    if parts == ["status"] and req.method == "GET":   # read-only: readiness for the UIs and Jarvis
        return req.reply(200, {"devices": s.statuses()})
    if parts == ["sessions"] and req.method == "POST":
        did = str(body.get("device_id") or "")
        if not did:
            return req.reply(400, {"error": "device_id required", "code": "client"})
        out = s.create(did, str(body.get("client") or ""), bool(body.get("confirm")),
                       str(body["enc_pub"]) if body.get("enc_pub") else None)
        return req.reply(400 if out.get("code") == "client" else 200, out)
    if parts == ["sessions"] and req.method == "GET":
        return req.reply(200, {"sessions": s.live()})
    if len(parts) == 2 and parts[0] == "sessions":
        if req.method == "GET":
            pub = s.public(parts[1])
            return req.reply(200, {"session": pub}) if pub else req.reply(404, {"error": "no such session"})
        if req.method == "DELETE":
            s.end(parts[1], "disconnected")
            return req.reply(200, {"ok": True})
    if parts == ["audit"] and req.method == "GET":
        return req.reply(200, {"audit": s.audit()})
    return req.reply(404, {"error": "not found"})
