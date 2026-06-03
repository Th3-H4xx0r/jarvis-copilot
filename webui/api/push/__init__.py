"""Push notification dispatch (FCM + APNs).

Used by the device bridge to wake mobile clients when the WebSocket isn't
live. Two backends are supported:

- FCM HTTP v1 (Android). Auth is a service-account JSON key signed into a
  short-lived OAuth bearer token. Credentials path: ``STATE_DIR/.fcm-service-account.json``.
- APNs HTTP/2 (iOS). Auth is a JWT signed by an "Auth Key" .p8 stored
  alongside the team & key ID. Credentials path: ``STATE_DIR/.apns-auth-key.p8``.

Both backends are *optional*; if their credentials aren't on disk the
``send()`` helper returns ``{"ok": False, "error": "not configured"}``
and the caller is expected to fall back to "device not connected".

Public surface:

    push.send(push_kind, push_token, payload) → dict

Where ``push_kind`` is ``"fcm"`` or ``"apns"``. ``payload`` is a small
JSON dict (typically just an envelope telling the app to poll for queued
invocations). For iOS we use *silent* push (``content-available: 1``) —
the app wakes itself, no banner. For Android the FCM ``data`` payload
fires the FirebaseMessagingService background handler.
"""
from __future__ import annotations

import logging
from typing import Optional

from api.push.fcm import send_fcm, fcm_configured
from api.push.apns import send_apns, apns_configured

logger = logging.getLogger(__name__)


def send(push_kind: str, push_token: str, payload: dict,
         *, timeout: float = 10.0, alert: Optional[dict] = None) -> dict:
    """Dispatch to the right backend. ``alert`` (title/body) makes it a visible,
    tappable push; omit for a silent background wake. Returns ``{"ok": bool, ...}``."""
    if not push_token:
        return {"ok": False, "error": "no push token"}
    kind = (push_kind or "").lower().strip()
    if kind in ("fcm", "android"):
        return send_fcm(push_token, payload, timeout=timeout, alert=alert)
    if kind in ("apns", "ios"):
        return send_apns(push_token, payload, timeout=timeout, alert=alert)
    return {"ok": False, "error": f"unknown push kind: {push_kind!r}"}


def configured() -> dict:
    """Report which backends are configured. Used by /api/devices/mobile/token
    so the mobile app knows whether push is even available."""
    return {
        "fcm": fcm_configured(),
        "apns": apns_configured(),
    }
