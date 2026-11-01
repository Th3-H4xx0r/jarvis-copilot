"""What Jarvis and the services around it are costing — the Insights → Costs data, for chat.

Read-only apart from ``refresh`` (re-runs the collector: billing APIs + Jarvis's own call
log, no model calls). Keys and plan prices are set by the user on the Costs tab, never
here, so the model never handles a secret.
"""
from __future__ import annotations

import json
from typing import Any, Dict

from tools.registry import registry

_SCHEMA = {
    "name": "cost_insights",
    "description": (
        "What the user's AI models, APIs and subscriptions cost, per service and per day, "
        "with history: Anthropic, OpenRouter, Celeris, Ollama, Parallel search, Soniox, "
        "Fish Audio, plans like Claude/ChatGPT, hosting and custom subscriptions. Amounts "
        "come from provider billing APIs where connected, otherwise Jarvis's own usage × "
        "list price (marked estimated)."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "action": {
                "type": "string",
                "enum": ["summary", "service", "services", "refresh"],
                "description": (
                    "summary: totals (period, month to date, projected month, vs previous "
                    "period), budget, per-service spend and the daily trend. service: one "
                    "service's daily breakdown, models and balance. services: every service "
                    "with its status and how it's priced. refresh: fetch fresh billing data "
                    "now, then return the summary."
                ),
            },
            "days": {"type": "integer", "description": "Period length in days (1-365, default 30)."},
            "service_id": {"type": "string", "description": "For action=service, e.g. anthropic, parallel."},
        },
        "required": ["action"],
    },
}


def _money(x: Any) -> Any:
    return None if x is None else round(float(x), 2)


def _service_line(c: Dict[str, Any]) -> Dict[str, Any]:
    line = {
        "id": c["id"], "name": c["name"], "status": c["status"],
        "period_usd": _money(c.get("period_total")),
        "month_to_date_usd": _money(c.get("month_to_date")),
        "priced_from": c.get("sources") or [],
    }
    if c.get("balance_usd") is not None:
        line["balance_usd"] = _money(c["balance_usd"])
    if c.get("limit_usd") is not None:
        line["limit_usd"] = _money(c["limit_usd"])
    if c.get("subscription"):
        line["plan"] = c["subscription"]
    units = c.get("units") or {}
    for k in ("calls", "searches", "audio_seconds", "api_equiv_usd", "from_history"):
        if units.get(k):
            line[k] = units[k]
    if c.get("error"):
        line["error"] = c["error"]
    return line


def _summary(days: int) -> Dict[str, Any]:
    from agent.costs.report import overview
    o = overview(days)
    daily = o["daily"]
    # Week-sized buckets keep a 90-day answer small.
    step = 1 if len(daily) <= 31 else 7
    trend = []
    for i in range(0, len(daily), step):
        chunk = daily[i:i + step]
        trend.append({"from": chunk[0]["day"], "to": chunk[-1]["day"],
                      "usd": _money(sum(d["total"] or 0 for d in chunk))})
    totals = dict(o["totals"])
    by_source = {k: _money(v) for k, v in (totals.pop("by_source", None) or {}).items()}
    return {
        "ok": True,
        "period": {"days": o["days"], "start": o["start"], "end": o["end"]},
        "totals_usd": {k: _money(v) for k, v in totals.items()},
        "by_source_usd": by_source,
        "budget": o["budget"],
        "services": [_service_line(c) for c in o["services"]
                     if c.get("period_total") or c["status"] != "free"],
        "trend": trend,
        "notes": ("estimated = Jarvis's own count × list price; subscription = plan price "
                  "spread per day; needs_price = the user hasn't entered the plan price "
                  "(Insights → Costs)."),
    }


def cost_insights(args: Dict[str, Any]) -> str:
    action = str(args.get("action") or "summary")
    try:
        days = min(max(int(args.get("days") or 30), 1), 365)
    except (TypeError, ValueError):
        days = 30
    try:
        if action == "summary":
            return json.dumps(_summary(days), ensure_ascii=False)
        if action == "refresh":
            from agent.costs.collector import collect
            run = collect()
            failed = {k: v.get("error") for k, v in run.get("services", {}).items() if not v.get("ok")}
            out = _summary(days)
            if failed:
                out["refresh_failures"] = failed
            return json.dumps(out, ensure_ascii=False)
        if action == "services":
            from agent.costs.report import overview
            o = overview(days)
            return json.dumps({
                "ok": True,
                "services": [_service_line(c) for c in o["services"]],
                "available_to_connect": [{"id": c["id"], "name": c["name"], "how": c.get("help")}
                                         for c in o["available"]],
            }, ensure_ascii=False)
        if action == "service":
            from agent.costs.report import service_detail
            sid = str(args.get("service_id") or "").strip()
            detail = service_detail(sid, days) if sid else None
            if detail is None:
                return json.dumps({"ok": False, "error": f"unknown service {sid!r}; use action=services"})
            daily = []
            for r in detail["daily"]:
                if not (r.get("effective") or r.get("estimate")):
                    continue
                row = {"day": r["day"], "usd": _money(r["effective"]), "source": r["source"]}
                if r.get("billing") is not None:
                    row["billing_usd"] = _money(r["billing"])
                if r.get("estimate") is not None:
                    row["estimate_usd"] = _money(r["estimate"])
                daily.append(row)
            return json.dumps({
                "ok": True,
                "service": _service_line(detail["service"]),
                "how_priced": detail["service"].get("help"),
                "daily": daily,
                "models": [{"model": m["model"], "calls": m["calls"], "usd": _money(m["cost_usd"])}
                           for m in detail["models"][:15]],
                "billing_items": detail["billing_items"][:15],
            }, ensure_ascii=False)
    except Exception as exc:
        return json.dumps({"ok": False, "error": f"{type(exc).__name__}: {exc}"})
    return json.dumps({"ok": False, "error": f"unknown action {action!r}"})


registry.register(
    name="cost_insights",
    toolset="costs",
    schema=_SCHEMA,
    handler=lambda args, **_kw: cost_insights(args or {}),
    emoji="💸",
)
