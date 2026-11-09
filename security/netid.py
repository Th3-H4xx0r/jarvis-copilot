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
