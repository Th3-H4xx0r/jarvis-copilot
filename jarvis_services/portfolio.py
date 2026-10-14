"""Portfolio: what the configured exchange accounts and public wallets hold, every
2 minutes, valued in USD from Coinbase: one exchange-rates request prices
everything Coinbase knows (fiat included), then each crypto's market adds the 24 h
change and a 7-day curve. Stablecoins nobody prices count as $1.

after coucou (github.com/Louis-CFM/coucou, MIT)
"""
from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any, Optional

from jarvis_services import exchanges, wallets
from jarvis_services.base import HttpError, Service, ServiceError, plain, call_json, describe, num, same_content

RATES_URL = "https://api.coinbase.com/v2/exchange-rates?currency=USD"
MARKET = "https://api.exchange.coinbase.com/products"
#: Cash held on an exchange: valued with the day's rate, no market data.
FIAT = {"USD", "EUR", "GBP", "CHF", "CAD", "AUD", "JPY"}
STABLECOINS = {"USDT", "USDC", "BUSD", "DAI"}


@dataclass
class Holding:
    symbol: str
    amount: float
    price: float = 0.0
    value: float = 0.0
    change_24h: Optional[float] = None
    #: Last 7 daily closes, oldest first.
    history: list = field(default_factory=list)


@dataclass
class Account:
    id: str
    kind: str            # "exchange" | "wallet"
    source: str          # exchange id or network id
    name: str
    label: str
    address: Optional[str] = None
    holdings: list = field(default_factory=list)
    total_usd: float = 0.0
    error: Optional[str] = None


@dataclass
class PortfolioBoard:
    accounts: list
    total_usd: float
    updated_at: float = 0.0
    error: Optional[str] = None
    state: Any = field(default=None, compare=False, repr=False)

    def to_dict(self) -> dict:
        return plain(self)

    def same_content(self, other) -> bool:
        return same_content(self, other)


def short_address(address: str) -> str:
    return f"{address[:6]}…{address[-4:]}" if len(address) > 12 else address


def configured_wallets(cfg) -> list:
    out = []
    for w in cfg.setting("portfolio", "wallets", []) or []:
        if isinstance(w, dict) and w.get("network") in wallets.NETWORKS and isinstance(w.get("address"), str):
            out.append({"network": w["network"], "address": w["address"].strip(),
                        "label": str(w.get("label") or "").strip()})
    return out


def exchange_creds(cfg, exchange: str) -> dict:
    return {f: cfg.secret(exchanges.env_name(exchange, f)) for f in exchanges.EXCHANGES[exchange].fields}


def configured_exchanges(cfg) -> list:
    return [ex for ex in exchanges.EXCHANGES if all(exchange_creds(cfg, ex).values())]


def fetch_prices(http, symbols) -> dict:
    """``{symbol: (usd_price, change_24h or None, 7-day closes)}``."""
    symbols = sorted(set(symbols))
    if not symbols:
        return {}
    accept = {"Accept": "application/json"}
    rates: dict = {}
    try:
        body = call_json(http, "GET", RATES_URL, headers=accept, timeout=8)
        for sym, value in ((body.get("data") or {}).get("rates") or {}).items():
            r = num(value)
            if r and r > 0:
                rates[sym.upper()] = float(f"{1 / r:.10g}")   # rates[X]: how many X one dollar buys
    except (ServiceError, AttributeError):
        pass
    result = {}
    for sym in symbols:
        if sym == "USD":
            result[sym] = (1.0, None, [])
        elif sym in rates:
            result[sym] = (rates[sym], None, [])
    for sym in symbols:
        if sym in FIAT:
            continue
        try:
            stats = call_json(http, "GET", f"{MARKET}/{sym}-USD/stats", headers=accept, timeout=8)
        except ServiceError:
            continue
        if not isinstance(stats, dict) or num(stats.get("last")) is None:
            continue
        last, open_ = num(stats["last"]), num(stats.get("open"))
        change = ((last - open_) / open_ * 100 if open_ > 0 else 0.0) if open_ is not None else None
        history: list = []
        try:
            rows = call_json(http, "GET", f"{MARKET}/{sym}-USD/candles?granularity=86400", headers=accept, timeout=8)
            if isinstance(rows, list):
                closes = [num(r[4]) for r in rows[:7] if isinstance(r, list) and len(r) > 4]
                history = [c for c in closes if c is not None][::-1]
        except ServiceError:
            pass
        result[sym] = (last, change, history)
    return result


def merge_prices(accounts: list, prices: dict) -> list:
    for account in accounts:
        for h in account.holdings:
            if h.symbol in prices:
                h.price, h.change_24h, h.history = prices[h.symbol]
            elif h.symbol in STABLECOINS:
                h.price = 1.0          # stablecoins ≈ $1
            h.value = h.amount * h.price
        account.holdings.sort(key=lambda h: h.value, reverse=True)
        account.total_usd = sum(h.value for h in account.holdings)
    return accounts


class PortfolioService(Service):
    id = "portfolio"
    display_name = "Portfolio"
    interval = 120
    first_delay = 4
    topic = "portfolio"

    def configured(self, cfg) -> bool:
        return bool(configured_exchanges(cfg) or configured_wallets(cfg))

    def fetch(self, http, cfg, prev=None, now=None) -> PortfolioBoard:
        now = now or time.time()
        accounts = []
        for ex in configured_exchanges(cfg):
            spec = exchanges.EXCHANGES[ex]
            account = Account(ex, "exchange", ex, spec.name, spec.name)
            try:
                account.holdings = [Holding(s, a) for s, a in exchanges.fetch(http, ex, exchange_creds(cfg, ex), now)]
            except (HttpError, ServiceError) as e:
                account.error = describe(e, spec.name)
            accounts.append(account)
        for w in configured_wallets(cfg):
            net = wallets.NETWORKS[w["network"]]
            account = Account(f"{w['network']}:{w['address']}", "wallet", w["network"], net.name,
                              w["label"] or short_address(w["address"]), w["address"])
            try:
                account.holdings = [Holding(s, a) for s, a in wallets.fetch(http, w["network"], w["address"])]
            except (HttpError, ServiceError) as e:
                account.error = describe(e, net.name)
            accounts.append(account)
        merge_prices(accounts, fetch_prices(http, [h.symbol for a in accounts for h in a.holdings]))
        return PortfolioBoard(accounts, sum(a.total_usd for a in accounts), now)

    def error_snapshot(self, message: str, now: float) -> PortfolioBoard:
        return PortfolioBoard([], 0.0, now, error=message)
