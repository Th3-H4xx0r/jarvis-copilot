"""Fill ``costs.db``: price Jarvis's own usage, read billing APIs, spread subscriptions.

Run every few hours by the webui (``api/costs_routes``) and on demand from the UI or the
``cost_insights`` tool. It is HTTP + SQL only — never an LLM call, which would add to the
very bill being measured. Each step is isolated: a dead provider marks its own
``sync_state`` error and the rest carry on.

Recent days are recomputed every run (upserts), so late call-log rows and revised billing
land; days older than the window are left alone, which is what keeps history.
"""
from __future__ import annotations

import calendar
import logging
import os
import sqlite3
import threading
import time
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

from agent.costs import catalog
from agent.costs.store import CostStore, day_of, day_start_ts, days_back, get_store

logger = logging.getLogger(__name__)

RECENT_DAYS = 35
BACKFILL_DAYS = 365
_HTTP_TIMEOUT = 20.0
_RUN_LOCK = threading.Lock()
# Plan writes (settings.py) and spreads share this one, not _RUN_LOCK, so saving a
# price never waits behind a slow billing fetch.
SPREAD_LOCK = threading.RLock()


# ── environment ──────────────────────────────────────────────────────────

def _home() -> Path:
    from jarviscopilot_constants import get_hermes_home
    return get_hermes_home()


def _env_file() -> Dict[str, str]:
    values: Dict[str, str] = {}
    try:
        for raw in (_home() / ".env").read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().strip('"').strip("'")
    except OSError:
        pass
    return values


def env_value(name: str, env_file: Optional[Dict[str, str]] = None) -> str:
    """A key's value from the profile .env (what the UI writes) or the process env.
    Blank counts as unset — a key line with no value is common in his .env."""
    values = env_file if env_file is not None else _env_file()
    return (values.get(name) or os.environ.get(name) or "").strip()


def load_config() -> Dict[str, Any]:
    try:
        import yaml
        data = yaml.safe_load((_home() / "config.yaml").read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def config_value(config: Dict[str, Any], dotted: str) -> Any:
    node: Any = config
    for part in dotted.split("."):
        if not isinstance(node, dict):
            return None
        node = node.get(part)
    return node


def fish_audio_key(config: Dict[str, Any], env_file: Dict[str, str]) -> str:
    key = str(config_value(config, "tts.fish-audio.api_key") or "").strip()
    if key:
        return key
    for name in ("FISH_AUDIO_API_KEY", "FISH_API_KEY"):
        key = env_value(name, env_file)
        if key:
            return key
    return ""


class ProviderError(RuntimeError):
    def __init__(self, message: str, status: Optional[int] = None) -> None:
        super().__init__(message)
        self.status = status


class Context:
    def __init__(self, store: CostStore, http_get: Optional[Callable[..., Any]] = None) -> None:
        self.store = store
        self.env_file = _env_file()
        self.config = load_config()
        self._http_get = http_get

    def env(self, name: str) -> str:
        return env_value(name, self.env_file)

    def get_json(self, url: str, *, headers: Dict[str, str], params: Any = None) -> Any:
        """GET → parsed JSON. Errors carry the status and a short body, never the key."""
        if self._http_get is not None:
            return self._http_get(url, headers=headers, params=params)
        import httpx
        resp = httpx.get(url, headers=headers, params=params, timeout=_HTTP_TIMEOUT)
        if resp.status_code >= 400:
            body = (resp.text or "")[:200].replace("\n", " ")
            raise ProviderError(f"HTTP {resp.status_code}: {body}", status=resp.status_code)
        return resp.json()


def _num(value: Any) -> Optional[float]:
    if value is None or value == "":
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _utc_day(iso: Any) -> str:
    return str(iso or "")[:10]


# ── 1. LLM calls priced from message_usage ──────────────────────────────

def _state_db() -> Path:
    return _home() / "state.db"


def _long_cache(config: Dict[str, Any]) -> bool:
    return str(config_value(config, "prompt_caching.retention") or "").strip().lower() == "long"


def rebuild_llm_estimates(store: CostStore, since_ts: float,
                          state_db: Optional[Path] = None,
                          long_cache: bool = False) -> Dict[str, int]:
    """Price every logged model call since ``since_ts`` and write per-service daily rows.

    Pay-as-you-go services get their amount. Subscription and free services get amount 0
    plus ``api_equiv_usd`` in the units — what the same calls would cost on the API.

    The price table's cache-write rate is Anthropic's 5-minute one. With
    ``prompt_caching.retention: long`` native Anthropic writes use 1-hour markers, billed
    at 2× input rather than 1.25×, so those writes get the difference added."""
    from agent.usage_pricing import CanonicalUsage, estimate_usage_cost, get_pricing_entry

    path = state_db or _state_db()
    if not path.exists():
        return {}
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=10)
    try:
        rows = conn.execute(
            "SELECT timestamp, provider, model, input_tokens, output_tokens, cache_read_tokens, "
            "cache_write_tokens, reasoning_tokens FROM message_usage WHERE timestamp >= ?",
            (since_ts,)).fetchall()
    finally:
        conn.close()

    # (day, provider, model) → [calls, in, out, cache read, cache write, reasoning]
    groups: Dict[tuple, List[int]] = defaultdict(lambda: [0, 0, 0, 0, 0, 0])
    for ts, provider, model, i, o, cr, cw, rs in rows:
        g = groups[(day_of(ts), (provider or "").strip().lower(), (model or "").strip())]
        g[0] += 1
        g[1] += int(i or 0)
        g[2] += int(o or 0)
        g[3] += int(cr or 0)
        g[4] += int(cw or 0)
        g[5] += int(rs or 0)

    per: Dict[tuple, Dict[str, Any]] = {}
    for (day, provider, model), (calls, i, o, cr, cw, rs) in groups.items():
        sid = catalog.service_for_provider(provider)
        try:
            cost = estimate_usage_cost(model, CanonicalUsage(
                input_tokens=i, output_tokens=o, cache_read_tokens=cr, cache_write_tokens=cw,
                reasoning_tokens=rs, request_count=calls), provider=provider)
            amount = float(cost.amount_usd) if cost.amount_usd is not None else None
            if amount is None and model.startswith("claude-"):
                # Claude through a subscription (claude-code): what the API would charge.
                cost = estimate_usage_cost(model, CanonicalUsage(
                    input_tokens=i, output_tokens=o, cache_read_tokens=cr, cache_write_tokens=cw,
                    reasoning_tokens=rs, request_count=calls), provider="anthropic")
                amount = float(cost.amount_usd) if cost.amount_usd is not None else None
            if amount is not None and long_cache and cw and provider in ("anthropic-api", "anthropic"):
                entry = get_pricing_entry(model, provider=provider)
                if entry and entry.input_cost_per_million is not None:
                    amount += cw * float(entry.input_cost_per_million) * 0.75 / 1e6
        except Exception:
            amount = None
        b = per.setdefault((sid, day), {
            "calls": 0, "input_tokens": 0, "output_tokens": 0, "cache_read_tokens": 0,
            "cache_write_tokens": 0, "priced_usd": 0.0, "unpriced_calls": 0, "models": {}})
        b["calls"] += calls
        b["input_tokens"] += i
        b["output_tokens"] += o
        b["cache_read_tokens"] += cr
        b["cache_write_tokens"] += cw
        m = b["models"].setdefault(model or "unknown", {"calls": 0, "tokens": 0, "cost_usd": 0.0})
        m["calls"] += calls
        m["tokens"] += i + o + cr + cw
        if amount is None:
            b["unpriced_calls"] += calls
            m["unpriced"] = True
        else:
            b["priced_usd"] += amount
            m["cost_usd"] = round(m["cost_usd"] + amount, 6)

    counts: Dict[str, int] = defaultdict(int)
    for (sid, day), b in per.items():
        entry = catalog.get(sid) or catalog.adhoc_service(sid)
        priced = round(b.pop("priced_usd"), 6)
        if entry.get("kind") == "usage":
            amount = priced
        else:
            amount = 0.0
            b["covered"] = True
            b["api_equiv_usd"] = priced
        store.upsert_daily(sid, day, "estimate", amount, b)
        counts[sid] += 1
    return dict(counts)


# ── 2. the local meter ──────────────────────────────────────────────────

def rollup_meter(store: CostStore, since_ts: float) -> None:
    """Turn metered events into daily estimate rows — only for days that have events, so a
    backfilled day is never zeroed out."""
    by_day: Dict[str, Dict[str, Any]] = {}
    for ev in store.events("parallel", since_ts):
        mode = str(ev["meta"].get("mode") or "fast").lower()
        price = catalog.PARALLEL_PER_SEARCH.get(mode, catalog.PARALLEL_PER_SEARCH["fast"])
        d = by_day.setdefault(day_of(ev["ts"]), {"searches": 0, "amount": 0.0, "modes": {}})
        d["searches"] += int(ev["units"])
        d["amount"] += ev["units"] * price
        d["modes"][mode] = d["modes"].get(mode, 0) + int(ev["units"])
    for day, d in by_day.items():
        store.upsert_daily("parallel", day, "estimate", round(d.pop("amount"), 6), d)

    # Soniox: jarvis_speech already records paid stream seconds per (UTC) day and surface.
    try:
        from jarvis_speech import usage as speech_usage
        since_day = datetime.fromtimestamp(since_ts, timezone.utc).strftime("%Y-%m-%d")
        for day, row in (speech_usage._read() or {}).items():
            if day < since_day or not isinstance(row, dict):
                continue
            by_surface = {str(k): float(v or 0) for k, v in row.items()}
            secs = sum(by_surface.values())
            if secs > 0:
                store.upsert_daily("soniox", day, "estimate",
                                   round(secs / 3600 * catalog.SONIOX_PER_HOUR, 6),
                                   {"audio_seconds": round(secs, 1),
                                    "by_purpose": {k: round(v, 1) for k, v in by_surface.items()}})
    except Exception:
        logger.warning("costs: reading speech_usage.json failed", exc_info=True)

    nbytes: Dict[str, float] = defaultdict(float)
    reqs: Dict[str, int] = defaultdict(int)
    for ev in store.events("fish-audio", since_ts):
        day = day_of(ev["ts"])
        nbytes[day] += ev["units"]
        reqs[day] += 1
    for day, b in nbytes.items():
        store.upsert_daily("fish-audio", day, "estimate",
                           round(b / 1e6 * catalog.FISH_PER_MILLION_BYTES, 6),
                           {"bytes": int(b), "requests": reqs[day]})


def backfill_parallel(ctx: "Context", state_db: Optional[Path] = None) -> None:
    """Once: estimate the Parallel searches made before the meter existed, from the
    ``web_search`` tool results in chat history (the 30 days before the first metered
    search). History doesn't record which backend served a search, so these days are
    marked ``from_history``."""
    store = ctx.store
    if store.get_meta("parallel_backfilled") or not ctx.env("PARALLEL_API_KEY"):
        return
    path = state_db or _state_db()
    first = store.events("parallel")
    # Up to the start of the first metered day: that day's row belongs to the meter.
    until = day_start_ts(day_of(first[0]["ts"] if first else time.time()))
    since = until - 30 * 86400
    if path.exists():
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=10)
        try:
            rows = conn.execute(
                "SELECT timestamp FROM messages WHERE tool_name='web_search' AND role='tool' "
                "AND timestamp >= ? AND timestamp < ?", (since, until)).fetchall()
        finally:
            conn.close()
        counts: Dict[str, int] = defaultdict(int)
        for (ts,) in rows:
            counts[day_of(ts)] += 1
        price = catalog.PARALLEL_PER_SEARCH["fast"]
        for day, n in counts.items():
            store.upsert_daily("parallel", day, "estimate", round(n * price, 6),
                               {"searches": n, "from_history": True})
    store.set_meta("parallel_backfilled", str(time.time()))


# ── 3. subscriptions ─────────────────────────────────────────────────────

def subscription_daily_amount(amount_usd: float, interval: str, day: str) -> float:
    year, month = int(day[:4]), int(day[5:7])
    if interval == "year":
        return amount_usd / (366 if calendar.isleap(year) else 365)
    return amount_usd / calendar.monthrange(year, month)[1]


def _next_day(day: str) -> str:
    return (datetime.strptime(day, "%Y-%m-%d") + timedelta(days=1)).strftime("%Y-%m-%d")


def valid_day(day: str) -> bool:
    try:
        datetime.strptime(day, "%Y-%m-%d")
        return True
    except (TypeError, ValueError):
        return False


def spread_subscriptions(store: CostStore) -> None:
    """Rewrite every configured plan's daily rows from its start day to today.

    A plan with no start day starts where Jarvis's own usage history starts — charging a
    year of hosting before Jarvis existed would swamp every trend. Runs under SPREAD_LOCK
    so a plan edited mid-spread can't be written back at its old price, and clears plan
    rows whose service has no config left (a delete raced by the other process)."""
    with SPREAD_LOCK:
        today = day_of(time.time())
        earliest = days_back(BACKFILL_DAYS)[0]
        default_since = store.earliest_day("estimate") or today
        configs = store.all_service_configs()
        for sid in store.services_with_rows():
            if sid not in configs:
                store.delete_daily(sid, "subscription")
        for sid, cfg in configs.items():
            try:
                amount = _num(cfg.get("amount_usd"))
                store.delete_daily(sid, "subscription")
                if amount is None:
                    continue
                interval = "year" if cfg.get("interval") == "year" else "month"
                since = str(cfg.get("since") or "")
                day = max(since if valid_day(since) else default_since, earliest)
                units = {"plan": cfg.get("plan"), "amount_usd": amount, "interval": interval}
                while day <= today:
                    store.upsert_daily(sid, day, "subscription",
                                       round(subscription_daily_amount(amount, interval, day), 6), units)
                    day = _next_day(day)
            except Exception:
                logger.warning("costs: spreading %s's plan failed", sid, exc_info=True)


# ── 4. billing APIs ──────────────────────────────────────────────────────

def daily_from_cumulative(store: CostStore, service: str, since_ts: float) -> None:
    """Billing rows from a cumulative "spent so far" counter (``used_usd`` snapshots):
    a day's spend is its last reading minus the previous day's last reading. A gap of
    more than a day is skipped — that delta would span several days — so those days
    fall back to the estimate."""
    snaps = [s for s in store.snapshots(service, since_ts - 2 * 86400)
             if s.get("used_usd") is not None]
    last_by_day: Dict[str, float] = {}
    for s in snaps:
        last_by_day[day_of(s["ts"])] = float(s["used_usd"])
    days = sorted(last_by_day)
    for prev, day in zip(days, days[1:]):
        if (day_start_ts(day) - day_start_ts(prev)) / 86400 > 1.5:
            continue
        spent = max(last_by_day[day] - last_by_day[prev], 0.0)
        store.upsert_daily(service, day, "billing", round(spent, 6), {"from_balance": True})


def fetch_anthropic(ctx: Context) -> bool:
    key = ctx.env("ANTHROPIC_ADMIN_KEY")
    if not key:
        return False
    first = not ctx.store.get_meta("anthropic_billing_backfilled")
    start = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0) \
        - timedelta(days=(180 if first else RECENT_DAYS))
    headers = {"x-api-key": key, "anthropic-version": "2023-06-01"}
    base: List[tuple] = [("starting_at", start.strftime("%Y-%m-%dT%H:%M:%SZ")),
                         ("group_by[]", "description"), ("limit", "31")]
    per_day: Dict[str, Dict[str, Any]] = {}
    page: Optional[str] = None
    for _ in range(20):
        try:
            data = ctx.get_json("https://api.anthropic.com/v1/organizations/cost_report",
                                headers=headers, params=base + ([("page", page)] if page else [])) or {}
        except ProviderError as exc:
            if exc.status in (401, 403):
                raise ProviderError(
                    "This key can't read Anthropic billing. It needs an Admin key (starts with "
                    "sk-ant-admin, Console → Settings → Admin keys); individual accounts must set "
                    "up an organization first (Console → Settings → Organization).",
                    status=exc.status) from exc
            raise
        for bucket in data.get("data") or []:
            day = _utc_day(bucket.get("starting_at"))
            d = per_day.setdefault(day, {"amount": 0.0, "by_item": {}})
            for r in bucket.get("results") or []:
                usd = (_num(r.get("amount")) or 0.0) / 100.0  # cents, as a decimal string
                d["amount"] += usd
                label = r.get("model") or r.get("description") or r.get("cost_type") or "other"
                d["by_item"][label] = round(d["by_item"].get(label, 0.0) + usd, 6)
        page = data.get("next_page") if data.get("has_more") else None
        if not page:
            break
    for day, d in per_day.items():
        ctx.store.upsert_daily("anthropic", day, "billing", round(d["amount"], 6),
                               {"by_item": d["by_item"]})
    ctx.store.set_meta("anthropic_billing_backfilled", "1")
    return True


def fetch_openrouter(ctx: Context) -> bool:
    key = ctx.env("OPENROUTER_API_KEY")
    mgmt = ctx.env("OPENROUTER_MANAGEMENT_KEY")
    if not key and not mgmt:
        return False
    store = ctx.store
    balance = limit = used = None
    raw: Dict[str, Any] = {}
    if key:
        data = (ctx.get_json("https://openrouter.ai/api/v1/key",
                             headers={"Authorization": f"Bearer {key}"}) or {}).get("data") or {}
        used = _num(data.get("usage"))
        limit = _num(data.get("limit"))
        balance = _num(data.get("limit_remaining"))
        raw = {k: data.get(k) for k in ("usage", "usage_daily", "usage_monthly", "limit",
                                        "limit_remaining", "limit_reset", "is_free_tier")}
    if mgmt:
        auth = {"Authorization": f"Bearer {mgmt}"}
        credits = (ctx.get_json("https://openrouter.ai/api/v1/credits", headers=auth) or {}).get("data") or {}
        total, spent = _num(credits.get("total_credits")), _num(credits.get("total_usage"))
        if total is not None and spent is not None:
            balance, used, limit = total - spent, spent, total
            raw["total_credits"], raw["total_usage"] = total, spent
        activity = (ctx.get_json("https://openrouter.ai/api/v1/activity", headers=auth) or {}).get("data") or []
        per_day: Dict[str, Dict[str, Any]] = {}
        for r in activity:
            d = per_day.setdefault(_utc_day(r.get("date")), {"amount": 0.0, "requests": 0, "models": {}})
            usd = _num(r.get("usage")) or 0.0
            d["amount"] += usd
            d["requests"] += int(r.get("requests") or 0)
            model = r.get("model") or "unknown"
            d["models"][model] = round(d["models"].get(model, 0.0) + usd, 6)
        for day, d in per_day.items():
            if day:
                store.upsert_daily("openrouter", day, "billing", round(d.pop("amount"), 6), d)
    store.add_snapshot("openrouter", balance_usd=balance, used_usd=used, limit_usd=limit, raw=raw)
    if not mgmt:
        daily_from_cumulative(store, "openrouter", time.time() - RECENT_DAYS * 86400)
        if raw.get("usage_daily") is not None:
            # Today so far, straight from the key (UTC day) — beats a one-sided delta.
            store.upsert_daily("openrouter", datetime.now(timezone.utc).strftime("%Y-%m-%d"),
                               "billing", round(_num(raw["usage_daily"]) or 0.0, 6),
                               {"key_usage_daily": True})
    return True


def fetch_ollama(ctx: Context) -> bool:
    key = ctx.env("OLLAMA_API_KEY")
    if not key:
        return False
    auth = {"Authorization": f"Bearer {key}"}
    bal = ctx.get_json("https://ollama.com/api/balance", headers=auth) or {}
    included = bal.get("included") or {}
    allowance = _num(included.get("allowance_usd"))
    left = _num(included.get("balance_usd"))
    ctx.store.add_snapshot(
        "ollama-cloud", balance_usd=left, limit_usd=allowance,
        used_usd=(allowance - left) if allowance is not None and left is not None else None,
        raw={"period": included.get("period"),
             "purchased_usd": _num((bal.get("purchased") or {}).get("balance_usd")),
             "session": included.get("session"), "weekly": included.get("weekly")})
    usage = ctx.get_json("https://ollama.com/api/usage", headers=auth, params={"range": "30d"}) or {}
    for b in usage.get("buckets") or []:
        day = _utc_day(b.get("from"))
        if not day:
            continue
        # Plan value used that day: informational for a subscription, not extra spend.
        ctx.store.upsert_daily("ollama-cloud", day, "billing", round(_num(b.get("usage_usd")) or 0.0, 6),
                               {"plan_usage": True, "requests": b.get("request_count"),
                                "input_tokens": b.get("input_tokens"),
                                "cached_input_tokens": b.get("cached_input_tokens"),
                                "output_tokens": b.get("output_tokens")})
    return True


def fetch_soniox(ctx: Context) -> bool:
    key = ctx.env("SONIOX_ORG_API_KEY")
    if not key:
        return False
    auth = {"Authorization": f"Bearer {key}"}
    now = datetime.now(timezone.utc)
    summary = ctx.get_json(
        "https://api.soniox.com/v1/organization/usage/summary", headers=auth,
        params={"start_time": (now - timedelta(days=RECENT_DAYS)).strftime("%Y-%m-%dT00:00:00Z"),
                "end_time": (now + timedelta(days=1)).strftime("%Y-%m-%dT00:00:00Z")}) or {}
    total = summary.get("total") or {}
    days, costs, durations = total.get("days") or [], total.get("cost_usd") or [], total.get("duration_ms") or []
    for i, day in enumerate(days):
        amount = _num(costs[i]) if i < len(costs) else None
        if amount is None:
            continue
        units = {}
        if i < len(durations) and _num(durations[i]) is not None:
            units["audio_seconds"] = round((_num(durations[i]) or 0) / 1000, 1)
        ctx.store.upsert_daily("soniox", _utc_day(day), "billing", round(amount, 6), units)
    bal = ctx.get_json("https://api.soniox.com/v1/organization/balance", headers=auth) or {}
    ctx.store.add_snapshot("soniox", balance_usd=_num(bal.get("available_balance_usd")),
                           used_usd=_num(bal.get("used_balance_usd")),
                           raw={k: bal.get(k) for k in ("free_balance_usd", "balance_exhausted",
                                                        "autopay_enabled")})
    return True


def fetch_fish_audio(ctx: Context) -> bool:
    key = fish_audio_key(ctx.config, ctx.env_file)
    if not key:
        return False
    data = ctx.get_json("https://api.fish.audio/wallet/self/api-credit",
                        headers={"Authorization": f"Bearer {key}"}) or {}
    credit = _num(data.get("credit"))
    topped = _num(data.get("cumulative_top_up"))
    used = (topped - credit) if credit is not None and topped is not None else None
    ctx.store.add_snapshot("fish-audio", balance_usd=credit, used_usd=used,
                           raw={"cumulative_top_up": topped})
    daily_from_cumulative(ctx.store, "fish-audio", time.time() - RECENT_DAYS * 86400)
    return True


def fetch_openai(ctx: Context) -> bool:
    key = ctx.env("OPENAI_ADMIN_KEY")
    if not key:
        return False
    start = int((datetime.now(timezone.utc) - timedelta(days=RECENT_DAYS)).timestamp())
    page: Optional[str] = None
    per_day: Dict[str, float] = defaultdict(float)
    for _ in range(10):
        params: Dict[str, Any] = {"start_time": start, "bucket_width": "1d", "limit": 180}
        if page:
            params["page"] = page
        data = ctx.get_json("https://api.openai.com/v1/organization/costs",
                            headers={"Authorization": f"Bearer {key}"}, params=params) or {}
        for b in data.get("data") or []:
            day = datetime.fromtimestamp(int(b.get("start_time") or 0), timezone.utc).strftime("%Y-%m-%d")
            for r in b.get("results") or []:
                per_day[day] += _num((r.get("amount") or {}).get("value")) or 0.0
        page = data.get("next_page") if data.get("has_more") else None
        if not page:
            break
    for day, amount in per_day.items():
        ctx.store.upsert_daily("openai", day, "billing", round(amount, 6))
    return True


def fetch_elevenlabs(ctx: Context) -> bool:
    key = ctx.env("ELEVENLABS_API_KEY")
    if not key:
        return False
    data = ctx.get_json("https://api.elevenlabs.io/v1/user/subscription",
                        headers={"xi-api-key": key}) or {}
    ctx.store.add_snapshot("elevenlabs", raw={
        "characters_used": data.get("character_count"),
        "characters_limit": data.get("character_limit"),
        "resets_at": data.get("next_character_count_reset_unix"),
        "tier": data.get("tier")})
    return True


def fetch_browserbase(ctx: Context) -> bool:
    key, project = ctx.env("BROWSERBASE_API_KEY"), ctx.env("BROWSERBASE_PROJECT_ID")
    if not key or not project:
        return False
    data = ctx.get_json(f"https://api.browserbase.com/v1/projects/{project}/usage",
                        headers={"X-BB-API-Key": key}) or {}
    ctx.store.add_snapshot("browserbase", raw={"browser_minutes": data.get("browserMinutes"),
                                               "proxy_bytes": data.get("proxyBytes")})
    return True


FETCHERS: Dict[str, Callable[[Context], bool]] = {
    "anthropic": fetch_anthropic,
    "openrouter": fetch_openrouter,
    "ollama-cloud": fetch_ollama,
    "soniox": fetch_soniox,
    "fish-audio": fetch_fish_audio,
    "openai": fetch_openai,
    "elevenlabs": fetch_elevenlabs,
    "browserbase": fetch_browserbase,
}


# ── the run ──────────────────────────────────────────────────────────────

def collect(service: Optional[str] = None, *, store: Optional[CostStore] = None,
            http_get: Optional[Callable[..., Any]] = None,
            state_db: Optional[Path] = None) -> Dict[str, Any]:
    """One pass (every service, or only ``service``'s billing API + subscriptions).
    Returns ``{"ok": True, "services": {id: {"ok": bool, "error"?: str}}, "took_s": float}``."""
    started = time.time()
    store = store or get_store()
    results: Dict[str, Dict[str, Any]] = {}
    with _RUN_LOCK:
        ctx = Context(store, http_get=http_get)
        if service is None:
            first = not store.get_meta("llm_backfilled")
            # From local midnight: a window starting mid-day would re-price its oldest day
            # from only part of that day's calls and overwrite the full-day row.
            since = day_start_ts(day_of(started - (BACKFILL_DAYS if first else RECENT_DAYS) * 86400))
            try:
                rebuild_llm_estimates(store, since, state_db=state_db,
                                      long_cache=_long_cache(ctx.config))
                store.set_meta("llm_backfilled", str(started))
                results["_calls"] = {"ok": True}
            except Exception as exc:
                logger.warning("costs: pricing the call log failed", exc_info=True)
                results["_calls"] = {"ok": False, "error": str(exc)[:300]}
            try:
                backfill_parallel(ctx, state_db=state_db)
                rollup_meter(store, since)
                results["_meter"] = {"ok": True}
            except Exception as exc:
                logger.warning("costs: meter rollup failed", exc_info=True)
                results["_meter"] = {"ok": False, "error": str(exc)[:300]}
        try:
            spread_subscriptions(store)
        except Exception:
            logger.warning("costs: spreading subscriptions failed", exc_info=True)

        for sid in ([service] if service else list(FETCHERS)):
            fetch = FETCHERS.get(sid)
            if fetch is None:
                continue
            try:
                if fetch(ctx):
                    store.mark_sync(sid, ok=True)
                    results[sid] = {"ok": True}
                elif service:
                    # Asked for by name (a connect) but its keys aren't all there: never
                    # let that read as a successful sync.
                    results[sid] = {"ok": False, "error": "Not connected yet: a key or ID is still missing."}
            except Exception as exc:
                msg = str(exc)[:300] or exc.__class__.__name__
                logger.info("costs: %s billing fetch failed: %s", sid, msg)
                store.mark_sync(sid, ok=False, error=msg)
                results[sid] = {"ok": False, "error": msg}
        store.set_meta("last_run", str(time.time()))
    return {"ok": True, "services": results, "took_s": round(time.time() - started, 2)}


def last_run_ts(store: Optional[CostStore] = None) -> Optional[float]:
    return _num((store or get_store()).get_meta("last_run"))
