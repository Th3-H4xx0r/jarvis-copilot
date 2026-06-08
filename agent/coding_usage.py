"""Accurate Claude account usage for the coding rings (5-hour + weekly).

The numbers shown are the REAL subscription-limit utilization that Claude Code's
interactive ``/usage`` view shows, fetched live from Anthropic's OAuth usage API
(``GET https://api.anthropic.com/api/oauth/usage``) — the same endpoint the
provider-quota card uses (see ``agent/account_usage.py``). This replaces the old
transcript-token ÷ guessed-budget ESTIMATE, which was relative to a made-up
budget and therefore inaccurate.

Design (so the hot path never blocks on a 15s HTTP call):
  - ``compute_usage`` does the blocking fetch and maps it to a snapshot.
  - ``refresh`` calls it and persists the snapshot (in-memory + the coding DB),
    leaving the last good value in place on a transient error.
  - ``start_refresher`` runs ``refresh`` on a daemon thread every ~60s.
  - ``get_usage`` is a NON-BLOCKING read of the cache/DB; the status loop and the
    instant ``/activity-event`` push call it, so they never wait on the network.

Reset hints are stored as ABSOLUTE epoch seconds and the "Xh Ym" countdown is
recomputed at read time, so it stays correct between fetches. The usage API is
OAuth-only: with an API-key (non-OAuth) account, or on any failure, the snapshot
is ``available=False`` and ``get_usage`` returns ``None`` so the rings render "—"
(never a fabricated number).
"""
from __future__ import annotations

import threading
import time

_FIVE_HOURS = 5 * 3600
_WEEK = 7 * 24 * 3600
_OAUTH_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"

# In-memory snapshot, shared by the refresher (writer) and get_usage (readers).
_lock = threading.Lock()
_cache: dict | None = None


def _fmt_reset(seconds: float) -> str:
    """A compact "Xd Yh" / "Xh Ym" / "Xm" countdown string."""
    seconds = max(0, int(seconds))
    if seconds >= 86400:
        d, h = seconds // 86400, (seconds % 86400) // 3600
        return f"{d}d {h}h" if h else f"{d}d"
    h, m = seconds // 3600, (seconds % 3600) // 60
    if h:
        return f"{h}h {m}m" if m else f"{h}h"
    return f"{m}m"


def _parse_dt_epoch(value) -> float | None:
    """ISO-8601 (or epoch) → epoch seconds, or None."""
    if value in (None, ""):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        from datetime import datetime, timezone
        text = value.strip()
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        try:
            dt = datetime.fromisoformat(text)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt.timestamp()
        except ValueError:
            return None
    return None


def _pct(util) -> int | None:
    """Anthropic ``utilization`` (0-1 fraction OR already 0-100) → clamped int %."""
    if util is None:
        return None
    try:
        v = float(util)
    except (TypeError, ValueError):
        return None
    if v <= 1:
        v *= 100
    return max(0, min(100, round(v)))


def _fetch_oauth_usage() -> dict | None:
    """Raw payload from the Anthropic OAuth usage API.

    Returns the JSON dict on success, ``{}`` when the account isn't OAuth-backed
    (a definitive "no usage available"), or ``None`` on a transient error
    (network/HTTP) so the caller can keep the last good snapshot.
    """
    try:
        from agent.anthropic_adapter import _is_oauth_token, resolve_anthropic_token
    except Exception:
        return None
    try:
        token = (resolve_anthropic_token() or "").strip()
    except Exception:
        return None  # transient (e.g. an OAuth refresh hiccup) — keep last good
    if not token:
        # Couldn't resolve a token. This can be a transient OAuth-refresh failure,
        # so treat it as transient (None) rather than definitively unavailable —
        # don't clobber the last good cached/persisted snapshot over a blip.
        return None
    if not _is_oauth_token(token):
        return {}  # definitively unavailable: an API-key (non-OAuth) account
    try:
        import httpx
    except Exception:
        return None
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
        "Content-Type": "application/json",
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": "claude-code/2.1.0",
    }
    try:
        with httpx.Client(timeout=15.0) as client:
            r = client.get(_OAUTH_USAGE_URL, headers=headers)
            r.raise_for_status()
        return r.json() or {}
    except Exception:
        return None  # transient → keep last good snapshot


def compute_usage(*, now: float | None = None, fetch=_fetch_oauth_usage) -> dict | None:
    """Fetch + map account usage into a persistable snapshot.

    Returns a snapshot dict ``{five_hour_pct, weekly_pct, five_hour_reset_at,
    weekly_reset_at, available, fetched_at}`` (pcts are ints or None; reset_at is
    absolute epoch seconds or None). Returns ``None`` ONLY on a transient fetch
    error, so the refresher leaves the last good snapshot untouched. A non-OAuth
    account yields ``available=False`` (a definitive, persistable result).
    """
    now = time.time() if now is None else now
    payload = fetch()
    if payload is None:
        return None  # transient error → don't clobber the cache
    five = payload.get("five_hour") or {}
    week = payload.get("seven_day") or {}
    five_pct = _pct(five.get("utilization"))
    week_pct = _pct(week.get("utilization"))
    return {
        "five_hour_pct": five_pct,
        "weekly_pct": week_pct,
        "five_hour_reset_at": _parse_dt_epoch(five.get("resets_at")),
        "weekly_reset_at": _parse_dt_epoch(week.get("resets_at")),
        "available": five_pct is not None or week_pct is not None,
        "fetched_at": now,
    }


def _to_usage_dict(snap: dict | None, *, now: float) -> dict | None:
    """Render a stored snapshot into the consumer dict (LA + WebUI), or None.

    ``None`` when there's no usable snapshot, so the rings show "—". Reset
    countdowns are computed fresh from the absolute reset timestamps."""
    if not snap or not snap.get("available"):
        return None
    five_pct = snap.get("five_hour_pct")
    week_pct = snap.get("weekly_pct")

    def _reset_str(reset_at):
        if reset_at is None:
            return ""
        return _fmt_reset(float(reset_at) - now)

    return {
        "five_hour_pct": int(five_pct) if five_pct is not None else -1,
        "weekly_pct": int(week_pct) if week_pct is not None else -1,
        "five_hour_resets": _reset_str(snap.get("five_hour_reset_at")),
        "weekly_resets": _reset_str(snap.get("weekly_reset_at")),
        "five_hour_reset_at": snap.get("five_hour_reset_at"),
        "weekly_reset_at": snap.get("weekly_reset_at"),
        "available": True,
        "fetched_at": snap.get("fetched_at"),
    }


def refresh(store=None, *, now: float | None = None, fetch=_fetch_oauth_usage) -> dict | None:
    """Fetch a fresh snapshot, update the in-memory cache + persist to the store.

    Leaves the last good snapshot in place on a transient error. Returns the
    snapshot it stored (or the existing one). Never raises."""
    global _cache
    now = time.time() if now is None else now
    try:
        snap = compute_usage(now=now, fetch=fetch)
    except Exception:
        snap = None
    if snap is None:
        with _lock:
            return _cache
    with _lock:
        _cache = snap
    if store is not None:
        try:
            store.upsert_usage_snapshot(
                five_hour_pct=snap["five_hour_pct"],
                weekly_pct=snap["weekly_pct"],
                five_hour_reset_at=snap["five_hour_reset_at"],
                weekly_reset_at=snap["weekly_reset_at"],
                available=snap["available"],
                fetched_at=snap["fetched_at"])
        except Exception:
            pass
    return snap


def get_usage(store=None, *, now: float | None = None) -> dict | None:
    """NON-BLOCKING usage snapshot for the rings, or None ("—"). Never fetches.

    Reads the in-memory cache; on a cold cache (e.g. right after a webui
    restart) falls back to the persisted DB snapshot if ``store`` is given.
    Never raises."""
    global _cache
    now = time.time() if now is None else now
    with _lock:
        snap = _cache
    if snap is None and store is not None:
        try:
            snap = store.get_usage_snapshot()
        except Exception:
            snap = None
        if snap is not None:
            with _lock:
                # Seed the cache so subsequent reads don't re-hit the DB.
                if _cache is None:
                    _cache = snap
    try:
        return _to_usage_dict(snap, now=now)
    except Exception:
        return None


def start_refresher(store, *, interval: float = 60.0):
    """Start the background usage poller on a daemon thread.

    Does one immediate refresh, then refreshes every ``interval`` seconds.
    Returns ``(thread, stop_event)``; call ``stop_event.set()`` to stop."""
    stop_event = threading.Event()

    def _loop():
        # Seed from the DB immediately so a cold start isn't blank, then fetch.
        try:
            get_usage(store)
        except Exception:
            pass
        while not stop_event.is_set():
            try:
                refresh(store)
            except Exception:
                pass
            stop_event.wait(interval)

    t = threading.Thread(target=_loop, daemon=True, name="coding-usage")
    t.start()
    return t, stop_event
