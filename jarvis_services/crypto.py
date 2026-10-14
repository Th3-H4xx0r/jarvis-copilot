"""Crypto watchlist: up to 8 coins priced from Coinbase Exchange or OKX public market
data (no key, no account) every 60 s, hourly candles every 10 min for a 24 h curve,
and an opt-in alert when a coin moves more than a set percentage (default 5 %)
since the last alert or since it was first seen.

after coucou (github.com/Louis-CFM/coucou, MIT)
"""
from __future__ import annotations

import re
import time
from dataclasses import dataclass, field
from typing import Any, Optional

from jarvis_services.base import Event, HttpError, Service, plain, num, same_content

EXCHANGES = ("coinbase", "okx")
CURRENCIES = ("USD", "EUR")
MAX_COINS = 8
CANDLES_EVERY = 600
DEFAULTS = {"enabled": False, "exchange": "coinbase", "currency": "USD", "coins": ["BTC", "ETH", "SOL"],
            "alert_enabled": False, "alert_percent": 5.0}


def parse_coins(raw: Any) -> list:
    """"btc, Eth;sol" → ["BTC", "ETH", "SOL"]: letters and digits, ≤10 chars, no repeats, ≤8."""
    text = " ".join(str(x) for x in raw) if isinstance(raw, (list, tuple)) else str(raw or "")
    out: list = []
    for token in re.split(r"[^A-Za-z0-9]+", text.upper()):
        if token and len(token) <= 10 and token not in out:
            out.append(token)
    return out[:MAX_COINS]


def pair(exchange: str, symbol: str, currency: str) -> str:
    """OKX quotes dollars in USDT."""
    if exchange == "okx" and currency == "USD":
        return f"{symbol}-USDT"
    return f"{symbol}-{currency}"


def _ticker_url(exchange: str, p: str) -> str:
    if exchange == "okx":
        return f"https://www.okx.com/api/v5/market/ticker?instId={p}"
    return f"https://api.exchange.coinbase.com/products/{p}/stats"


def _candles_url(exchange: str, p: str) -> str:
    if exchange == "okx":
        return f"https://www.okx.com/api/v5/market/candles?instId={p}&bar=1H&limit=24"
    return f"https://api.exchange.coinbase.com/products/{p}/candles?granularity=3600"


def trade_url(exchange: str, p: str) -> str:
    if exchange == "okx":
        return f"https://www.okx.com/trade-spot/{p.lower()}"
    return f"https://www.coinbase.com/advanced-trade/spot/{p}"


def parse_ticker(exchange: str, body: Any) -> Optional[tuple]:
    """(price, price 24 h ago)."""
    if not isinstance(body, dict):
        return None
    if exchange == "okx":
        rows = body.get("data") if str(body.get("code")) == "0" else None
        row = rows[0] if isinstance(rows, list) and rows and isinstance(rows[0], dict) else {}
        last, open_ = num(row.get("last")), num(row.get("open24h"))
    else:
        last, open_ = num(body.get("last")), num(body.get("open"))
    return (last, open_) if last is not None and open_ is not None else None


def parse_candles(exchange: str, body: Any) -> list:
    """Hourly closes, oldest first (both exchanges send newest first; close is index 4)."""
    rows = body.get("data") if exchange == "okx" and isinstance(body, dict) else body
    if not isinstance(rows, list):
        return []
    closes = [num(r[4]) for r in rows[:24] if isinstance(r, list) and len(r) > 4]
    return [c for c in closes if c is not None][::-1]


def format_price(value: float, currency: str) -> str:
    digits = 0 if value >= 1000 else 2 if value >= 1 else 4
    return f"{value:,.{digits}f} {currency}"


def _signed(pct: float) -> str:
    return f"{'+' if pct >= 0 else '−'}{abs(pct):.2f} %"


@dataclass
class Quote:
    symbol: str
    price: float
    open_24h: float
    change_24h: float
    spark: list = field(default_factory=list)
    url: str = ""


@dataclass(frozen=True)
class CryptoState:
    key: str
    reference: dict
    last_candles: float = 0.0
    #: (symbol, percent, price, reference) when an alert fired on this poll.
    fired: Optional[tuple] = None


@dataclass
class CryptoBoard:
    exchange: str
    currency: str
    quotes: list
    missing: list
    alert_symbol: Optional[str] = None
    updated_at: float = 0.0
    error: Optional[str] = None
    state: Any = field(default=None, compare=False, repr=False)

    def to_dict(self) -> dict:
        return plain(self)

    def same_content(self, other) -> bool:
        return same_content(self, other)


class CryptoService(Service):
    id = "crypto"
    display_name = "Crypto"
    interval = 60
    first_delay = 2
    topic = "portfolio"
    settings = DEFAULTS

    @staticmethod
    def options(cfg) -> dict:
        s = {**DEFAULTS, **cfg.section("crypto")}
        exchange = s["exchange"] if s["exchange"] in EXCHANGES else "coinbase"
        currency = s["currency"] if s["currency"] in CURRENCIES else "USD"
        percent = num(s.get("alert_percent"))
        return {"enabled": s["enabled"] is True, "exchange": exchange, "currency": currency,
                "coins": parse_coins(s["coins"]), "alert_enabled": s["alert_enabled"] is True,
                "alert_percent": percent if percent and percent > 0 else 5.0}

    def configured(self, cfg) -> bool:
        o = self.options(cfg)
        return o["enabled"] and bool(o["coins"])

    def fetch(self, http, cfg, prev=None, now=None) -> CryptoBoard:
        now = now or time.time()
        o = self.options(cfg)
        exchange, currency, coins = o["exchange"], o["currency"], o["coins"]
        key = f"{exchange}|{currency}|{','.join(coins)}"
        old = prev.state if prev is not None and isinstance(prev.state, CryptoState) else None
        if old is None or old.key != key:       # new list: start over
            old, prev = CryptoState(key, {}), None
        with_candles = now - old.last_candles > CANDLES_EVERY
        previous_spark = {q.symbol: q.spark for q in prev.quotes} if prev else {}
        quotes, missing = [], []
        headers = {"Accept": "application/json"}
        for coin in coins:
            p = pair(exchange, coin, currency)
            try:
                r = http.request("GET", _ticker_url(exchange, p), headers=headers, timeout=10)
                tick = parse_ticker(exchange, r.json()) if r.status == 200 else None
            except (HttpError, ValueError):
                tick = None
            if tick is None:
                missing.append(coin)
                continue
            price, open_ = tick
            spark = previous_spark.get(coin, [])
            if with_candles:
                try:
                    r = http.request("GET", _candles_url(exchange, p), headers=headers, timeout=10)
                    if r.status == 200:
                        spark = parse_candles(exchange, r.json()) or spark
                except (HttpError, ValueError):
                    pass
            change = (price - open_) / open_ * 100 if open_ > 0 else 0.0
            quotes.append(Quote(coin, price, open_, round(change, 4), spark, trade_url(exchange, p)))
        reference, fired = dict(old.reference), None
        for q in quotes:
            ref = reference.get(q.symbol)
            if not ref:
                reference[q.symbol] = q.price
                continue
            move = round((q.price - ref) / ref * 100, 6)
            if o["alert_enabled"] and abs(move) >= o["alert_percent"]:
                reference[q.symbol] = q.price
                fired = (q.symbol, move, q.price, ref)
                break                       # one alert at a time
        last_candles = now if with_candles and quotes else old.last_candles
        alert_symbol = fired[0] if fired else (prev.alert_symbol if prev else None)
        return CryptoBoard(exchange, currency, quotes, missing, alert_symbol, now,
                           state=CryptoState(key, reference, last_candles, fired))

    def events(self, old_state, new_state) -> list:
        if not isinstance(new_state, CryptoState) or not new_state.fired or old_state is None:
            return []
        symbol, move, price, ref = new_state.fired
        currency = new_state.key.split("|")[1]
        return [Event("crypto_move", f"{symbol} {_signed(move)}",
                      f"{symbol} is at {format_price(price, currency)} (from {format_price(ref, currency)})",
                      {"symbol": symbol, "percent": move, "price": price})]

    def error_snapshot(self, message: str, now: float) -> CryptoBoard:
        return CryptoBoard("", "", [], [], None, now, error=message)
