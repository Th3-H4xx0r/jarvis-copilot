"""Which device tools stay fully loaded; the rest are reached on demand.

Device tools (one per skill a paired device offers — ~170 on the iPhone) were
once all sent on every request: ~28k tokens at the head of every agent's
prompt. Now only the ones the user actually calls stay loaded — ranked by the
last 30 days of calls (direct, and bridged through ``tool_call``), filled up to
a token budget, plus any pins — and everything else sits in the on-demand
catalogue (``tool_search`` then ``tool_call``).

Config (``agent.device_tools`` in config.yaml):
    always_loaded_tokens  budget for the loaded set (default 8000)
    pinned                tool names always loaded

The counts are cached for a day in ``<home>/cache/device_tool_rank.json`` and
recounted in the background, so building an agent never waits on a scan of
state.db — and the loaded set (part of the cached prompt) moves at most daily.
"""
from __future__ import annotations

import json
import logging
import sqlite3
import threading
import time
from collections import Counter
from pathlib import Path

logger = logging.getLogger(__name__)

_DEFAULT_BUDGET = 8000
_DAYS = 30
_MAX_AGE_S = 24 * 3600
_refreshing = threading.Lock()


def _default_pins() -> list:
    """The pins DEFAULT_CONFIG ships (the car's directions)."""
    try:
        from jarviscopilot_cli.config import DEFAULT_CONFIG
        pins = ((DEFAULT_CONFIG.get("agent") or {}).get("device_tools") or {}).get("pinned") or []
        return [str(p) for p in pins]
    except Exception:
        logger.warning("device tools: default pins unreadable", exc_info=True)
        return []


def _config() -> dict:
    try:
        from jarviscopilot_cli.config import load_config
        cfg = ((load_config() or {}).get("agent", {}) or {}).get("device_tools") or {}
    except Exception:
        logger.warning("device tools: config unreadable; using defaults", exc_info=True)
        cfg = {}
    try:
        budget = int(cfg.get("always_loaded_tokens", _DEFAULT_BUDGET))
    except (TypeError, ValueError):
        budget = _DEFAULT_BUDGET
    pinned = cfg.get("pinned") or []
    pinned = [str(p) for p in pinned] if isinstance(pinned, list) else []
    # A pinned list in config.yaml replaces the default one when merged; the
    # built-in pins stay in either way.
    return {"always_loaded_tokens": max(0, budget),
            "pinned": list(dict.fromkeys(pinned + _default_pins()))}


def _home() -> Path:
    from jarviscopilot_constants import get_hermes_home
    return get_hermes_home()


def _cache_path() -> Path:
    return _home() / "cache" / "device_tool_rank.json"


def count_usage(db_path, days: int = _DAYS) -> Counter:
    """Tool calls per name in the last ``days`` (bridged ``tool_call`` rows
    counted under the tool they really reached). One pass over the table:
    there is no timestamp-only index, and state.db runs to gigabytes."""
    since = time.time() - days * 86400
    counts: Counter = Counter()
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=5)
    try:
        rows = con.execute(
            "SELECT role, tool_name, tool_calls FROM messages WHERE timestamp >= ? AND "
            "((role = 'tool' AND tool_name IS NOT NULL AND tool_name != 'tool_call') OR "
            "(role = 'assistant' AND tool_calls LIKE '%tool_call%'))", (since,))
        for role, name, raw in rows:
            if role == "tool":
                counts[name] += 1
                continue
            try:
                calls = json.loads(raw or "[]")
            except ValueError:
                continue
            for c in calls if isinstance(calls, list) else []:
                fn = (c or {}).get("function") or {} if isinstance(c, dict) else {}
                if fn.get("name") != "tool_call":
                    continue
                args = fn.get("arguments")
                try:
                    args = json.loads(args) if isinstance(args, str) else args
                except ValueError:
                    continue
                inner = (args or {}).get("name") if isinstance(args, dict) else None
                if isinstance(inner, str) and inner:
                    counts[inner] += 1
    finally:
        con.close()
    return counts


def _write_cache(payload: dict) -> None:
    path = _cache_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload))
    tmp.replace(path)


def _recount() -> None:
    if not _refreshing.acquire(blocking=False):
        return
    try:
        db = _home() / "state.db"
        counts = count_usage(db) if db.exists() else Counter()
        _write_cache({"computed_at": time.time(), "counts": dict(counts)})
    except Exception:
        logger.warning("device tool usage recount failed", exc_info=True)
        # Keep what was counted before and try again in an hour — not on every
        # agent build (each try is a full scan of state.db).
        try:
            old = json.loads(_cache_path().read_text()).get("counts") or {}
        except Exception:
            old = {}
        try:
            _write_cache({"computed_at": time.time() - _MAX_AGE_S + 3600, "counts": old, "failed": True})
        except Exception:
            logger.debug("device tool rank cache not written", exc_info=True)
    finally:
        _refreshing.release()


def refresh_in_background() -> None:
    threading.Thread(target=_recount, daemon=True, name="jc-device-tool-rank").start()


def usage_counts(days: int = _DAYS) -> dict:
    """The cached counts (possibly a day old); a missing or stale cache is
    recounted in the background and this call answers with what it has."""
    data: dict = {}
    try:
        data = json.loads(_cache_path().read_text())
    except Exception:
        data = {}
    if not data or time.time() - float(data.get("computed_at") or 0) > _MAX_AGE_S:
        refresh_in_background()
    counts = data.get("counts") if isinstance(data, dict) else None
    return dict(counts) if isinstance(counts, dict) else {}


def always_loaded_device_tools(candidates: dict) -> list:
    """Names (sorted) of the device tools to keep loaded, out of
    ``candidates`` = ``{tool name: estimated schema tokens}``."""
    cfg = _config()
    budget = cfg["always_loaded_tokens"]
    raw = usage_counts()
    # The bridge takes a device skill's bare name ("x5_get_status") for its
    # device_ tool, so those calls count toward it too.
    counts = {n: int(raw.get(n, 0) or 0) + (int(raw.get(n[len("device_"):], 0) or 0)
                                            if n.startswith("device_") else 0)
              for n in candidates}
    counts = {n: c for n, c in counts.items() if c}
    chosen = {p for p in cfg["pinned"] if p in candidates}
    spent = sum(int(candidates[p] or 0) for p in chosen)
    # Most used first; with no history at all, name order (still deterministic).
    ranked = sorted((n for n in candidates if n not in chosen),
                    key=lambda n: (-int(counts.get(n, 0) or 0), n))
    if counts:
        ranked = [n for n in ranked if counts.get(n)]
    for name in ranked:
        cost = int(candidates[name] or 0)
        if spent + cost <= budget:
            chosen.add(name)
            spent += cost
    return sorted(chosen)
