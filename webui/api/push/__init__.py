"""Push notification dispatch (APNs).

Used by the device bridge to wake the iOS app when its WebSocket isn't live.
Auth is a JWT signed by an "Auth Key" .p8 stored alongside the team & key ID;
credentials path: ``STATE_DIR/.apns-auth-key.p8``. Without credentials ``send()``
returns ``{"ok": False, "error": "not configured"}`` and the caller falls back
to "device not connected".

Public surface:

    push.send(push_kind, push_token, payload) → dict

``push_kind`` is ``"apns"``. ``payload`` is a small JSON dict (typically just an
envelope telling the app to poll for queued invocations), sent as a *silent*
push (``content-available: 1``) — the app wakes itself, no banner.
"""
from __future__ import annotations

from typing import Optional

from api.push.apns import send_apns


def send(push_kind: str, push_token: str, payload: dict,
         *, timeout: float = 10.0, alert: Optional[dict] = None,
         topic: Optional[str] = None, sandbox: Optional[bool] = None) -> dict:
    """Dispatch a push. ``alert`` (title/body) makes it a visible, tappable push;
    omit for a silent background wake. ``topic`` overrides the APNs bundle ID for
    devices running a different app of ours, and ``sandbox`` the APNs host for a
    device signed for a different environment. Returns ``{"ok": bool, ...}``."""
    if not push_token:
        return {"ok": False, "error": "no push token"}
    kind = (push_kind or "").lower().strip()
    if kind in ("apns", "ios"):
        return send_apns(push_token, payload, timeout=timeout, alert=alert,
                         topic=topic, sandbox=sandbox)
    return {"ok": False, "error": f"unknown push kind: {push_kind!r}"}
