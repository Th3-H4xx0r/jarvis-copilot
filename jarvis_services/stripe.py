"""Stripe: balance and the latest charges every 30 s; payouts, subscriptions and an
estimated MRR up close. Read only: nothing here moves money.

after coucou (github.com/Louis-CFM/coucou, MIT)
"""
from __future__ import annotations

import base64
import time
from typing import Any, Optional

from jarvis_services.base import (
    ERROR, IDLE, INFO, OK, WARNING, Detail, Event, HttpError, Item, Section, Service, Snapshot,
    Stat, call_json, parse_date,
)

API = "https://api.stripe.com/v1"
ENV = "SERVICES_STRIPE_API_KEY"

# docs.stripe.com/currencies#zero-decimal (UGX and ISK stay ×100, as Stripe does).
_ZERO_DECIMAL = {"bif", "clp", "djf", "gnf", "jpy", "kmf", "krw", "mga", "pyg", "rwf",
                 "vnd", "vuv", "xaf", "xof", "xpf"}


def money(cents: int, currency: str) -> str:
    code = (currency or "").upper()
    if (currency or "").lower() in _ZERO_DECIMAL:
        return f"{int(cents):,} {code}"
    return f"{cents / 100:,.2f} {code}"


def _parse_charge(c: dict) -> Optional[dict]:
    if not isinstance(c, dict):
        return None
    cid, amount, currency, status = c.get("id"), c.get("amount"), c.get("currency"), c.get("status")
    if not (isinstance(cid, str) and isinstance(amount, int) and isinstance(currency, str)
            and isinstance(status, str)):
        return None
    billing = c.get("billing_details") if isinstance(c.get("billing_details"), dict) else {}
    return {"id": cid, "amount": amount, "currency": currency, "status": status,
            "created": parse_date(c.get("created")) or 0.0,
            "description": c.get("description") or billing.get("name")}


class StripeService(Service):
    id = "stripe"
    display_name = "Stripe"
    interval = 30
    first_delay = 6
    secrets = {"api_key": ENV}
    secret_labels = {"api_key": "Secret key (sk_live_… or rk_live_…)"}
    hints = {403: "That's a publishable key. Use the secret key (sk_live_… not pk_live_…)."}

    def fetch(self, http, cfg, prev=None, now=None) -> Snapshot:
        now = now or time.time()
        creds = base64.b64encode(f"{cfg.secret(ENV)}:".encode()).decode()
        headers = {"Authorization": f"Basic {creds}"}
        balance = call_json(http, "GET", f"{API}/balance", headers=headers, timeout=10)
        buckets = [b for b in (balance.get("available") or []) + (balance.get("pending") or [])
                   if isinstance(b, dict)]
        currency = next((b["currency"] for b in buckets if isinstance(b.get("currency"), str)), "eur")
        amount = sum(b["amount"] for b in buckets if isinstance(b.get("amount"), int))
        try:
            raw = call_json(http, "GET", f"{API}/charges?limit=3", headers=headers, timeout=10)
            charges = [c for c in map(_parse_charge, raw.get("data") or []) if c]
        except HttpError:
            charges = list((prev.state or {}).get("charges", [])) if prev else []
        return self._snapshot(amount, currency, charges, now)

    def _snapshot(self, balance: int, currency: str, charges: list, now: float) -> Snapshot:
        latest = charges[0] if charges else None
        if latest:
            what = f" · {latest['description']}" if latest["description"] else ""
            paid = money(latest["amount"], latest["currency"])
            if latest["status"] == "succeeded":
                tone = OK if now - latest["created"] < 86_400 else IDLE
                reason = f"Last payment received: {paid}{what}"
            elif latest["status"] == "failed":
                tone, reason = ERROR, f"Last payment failed: {paid}{what}"
            else:
                tone, reason = WARNING, f"Last payment pending: {paid}{what}"
        else:
            tone, reason = IDLE, "No payment yet"
        items = [Item(money(c["amount"], c["currency"]),
                      " · ".join(x for x in (c["description"], c["status"]) if x),
                      tone=OK if c["status"] == "succeeded" else ERROR if c["status"] == "failed" else WARNING,
                      date=c["created"])
                 for c in charges[:10]]
        return Snapshot(self.id, self.display_name, tone, f"Balance {money(balance, currency)}", reason,
                        [Section("Recent payments", items)] if items else [], now,
                        state={"charges": charges, "newest": latest})

    def events(self, old_state, new_state) -> list:
        if not old_state or not new_state:
            return []
        new, old = new_state.get("newest"), old_state.get("newest")
        if not new or (old and old["id"] == new["id"]) or new["status"] != "succeeded":
            return []
        what = f" · {new['description']}" if new["description"] else ""
        return [Event("payment_received", "Payment received",
                      f"{money(new['amount'], new['currency'])}{what}", {"charge": new["id"]})]

    # ── detail ──

    def detail(self, http, cfg, now=None) -> Detail:
        now = now or time.time()
        headers = {"Authorization": f"Bearer {cfg.secret(ENV)}"}
        balance = call_json(http, "GET", f"{API}/balance", headers=headers)
        available_list = [b for b in balance.get("available") or [] if isinstance(b, dict)]
        pending_list = [b for b in balance.get("pending") or [] if isinstance(b, dict)]
        first = (available_list or pending_list or [{}])[0]
        currency = str(first.get("currency") or "eur").lower()

        def amount(entries: list) -> int:
            return next((b.get("amount") or 0 for b in entries
                         if str(b.get("currency") or "").lower() == currency), 0)

        def listing(path: str) -> tuple[list, dict, Optional[str]]:
            try:
                body = call_json(http, "GET", f"{API}/{path}", headers=headers)
                return [x for x in body.get("data") or [] if isinstance(x, dict)], body, None
            except HttpError as e:
                return [], {}, self.describe(e)

        charges, _, charges_error = listing("charges?limit=15")
        payouts, _, payouts_error = listing("payouts?limit=5")
        subs, more_subs, subs_error = self._subscriptions(listing)
        monthly, mrr_currency = _mrr(subs, currency)

        sections = [Section("Payments", [self._charge_item(c, currency) for c in charges], charges_error)]
        if payouts or payouts_error:
            sections.append(Section("Payouts", [
                Item(money(p.get("amount") or 0, p.get("currency") or currency), "Arrives",
                     tone=ERROR if p.get("status") == "failed" else INFO,
                     date=parse_date(p.get("arrival_date")),
                     badge=str(p.get("status") or "").replace("_", " ").title() or None)
                for p in payouts], payouts_error))
        if subs_error:
            sections.append(Section("Subscriptions", [], subs_error))
        count = "—" if subs_error else (f"{len(subs)}+" if more_subs else f"{len(subs)}")
        mrr = "—" if subs_error else money(int(round(monthly)), mrr_currency)
        return Detail(self.id, self.display_name,
                      [Stat("Available", money(amount(available_list), currency), OK),
                       Stat("Pending", money(amount(pending_list), currency)),
                       Stat("Subscriptions", count, INFO),
                       Stat("Est. MRR", mrr, INFO)],
                      sections, now)

    @staticmethod
    def _subscriptions(listing) -> tuple[list, bool, Optional[str]]:
        """Active subscriptions, every page (up to 1 000)."""
        subs: list = []
        more = False
        cursor = None
        for _ in range(10):
            page, body, error = listing("subscriptions?status=active&limit=100"
                                        + (f"&starting_after={cursor}" if cursor else ""))
            if error:
                return subs, False, error
            subs += page
            more = bool(body.get("has_more"))
            cursor = subs[-1].get("id") if subs else None
            if not more or not cursor:
                break
        return subs, more, None

    @staticmethod
    def _charge_item(c: dict, currency: str) -> Item:
        status = str(c.get("status") or "")
        refunded = bool(c.get("refunded"))
        partly = not refunded and (c.get("amount_refunded") or 0) > 0
        uncaptured = not refunded and status == "succeeded" and c.get("captured") is False
        billing = c.get("billing_details") if isinstance(c.get("billing_details"), dict) else {}
        who = billing.get("name") or c.get("receipt_email") or c.get("description") or ""
        tone = (IDLE if refunded else WARNING if (uncaptured or partly)
                else OK if status == "succeeded" else ERROR if status == "failed" else WARNING)
        badge = ("Refunded" if refunded else "Uncaptured" if uncaptured
                 else "Partly refunded" if partly else status.capitalize())
        return Item(money(c.get("amount") or 0, c.get("currency") or currency), who, tone=tone,
                    date=parse_date(c.get("created")), badge=badge)


def _mrr(subs: list, currency: str) -> tuple[float, str]:
    """Estimated monthly revenue, one total per currency. Metered and tiered prices
    have no fixed amount per period, and discounts aren't applied."""
    by_currency: dict = {}
    for sub in subs:
        sub_currency = str(sub.get("currency") or "").lower() or None
        items = (sub.get("items") or {}).get("data") or [] if isinstance(sub.get("items"), dict) else []
        for item in items:
            price: Any = item.get("price") or {}
            recurring = price.get("recurring") or {}
            if recurring.get("usage_type") == "metered" or price.get("billing_scheme") == "tiered":
                continue
            per_unit = price.get("unit_amount")
            if not isinstance(per_unit, (int, float)):
                try:
                    per_unit = float(price.get("unit_amount_decimal") or 0)
                except (TypeError, ValueError):
                    per_unit = 0.0
            unit = float(per_unit) * float(item.get("quantity") or 1)
            count = float(recurring.get("interval_count") or 1)
            interval = recurring.get("interval")
            per_month = (unit / (12 * count) if interval == "year" else unit * 4.345 / count
                         if interval == "week" else unit * 30.4 / count if interval == "day"
                         else unit / count)
            key = sub_currency or str(price.get("currency") or currency).lower()
            by_currency[key] = by_currency.get(key, 0.0) + per_month
    if currency in by_currency:
        return by_currency[currency], currency
    if by_currency:
        key = max(by_currency, key=by_currency.get)
        return by_currency[key], key
    return 0.0, currency
