"""Best-effort Claude usage provider for the coding Live Activity (the 5-hour +
weekly usage rings).

SPIKE RESULT: there is no non-interactive Claude CLI command for the subscription
limit percentage — it lives only in the interactive ``/usage`` view, fetched live
from Anthropic and never written to a local file (``~/.claude/stats-cache.json``
holds only *stale daily* token aggregates). So this computes an ESTIMATE from the
data the CLI itself writes: per-message token usage in the transcript store
(``~/.claude/projects/**/*.jsonl``), summed over the trailing 5 hours and 7 days,
expressed as a percentage of a configurable token budget.

The budgets are env-tunable (``JC_CODING_5H_BUDGET`` / ``JC_CODING_WEEK_BUDGET``)
because the true plan limits are not published as token counts — the percentage
is relative to the configured budget, not the official limit. ``get_usage``
returns ``None`` on any failure; the UI then renders the rings empty ("—").
"""
from __future__ import annotations

import glob
import json
import os
import time
from datetime import datetime

_FIVE_HOURS = 5 * 3600
_WEEK = 7 * 24 * 3600
_CACHE_TTL = 60.0

# Order-of-magnitude defaults, NOT official limits (tune via env).
_DEFAULT_5H_BUDGET = 8_000_000
_DEFAULT_WEEK_BUDGET = 120_000_000

_cache = {"at": 0.0, "val": None}


def _budget(env_key: str, default: int) -> int:
    try:
        v = int(os.environ.get(env_key, "") or 0)
    except (TypeError, ValueError):
        return default
    return v if v > 0 else default


def _claude_projects_dir(home: str | None) -> str:
    base = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(
        home or os.path.expanduser("~"), ".claude")
    return os.path.join(base, "projects")


def _parse_ts(s) -> float | None:
    if not isinstance(s, str) or not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def _entry_tokens(obj: dict) -> int:
    """Billable-ish token count for one transcript line (input + output + cache
    creation; cache *reads* are excluded as they're cheap and would inflate)."""
    msg = obj.get("message")
    usage = msg.get("usage") if isinstance(msg, dict) else None
    if not isinstance(usage, dict):
        usage = obj.get("usage")
    if not isinstance(usage, dict):
        return 0
    try:
        return (int(usage.get("input_tokens") or 0)
                + int(usage.get("output_tokens") or 0)
                + int(usage.get("cache_creation_input_tokens") or 0))
    except (TypeError, ValueError):
        return 0


def _fmt_reset(seconds: float) -> str:
    seconds = max(0, int(seconds))
    if seconds >= 86400:
        d, h = seconds // 86400, (seconds % 86400) // 3600
        return f"{d}d {h}h" if h else f"{d}d"
    h, m = seconds // 3600, (seconds % 3600) // 60
    if h:
        return f"{h}h {m}m" if m else f"{h}h"
    return f"{m}m"


def compute_usage(*, now: float, home: str | None = None) -> dict | None:
    """Sum recent transcript token usage into 5-hour and weekly buckets and
    derive percentages + reset hints. Returns None when there's no transcript
    store. Pure-ish (clock injected) for testing."""
    proj = _claude_projects_dir(home)
    if not os.path.isdir(proj):
        return None
    cutoff_week = now - _WEEK
    cutoff_5h = now - _FIVE_HOURS
    tok_5h = tok_week = 0
    earliest_5h = earliest_week = None
    # Dedup by message id: discovery mirrors Mac session transcripts into this
    # same dir, so the same message can appear in two files — count it once.
    seen: set = set()
    try:
        files = glob.glob(os.path.join(proj, "**", "*.jsonl"), recursive=True)
    except OSError:
        return None
    for path in files:
        try:
            if os.path.getmtime(path) < cutoff_week:
                continue  # whole file is older than the window
        except OSError:
            continue
        try:
            with open(path, "r", errors="replace") as f:
                for line in f:
                    # Cheap pre-filter before the JSON parse.
                    if '"usage"' not in line:
                        continue
                    try:
                        obj = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(obj, dict):
                        continue
                    ts = _parse_ts(obj.get("timestamp"))
                    if ts is None or ts < cutoff_week:
                        continue
                    uid = obj.get("uuid") or obj.get("requestId")
                    if uid is not None:
                        if uid in seen:
                            continue
                        seen.add(uid)
                    n = _entry_tokens(obj)
                    if n <= 0:
                        continue
                    tok_week += n
                    earliest_week = ts if earliest_week is None else min(earliest_week, ts)
                    if ts >= cutoff_5h:
                        tok_5h += n
                        earliest_5h = ts if earliest_5h is None else min(earliest_5h, ts)
        except OSError:
            continue
    b5 = _budget("JC_CODING_5H_BUDGET", _DEFAULT_5H_BUDGET)
    bw = _budget("JC_CODING_WEEK_BUDGET", _DEFAULT_WEEK_BUDGET)
    five_pct = max(0, min(100, round(100 * tok_5h / b5))) if b5 else 0
    week_pct = max(0, min(100, round(100 * tok_week / bw))) if bw else 0
    five_reset = _fmt_reset((earliest_5h + _FIVE_HOURS) - now) \
        if earliest_5h is not None else _fmt_reset(_FIVE_HOURS)
    week_reset = _fmt_reset((earliest_week + _WEEK) - now) \
        if earliest_week is not None else _fmt_reset(_WEEK)
    return {
        "five_hour_pct": five_pct,
        "weekly_pct": week_pct,
        "five_hour_resets": five_reset,
        "weekly_resets": week_reset,
        "five_hour_tokens": tok_5h,
        "weekly_tokens": tok_week,
    }


def get_usage(*, now=None, home=None, force=False) -> dict | None:
    """Cached (~60s) usage snapshot, or None. Never raises."""
    now = time.time() if now is None else now
    if (not force and _cache["val"] is not None
            and (now - _cache["at"]) < _CACHE_TTL):
        return _cache["val"]
    try:
        val = compute_usage(now=now, home=home)
    except Exception:
        val = None
    _cache["at"] = now
    _cache["val"] = val
    return val
