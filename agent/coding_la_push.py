"""Build + APNs-push the coding-mode Live Activity ContentState.

Mirrors the Dart ``LiveActivityCoordinator`` project aggregation so the SERVER
can keep the iOS Live Activity live while the app is suspended/closed
(push-to-update). The status-loop calls ``push_coding_update`` each tick; it
rebuilds the content-state from the store (so both server-host poll changes AND
desktop discovery changes are reflected) and pushes to all registered Live
Activity tokens ONLY when the content actually changed.

The content-state keys MUST match the Swift ``JarvisActivityAttributes
.ContentState`` Codable property names exactly, and ALL of them must be present
(synthesized Decodable doesn't apply Swift defaults for missing keys).
"""
from __future__ import annotations

import hashlib
import json
import logging

log = logging.getLogger(__name__)

_LIVE_STATUSES = {"running", "starting", "idle"}
_US = "\x1f"  # unit separator between name and state (matches the Swift decode)

# Per-session sub-state shorthand for the segmented bar (3rd encoded field).
_SHORT = {"working": "w", "waiting": "p", "idle": "i"}
_MAX_SUBS = 8  # cap sub-segments per project (budget + legibility)


def _encode_subs(subs) -> str:
    return ",".join(_SHORT.get(s, "i") for s in subs[:_MAX_SUBS])

# Module-level dedupe: only push when the content-state signature changes.
_last_sig = {"v": ""}


def _status_class(status) -> str:
    s = str(status or "").lower()
    if s in ("running", "active", "busy"):
        return "running"
    if s in ("done", "completed", "finished"):
        return "done"
    if s in ("error", "failed"):
        return "error"
    if s in ("stopped", "cancelled", "canceled"):
        return "stopped"
    return "idle"


def _is_transcript_idle(row) -> bool:
    return (row.get("source") == "discovered-transcript"
            and _status_class(row.get("status")) != "running")


def _is_live(row) -> bool:
    return row.get("status") in _LIVE_STATUSES and not _is_transcript_idle(row)


def _live_state(row) -> str:
    act = str(row.get("activity_state") or "").lower()
    if act in ("waiting", "working", "idle"):
        return act
    return "working" if _status_class(row.get("status")) == "running" else "idle"


def _recency(row) -> float:
    raw = row.get("last_activity_at") or row.get("created_at") or 0
    try:
        n = float(raw)
        return n / 1000.0 if n > 1e12 else n
    except (TypeError, ValueError):
        return 0.0


def _priority(state: str) -> int:
    return {"waiting": 0, "working": 1}.get(state, 2)


def _aggregate(states) -> str:
    if "waiting" in states:
        return "waiting"
    if "working" in states:
        return "working"
    return "idle"


def _folder(cwd) -> str:
    base = str(cwd or "").rstrip("/").split("/")[-1]
    return base or "session"


def _sanitize(label) -> str:
    t = str(label or "").replace(_US, " ").strip()
    return (t[:21] + "…") if len(t) > 22 else t


def build_coding_content_state(store, usage=None):
    """The coding-mode ContentState dict, or None if there are no live sessions.

    One legend entry per PROJECT (aggregate state), labeled by project name;
    ungrouped sessions fall back to their cwd folder. Spotlight-sorted
    waiting > working > idle, then most-recent."""
    try:
        rows = store.list_sessions()
        projects = {p["id"]: p for p in store.list_projects()}
    except Exception:
        return None
    by_project: dict = {}
    ungrouped: list = []
    total = 0
    waiting = 0
    for r in rows:
        if not _is_live(r):
            continue
        total += 1
        st = _live_state(r)
        if st == "waiting":
            waiting += 1
        pid = r.get("project_id")
        if pid and pid in projects:
            by_project.setdefault(pid, []).append((st, _recency(r)))
        else:
            ungrouped.append((_folder(r.get("cwd")), st, _recency(r)))
    if total == 0:
        return None
    entries = []  # (label, aggregate_state, recency, sub_states)
    for pid, items in by_project.items():
        rec = max(rc for _, rc in items)
        states = [s for s, _ in items]
        # Order sub-states waiting > working > idle so the bar reads
        # consistently; cap defensively (the budget allows far more).
        subs = sorted(states, key=_priority)[:_MAX_SUBS]
        entries.append((projects[pid].get("name") or "project",
                        _aggregate(states), rec, subs))
    for folder, st, rec in ungrouped:
        entries.append((folder, st, rec, [st]))
    entries.sort(key=lambda e: (_priority(e[1]), -e[2]))
    # Encode "name␟aggState[␟subs]" — the 3rd field (per-session sub-states,
    # e.g. "w,p") is present only when a project has 2+ live sessions, so a
    # single-session project/ungrouped row renders exactly as before.
    sessions = []
    for lbl, st, _rec, subs in entries[:4]:
        enc = f"{_sanitize(lbl)}{_US}{st}"
        if len(subs) > 1:
            enc += f"{_US}{_encode_subs(subs)}"
        sessions.append(enc)
    cs = {
        "state": "idle", "transcript": "", "activity": "", "connected": True,
        "devices": [], "mode": "coding",
        "sessions": sessions, "sessionTotal": total, "entryTotal": len(entries),
        "waitingCount": waiting,
        "usage5": -1, "usageWeek": -1, "usage5Resets": "", "usageWeekResets": "",
    }
    if usage:
        # Set each ring independently so a missing window (e.g. weekly absent)
        # doesn't blank the other. -1 renders as "—" on the device.
        def _as_pct(v):
            try:
                return int(v)
            except (TypeError, ValueError):
                return -1
        cs["usage5"] = _as_pct(usage.get("five_hour_pct", -1))
        cs["usageWeek"] = _as_pct(usage.get("weekly_pct", -1))
        cs["usage5Resets"] = str(usage.get("five_hour_resets") or "")
        cs["usageWeekResets"] = str(usage.get("weekly_resets") or "")
    return cs


def push_coding_update(store, *, usage=None, force=False, sender=None) -> int:
    """Build the content-state and push to all registered LA tokens IF it
    changed since the last push. Returns the number of successful pushes.
    ``sender`` defaults to ``api.push.apns.send_live_activity`` (injected in
    tests). Never raises."""
    cs = build_coding_content_state(store, usage)
    if cs is None:
        return 0  # nothing live; let the device's own coordinator handle resting
    sig = hashlib.sha1(json.dumps(cs, sort_keys=True).encode()).hexdigest()
    if not force and sig == _last_sig["v"]:
        return 0
    try:
        tokens = store.list_la_tokens()
    except Exception:
        return 0
    if not tokens:
        _last_sig["v"] = sig
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
            log.warning("coding LA push raised for token …%s: %s",
                        str(tok)[-6:], exc)
            continue
        if res.get("ok"):
            pushed += 1
        else:
            # Surface WHY a push failed — previously swallowed, which hid the
            # most common cause: a sandbox/production token-vs-host mismatch
            # (HTTP 400 BadDeviceToken). Without this log there was no signal.
            failures.append(f"status={res.get('status')}:{res.get('error')}")
            log.warning("coding LA push failed (token …%s): status=%s error=%s",
                        str(tok)[-6:], res.get("status"), res.get("error"))
            if res.get("status") in (400, 410):
                # BadDeviceToken / Unregistered → drop the stale token.
                try:
                    store.delete_la_token(tok)
                except Exception:
                    pass
    _last_sig["v"] = sig
    log.info("coding LA push: %d/%d token(s) ok%s", pushed, len(tokens),
             ("; failures=" + "; ".join(failures)) if failures else "")
    return pushed
