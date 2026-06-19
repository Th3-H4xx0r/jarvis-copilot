"""Build + APNs-push the custom-design ("mode: custom") Live Activity state.

Sibling of ``coding_la_push`` but for the data-driven Dynamic Island designs.
The widget already has the *design tree* cached on-device; the server only pushes
``{designId, designVersion, data}`` (a tiny payload) so a SUSPENDED phone keeps a
Jarvis-driven island live. Lives in ``webui/api`` (not ``agent``) so the
``set-data`` route can trigger a push synchronously and reuse ``api.push.apns``.

v1 server push only drives the design the user has PINNED (the one the server can
unambiguously resolve as active). Auto-selected designs are pushed by the Dart
coordinator while the app is awake. The custom-mode content-state carries ALL
ContentState keys (Swift synthesizes no defaults for missing keys).
"""
from __future__ import annotations

import hashlib
import json
import logging
import time

log = logging.getLogger(__name__)

# Per-design dedupe + rate-limit (a Live Activity is last-write-wins, so
# collapsing a burst loses nothing — the next set-data re-sends the latest).
_last_sig: dict[str, str] = {}
_last_push_ts: dict[str, float] = {}
_MIN_PUSH_INTERVAL = 10.0  # seconds between non-forced pushes per design


def build_custom_content_state(design_id: str, version, data) -> dict:
    """The full ContentState dict for a custom design. ``data`` is the resolved
    value map; it is JSON-encoded into the single ``data`` string field so the
    Codable struct stays flat + small."""
    try:
        ver = int(version)
    except (TypeError, ValueError):
        ver = 0
    return {
        # voice fields (idle/empty for a custom design)
        "state": "idle", "transcript": "", "activity": "", "connected": True,
        "devices": [],
        # coding fields (empty)
        "mode": "custom",
        "sessions": [], "sessionTotal": 0, "entryTotal": 0, "waitingCount": 0,
        "usage5": -1, "usageWeek": -1, "usage5Resets": "", "usageWeekResets": "",
        # custom-design fields
        "designId": str(design_id or ""),
        "designVersion": ver,
        "data": json.dumps(data or {}, sort_keys=True, ensure_ascii=False),
    }


def _active_pinned_id(island_store) -> str | None:
    try:
        sel = island_store.get_selection()
    except Exception:
        return None
    if sel.get("mode") == "pinned":
        return sel.get("pinnedId")
    return None


def push_design_update(island_store, token_store, design_id, *, sender=None,
                       force=False) -> int:
    """Push the latest data for ``design_id`` to all LA tokens IF it is the
    pinned (server-resolvable active) design and its content changed. Returns the
    number of successful pushes. Never raises."""
    if not force and _active_pinned_id(island_store) != design_id:
        return 0  # server only drives the pinned design in v1
    try:
        design = island_store.get_design(design_id)
    except Exception:
        design = None
    if not design:
        return 0
    try:
        data = island_store.get_data(design_id)
    except Exception:
        data = {}
    cs = build_custom_content_state(design_id, design.get("version", 1), data)
    sig = hashlib.sha1(json.dumps(cs, sort_keys=True).encode()).hexdigest()
    now = time.monotonic()
    if not force:
        if _last_sig.get(design_id) == sig:
            return 0
        if now - _last_push_ts.get(design_id, 0.0) < _MIN_PUSH_INTERVAL:
            return 0  # rate-limited; don't advance sig so the next call re-sends
    try:
        tokens = token_store.list_la_tokens()
    except Exception:
        return 0
    if not tokens:
        _last_sig[design_id] = sig
        return 0
    if sender is None:
        try:
            from api.push.apns import send_live_activity as sender  # noqa: PLC0415
        except Exception:
            return 0
    pushed = 0
    failures = []
    for t in tokens:
        tok = t.get("token")
        if not tok:
            continue
        try:
            res = sender(tok, cs, event="update")
        except Exception as exc:
            failures.append(f"raised:{exc}")
            continue
        if res.get("ok"):
            pushed += 1
        else:
            failures.append(f"status={res.get('status')}:{res.get('error')}")
            if res.get("status") in (400, 410):
                try:
                    token_store.delete_la_token(tok)
                except Exception:
                    pass
    _last_sig[design_id] = sig
    _last_push_ts[design_id] = now
    log.info("island LA push [%s]: %d/%d token(s) ok%s", design_id, pushed,
             len(tokens), ("; failures=" + "; ".join(failures)) if failures else "")
    return pushed
