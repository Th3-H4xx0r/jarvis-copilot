"""Read views over ``costs.db``: the overview, one service's detail, the service list.

Shared by the HTTP API (web + iPhone) and the ``cost_insights`` tool, so the chat and the
screen always agree.

What a day "costs" for a service (``effective``):

- ``usage`` services: the billing amount when the provider reported one for that day,
  else Jarvis's estimate.
- ``subscription`` services: the plan's share of that day. Billing/estimate rows there
  describe the usage the plan covered, never extra spend.
- ``free`` services: nothing.
"""
from __future__ import annotations

import calendar
import time
from collections import defaultdict
from typing import Any, Dict, List, Optional

from agent.costs import catalog
from agent.costs.collector import FETCHERS, Context, config_value, fish_audio_key, last_run_ts
from agent.costs.store import CostStore, day_of, days_back, get_store

# The billing-API keys each fetcher needs (any one is enough).
_BILLING_KEYS = {
    "anthropic": ["ANTHROPIC_ADMIN_KEY"],
    "openrouter": ["OPENROUTER_API_KEY", "OPENROUTER_MANAGEMENT_KEY"],
    "ollama-cloud": ["OLLAMA_API_KEY"],
    "soniox": ["SONIOX_ORG_API_KEY"],
    "openai": ["OPENAI_ADMIN_KEY"],
    "elevenlabs": ["ELEVENLABS_API_KEY"],
    "browserbase": ["BROWSERBASE_API_KEY"],
}


def _r(x: Optional[float], places: int = 4) -> Optional[float]:
    return None if x is None else round(float(x), places)


def _entry(sid: str, configs: Dict[str, Dict[str, Any]]) -> Dict[str, Any]:
    return catalog.get(sid) or catalog.adhoc_service(sid, configs.get(sid))


def _detected(entry: Dict[str, Any], ctx: Context) -> bool:
    if entry.get("always"):
        return True
    if any(ctx.env(name) for name in entry.get("detect_env", [])):
        return True
    if entry["id"] == "fish-audio":
        return bool(fish_audio_key(ctx.config, ctx.env_file))
    path = entry.get("detect_config")
    return bool(path and str(config_value(ctx.config, path) or "").strip())


def _key_connected(entry: Dict[str, Any], ctx: Context) -> bool:
    """Whether the billing API this service's fetcher reads has its key."""
    if entry["id"] == "fish-audio":
        return bool(fish_audio_key(ctx.config, ctx.env_file))
    if entry["id"] == "browserbase":  # its usage endpoint needs both
        return bool(ctx.env("BROWSERBASE_API_KEY") and ctx.env("BROWSERBASE_PROJECT_ID"))
    return any(ctx.env(n) for n in _BILLING_KEYS.get(entry["id"], []))


def _field_states(entry: Dict[str, Any], ctx: Context) -> List[Dict[str, Any]]:
    specs = {s["key"]: s for s in entry.get("fields", [])}
    out = []
    for f in catalog.public_fields(entry):
        env = specs.get(f["key"], {}).get("env")
        out.append(dict(f, is_set=bool(env and ctx.env(env))))
    return out


class _Cells:
    """``(service, day) → {source: amount}`` plus the units, for one query window."""

    def __init__(self, rows: List[Dict[str, Any]]) -> None:
        self.amount: Dict[tuple, Dict[str, float]] = defaultdict(dict)
        self.units: Dict[tuple, Dict[str, Dict[str, Any]]] = defaultdict(dict)
        self.services: set = set()
        for r in rows:
            key = (r["service"], r["day"])
            self.amount[key][r["source"]] = r["amount_usd"]
            self.units[key][r["source"]] = r["units"]
            self.services.add(r["service"])

    def effective(self, sid: str, day: str, kind: str) -> float:
        c = self.amount.get((sid, day))
        if not c or kind == "free":
            return 0.0
        total = c.get("subscription", 0.0)
        if kind == "usage":
            total += c["billing"] if "billing" in c else c.get("estimate", 0.0)
        return total

    def source_used(self, sid: str, day: str, kind: str) -> Optional[str]:
        c = self.amount.get((sid, day)) or {}
        if kind == "subscription":
            return "subscription" if "subscription" in c else None
        if kind == "usage":
            if "billing" in c:
                return "billing"
            if "estimate" in c:
                return "estimate"
        return None


_COUNTABLE = ("calls", "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens",
              "searches", "audio_seconds", "bytes", "requests", "api_equiv_usd", "unpriced_calls",
              "cached_input_tokens")


def _sum_units(units_list: List[Dict[str, Any]]) -> Dict[str, Any]:
    """Add up the countable parts of a service's units over several days."""
    out: Dict[str, Any] = {}
    for u in units_list:
        for k in _COUNTABLE:
            v = u.get(k)
            if isinstance(v, (int, float)) and not isinstance(v, bool):
                out[k] = out.get(k, 0) + v
        if u.get("from_history"):
            out["from_history"] = True
    for k in ("api_equiv_usd", "audio_seconds"):
        if k in out:
            out[k] = round(out[k], 4)
    return out


def _status(entry: Dict[str, Any], cfg: Dict[str, Any], sync: Dict[str, Any],
            key_connected: bool) -> str:
    kind = entry.get("kind")
    if kind == "free":
        return "free"
    failing = bool(sync.get("last_error")) and key_connected and entry["id"] in FETCHERS
    if kind == "subscription":
        if failing:
            return "error"
        return "subscription" if cfg.get("amount_usd") is not None else "needs_price"
    if failing:
        return "error"
    return "billing" if key_connected and entry["id"] in FETCHERS else "estimated"


def _card(entry: Dict[str, Any], *, cells: _Cells, period: List[str], month: List[str],
          configs: Dict[str, Dict[str, Any]], syncs: Dict[str, Dict[str, Any]],
          ctx: Context, store: CostStore) -> Dict[str, Any]:
    sid, kind = entry["id"], entry.get("kind", "usage")
    cfg = configs.get(sid, {})
    sync = syncs.get(sid, {})
    connected = _key_connected(entry, ctx)
    spark = [_r(cells.effective(sid, d, kind)) or 0.0 for d in period]
    sources = sorted({cells.source_used(sid, d, kind) for d in period} - {None})
    estimate_total = sum((cells.amount.get((sid, d)) or {}).get("estimate", 0.0) for d in period)
    billing_total = sum((cells.amount.get((sid, d)) or {}).get("billing", 0.0) for d in period)
    units = _sum_units([u for d in period for u in (cells.units.get((sid, d)) or {}).values()])
    snap = store.last_snapshot(sid) or {}
    return {
        "id": sid,
        "name": entry.get("name", sid),
        "category": entry.get("category", "Other"),
        "kind": kind,
        "custom": bool(entry.get("custom")),
        "status": _status(entry, cfg, sync, connected),
        "detected": _detected(entry, ctx) or sid in cells.services or bool(cfg.get("amount_usd") is not None),
        "billing_connected": connected and sid in FETCHERS,
        "period_total": _r(sum(spark)),
        "month_to_date": _r(sum(cells.effective(sid, d, kind) for d in month)),
        "sources": sources,
        "estimate_total": _r(estimate_total) if kind == "usage" else None,
        "billing_total": _r(billing_total) if kind == "usage" and "billing" in sources else None,
        "plan_usage_usd": _r(billing_total) if kind == "subscription" and billing_total else None,
        "units": units,
        "spark": spark,
        "balance_usd": _r(snap.get("balance_usd")),
        "limit_usd": _r(snap.get("limit_usd")),
        "balance_at": snap.get("ts"),
        "last_synced": sync.get("last_ok_ts"),
        "error": sync.get("last_error"),
        "subscription": ({"amount_usd": cfg.get("amount_usd"), "interval": cfg.get("interval", "month"),
                          "plan": cfg.get("plan"), "since": cfg.get("since")}
                         if cfg.get("amount_usd") is not None else None),
        "suggested_plans": entry.get("suggested_plans", []),
        "fields": _field_states(entry, ctx),
        "url": entry.get("url"),
        "help": entry.get("help"),
    }


def _period_days(days: int, now: float) -> List[str]:
    return days_back(max(1, min(int(days), 365)), now=now)


def _month_days(now: float) -> List[str]:
    today = day_of(now)
    return [f"{today[:8]}{d:02d}" for d in range(1, int(today[8:10]) + 1)]


def _service_ids(cells: _Cells, configs: Dict[str, Dict[str, Any]]) -> List[str]:
    ids = [s["id"] for s in catalog.SERVICES]
    for extra in sorted(cells.services | set(configs)):
        if extra not in ids:
            ids.append(extra)
    return ids


def overview(days: int = 30, *, store: Optional[CostStore] = None,
             now: Optional[float] = None) -> Dict[str, Any]:
    store = store or get_store()
    now = time.time() if now is None else now
    period = _period_days(days, now)
    prev = days_back(len(period) * 2, now=now)[: -len(period)]
    month = _month_days(now)
    since = min([period[0], month[0]] + prev[:1])
    cells = _Cells(store.daily_rows(since))
    configs = store.all_service_configs()
    syncs = store.sync_states()
    ctx = Context(store)

    cards = [_card(_entry(sid, configs), cells=cells, period=period, month=month,
                   configs=configs, syncs=syncs, ctx=ctx, store=store)
             for sid in _service_ids(cells, configs)]
    kinds = {c["id"]: c["kind"] for c in cards}

    daily = []
    for d in period:
        by_service = {sid: _r(cells.effective(sid, d, k)) for sid, k in kinds.items()}
        by_service = {k: v for k, v in by_service.items() if v}
        daily.append({"day": d, "total": _r(sum(by_service.values())), "by_service": by_service})

    def total(span: List[str]) -> float:
        return sum(cells.effective(sid, d, k) for d in span for sid, k in kinds.items())

    by_source: Dict[str, float] = defaultdict(float)
    for d in period:
        for sid, k in kinds.items():
            src = cells.source_used(sid, d, k)
            if src:
                by_source[src] += cells.effective(sid, d, k)

    mtd = total(month)
    today = day_of(now)
    dim = calendar.monthrange(int(today[:4]), int(today[5:7]))[1]
    # Projection: the month's completed days, plus the last 7 full days' daily average for
    # every day left (today included). Dividing month-to-date by days elapsed is wild early on.
    last7 = days_back(8, now=now)[:-1]
    if since > last7[0]:
        cells_7 = _Cells(store.daily_rows(last7[0], last7[-1]))
        recent = sum(cells_7.effective(sid, d, k) for d in last7 for sid, k in kinds.items())
    else:
        recent = total(last7)
    done = month[:-1]
    projected = total(done) + recent / 7 * (dim - len(done))
    budget_raw = store.get_meta("budget_monthly_usd")
    budget = float(budget_raw) if budget_raw else None

    active = [c for c in cards if c["detected"] or c["period_total"]]
    available = [c for c in cards if c not in active and c["kind"] != "free"]
    active.sort(key=lambda c: (-(c["period_total"] or 0), c["kind"] == "free", c["name"].lower()))
    return {
        "currency": "USD",
        "days": len(period),
        "start": period[0],
        "end": period[-1],
        "generated_at": now,
        "last_run": last_run_ts(store),
        "totals": {
            "period": _r(total(period)),
            "previous_period": _r(total(prev)) if prev else None,
            "month_to_date": _r(mtd),
            "projected_month": _r(projected),
            "by_source": {k: _r(v) for k, v in by_source.items()},
        },
        "budget": {"monthly_usd": budget,
                   "used_pct": _r(mtd / budget * 100, 1) if budget else None},
        "daily": daily,
        "services": active,
        "available": available,
    }


def service_detail(service_id: str, days: int = 30, *, store: Optional[CostStore] = None,
                   now: Optional[float] = None) -> Optional[Dict[str, Any]]:
    store = store or get_store()
    now = time.time() if now is None else now
    configs = store.all_service_configs()
    if not (catalog.get(service_id) or service_id in configs
            or service_id in store.services_with_rows()):
        return None
    entry = _entry(service_id, configs)
    period = _period_days(days, now)
    month = _month_days(now)
    cells = _Cells(store.daily_rows(min(period[0], month[0]), service=service_id))
    card = _card(entry, cells=cells, period=period, month=month, configs=configs,
                 syncs=store.sync_states(), ctx=Context(store), store=store)
    kind = card["kind"]
    rows = []
    models: Dict[str, Dict[str, Any]] = {}
    items: Dict[str, float] = defaultdict(float)
    for d in period:
        c = cells.amount.get((service_id, d)) or {}
        u = cells.units.get((service_id, d)) or {}
        # Every day of the period, so a chart's axis matches the overview's.
        rows.append({"day": d, "effective": _r(cells.effective(service_id, d, kind)),
                     "billing": _r(c.get("billing")), "estimate": _r(c.get("estimate")),
                     "subscription": _r(c.get("subscription")),
                     "source": cells.source_used(service_id, d, kind),
                     "units": _sum_units(list(u.values()))})
        for name, m in ((u.get("estimate") or {}).get("models") or {}).items():
            agg = models.setdefault(name, {"model": name, "calls": 0, "tokens": 0, "cost_usd": 0.0})
            agg["calls"] += m.get("calls", 0)
            agg["tokens"] += m.get("tokens", 0)
            agg["cost_usd"] += m.get("cost_usd", 0.0)
            if m.get("unpriced"):
                agg["unpriced"] = True
        for name, usd in ((u.get("billing") or {}).get("by_item") or {}).items():
            items[name] += usd
    for m in models.values():
        m["cost_usd"] = _r(m["cost_usd"])
    return {
        "service": card,
        "days": len(period),
        "daily": rows,
        "models": sorted(models.values(), key=lambda m: -(m["cost_usd"] or 0)),
        "billing_items": [{"item": k, "cost_usd": _r(v)}
                          for k, v in sorted(items.items(), key=lambda kv: -kv[1])],
        "snapshots": [{"ts": s["ts"], "balance_usd": _r(s["balance_usd"]),
                       "used_usd": _r(s["used_usd"]), "limit_usd": _r(s["limit_usd"])}
                      for s in store.snapshots(service_id, now - len(period) * 86400)][-200:],
    }
