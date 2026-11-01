"""The non-secret Cost Insights settings: plan prices, custom subscriptions, the budget.

Secrets (billing-API keys) are not here — the webui writes them to the profile ``.env``
with the same helper Settings → Providers uses.
"""
from __future__ import annotations

import re
from typing import Any, Dict, Optional

from agent.costs import catalog
from agent.costs.collector import SPREAD_LOCK, spread_subscriptions, valid_day
from agent.costs.store import CostStore, get_store

MAX_AMOUNT = 100_000.0


class SettingsError(ValueError):
    pass


def _amount(value: Any) -> float:
    try:
        amount = float(value)
    except (TypeError, ValueError):
        raise SettingsError("Enter the price as a number, like 20 or 9.99.")
    if amount != amount or amount < 0 or amount > MAX_AMOUNT:
        raise SettingsError("That price is out of range.")
    return round(amount, 2)


def _check_plan(interval: str, since: Optional[str]) -> None:
    if interval not in ("month", "year"):
        raise SettingsError("Interval must be month or year.")
    if since and not valid_day(since):
        raise SettingsError("Start date must be a real date like 2026-06-01.")


def set_subscription(service_id: str, amount_usd: Any, *, interval: str = "month",
                     plan: Optional[str] = None, since: Optional[str] = None,
                     store: Optional[CostStore] = None) -> Dict[str, Any]:
    store = store or get_store()
    entry = catalog.get(service_id)
    cfg = store.service_config(service_id)
    if entry is None and not cfg.get("custom"):
        raise SettingsError("Unknown service.")
    if entry is not None and entry.get("kind") == "free":
        raise SettingsError("That service is free.")
    _check_plan(interval, since)
    amount = _amount(amount_usd)
    with SPREAD_LOCK:
        cfg = store.service_config(service_id)
        cfg.update({"amount_usd": amount, "interval": interval,
                    "plan": (plan or "").strip()[:60] or None, "since": since or None})
        store.set_service_config(service_id, cfg)
        spread_subscriptions(store)
    return cfg


def clear_subscription(service_id: str, *, store: Optional[CostStore] = None) -> None:
    """Remove a plan price (a custom subscription goes entirely). A pay-as-you-go
    service's history is kept."""
    store = store or get_store()
    with SPREAD_LOCK:
        cfg = store.service_config(service_id)
        store.delete_daily(service_id, "subscription")
        if cfg.get("custom"):
            store.delete_service_config(service_id)
            return
        for key in ("amount_usd", "interval", "plan", "since"):
            cfg.pop(key, None)
        if cfg:
            store.set_service_config(service_id, cfg)
        else:
            store.delete_service_config(service_id)


def _slug(name: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:40]
    return f"custom-{s or 'subscription'}"


def add_custom(name: str, amount_usd: Any, *, interval: str = "month",
               category: Optional[str] = None, since: Optional[str] = None,
               store: Optional[CostStore] = None) -> str:
    store = store or get_store()
    name = (name or "").strip()[:60]
    if not name:
        raise SettingsError("Give the subscription a name.")
    _amount(amount_usd)
    _check_plan(interval, since)  # before anything is saved: a refused add leaves no card
    existing = store.all_service_configs()
    base = sid = _slug(name)
    n = 2
    while sid in existing or catalog.get(sid):
        sid = f"{base}-{n}"
        n += 1
    store.set_service_config(sid, {"custom": True, "name": name,
                                   "category": (category or "Other").strip()[:30] or "Other"})
    set_subscription(sid, amount_usd, interval=interval, since=since, store=store)
    return sid


def set_budget(monthly_usd: Any, *, store: Optional[CostStore] = None) -> Optional[float]:
    store = store or get_store()
    if monthly_usd in (None, "", 0, "0"):
        store.set_meta("budget_monthly_usd", None)
        return None
    value = _amount(monthly_usd)
    store.set_meta("budget_monthly_usd", str(value))
    return value
