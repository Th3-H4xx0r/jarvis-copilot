"""Who sent this request: the real client IP and the device behind it.

Behind Cloudflare → cloudflared → nginx every request reaches the webui from
127.0.0.1, and nginx passes Cloudflare's ``CF-Connecting-IP`` through. The webui
also listens on the LAN, where a peer could send that header itself, so it is
trusted only when the peer is loopback (the local edge).
"""
from __future__ import annotations

import ipaddress

_LOOPBACK = {"127.0.0.1", "::1"}


def _peer(handler) -> str:
    try:
        return str((handler.client_address or ("",))[0] or "")
    except Exception:
        return ""


def client_ip(handler) -> str:
    peer = _peer(handler)
    if peer in _LOOPBACK:
        try:
            raw = (handler.headers.get("CF-Connecting-IP") or "").strip()
        except Exception:
            raw = ""
        if raw:
            try:
                return str(ipaddress.ip_address(raw))
            except ValueError:
                pass
    return peer


def actor_for(handler) -> dict:
    """Who made this webui request: real IP plus the paired device, if any.

    ``session_kind`` is ``paired`` (a valid session of a paired device),
    ``unpaired`` (a valid session with no device record, e.g. password login),
    ``host`` (host-signed loopback call from the agent side) or ``none``.
    Never raises; outside the webui process it reports the IP only."""
    actor = {"ip": "", "device_id": "", "device_name": "", "session_kind": "none"}
    try:
        actor["ip"] = client_ip(handler)
        from api.auth import check_host_signature, parse_cookie, verify_session
        from api.pairing import find_device_by_session
        cookie = parse_cookie(handler) or ""
        device = find_device_by_session(cookie) if cookie else None
        if device:
            actor["device_id"] = str(device.get("id") or "")
            actor["device_name"] = str(device.get("name") or "")
        if cookie and verify_session(cookie):
            actor["session_kind"] = "paired" if device else "unpaired"
        elif check_host_signature(handler):
            actor["session_kind"] = "host"
    except Exception:
        pass
    return actor
