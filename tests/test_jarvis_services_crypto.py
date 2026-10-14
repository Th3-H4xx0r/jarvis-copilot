"""Crypto watchlist: Coinbase Exchange / OKX public prices every 60 s, hourly candles
every 10 min for the 24 h curve, move alerts."""
from __future__ import annotations

from jarvis_services.config import ConfigView
from jarvis_services.crypto import CryptoService, pair, parse_coins
from jarvis_services.testing import FakeHttp

NOW = 1_791_936_000.0
CB = "https://api.exchange.coinbase.com/products"


def cfg(**crypto):
    settings = {"enabled": True, "coins": ["BTC", "ETH"], "exchange": "coinbase", "currency": "USD",
                "alert_enabled": True}
    settings.update(crypto)
    return ConfigView({}, {"crypto": settings}, environ={})


def candles(closes):
    """Coinbase rows, newest first: [time, low, high, open, close, volume]."""
    return [[1_700_000_000 - i * 3600, 1, 2, 1, c, 9] for i, c in enumerate(reversed(closes))]


def coinbase_http(prices, opens=None, closes=None):
    http = FakeHttp()
    for sym, price in prices.items():
        http.add("GET", f"{CB}/{sym}-USD/stats", {"open": str((opens or {}).get(sym, price)), "last": str(price),
                                                  "high": "1", "low": "1", "volume": "1"})
        http.add("GET", f"{CB}/{sym}-USD/candles?granularity=3600", candles((closes or {}).get(sym, [price])))
    return http


def test_parse_coins():
    assert parse_coins("btc, Eth;sol;SOL") == ["BTC", "ETH", "SOL"]
    assert parse_coins(["btc", "eth"]) == ["BTC", "ETH"]
    assert parse_coins("A B C D E F G H I J") == ["A", "B", "C", "D", "E", "F", "G", "H"]
    assert parse_coins("WAYTOOLONGCOIN btc") == ["BTC"]


def test_pairs():
    assert pair("coinbase", "BTC", "USD") == "BTC-USD"
    assert pair("okx", "BTC", "USD") == "BTC-USDT"
    assert pair("okx", "BTC", "EUR") == "BTC-EUR"


def test_configured_only_when_enabled_with_coins():
    s = CryptoService()
    assert s.interval == 60 and s.topic == "portfolio"
    assert s.configured(cfg())
    assert not s.configured(cfg(enabled=False))
    assert not s.configured(cfg(coins=[]))
    assert not s.configured(ConfigView({}, {}, environ={}))


def test_coinbase_quotes_change_and_spark():
    http = coinbase_http({"BTC": 63000, "ETH": 3000}, opens={"BTC": 60000}, closes={"BTC": [61000, 62000, 63000]})
    board = CryptoService().fetch(http, cfg(), None, NOW)
    btc = board.quotes[0]
    assert (btc.symbol, btc.price, btc.open_24h, btc.change_24h) == ("BTC", 63000, 60000, 5.0)
    assert btc.spark == [61000, 62000, 63000]
    assert btc.url == "https://www.coinbase.com/advanced-trade/spot/BTC-USD"
    assert [q.symbol for q in board.quotes] == ["BTC", "ETH"]
    assert all(c.headers == {"Accept": "application/json"} for c in http.calls)
    d = board.to_dict()
    assert set(d) == {"exchange", "currency", "quotes", "missing", "alert_symbol", "updated_at", "error"}
    assert set(d["quotes"][0]) == {"symbol", "price", "open_24h", "change_24h", "spark", "url"}


def test_okx_endpoints_and_parsing():
    http = FakeHttp()
    http.add("GET", "https://www.okx.com/api/v5/market/ticker?instId=BTC-USDT",
             {"code": "0", "data": [{"instId": "BTC-USDT", "last": "63000", "open24h": "62000"}]})
    http.add("GET", "https://www.okx.com/api/v5/market/candles?instId=BTC-USDT&bar=1H&limit=24",
             {"code": "0", "data": [["3", "1", "1", "1", "63000"], ["2", "1", "1", "1", "62500"]]})
    board = CryptoService().fetch(http, cfg(exchange="okx", coins=["BTC"]), None, NOW)
    assert board.quotes[0].price == 63000 and board.quotes[0].spark == [62500, 63000]
    assert board.quotes[0].url == "https://www.okx.com/trade-spot/btc-usdt"


def test_missing_coins():
    http = coinbase_http({"BTC": 63000})
    board = CryptoService().fetch(http, cfg(coins=["BTC", "NOPE"]), None, NOW)
    assert [q.symbol for q in board.quotes] == ["BTC"] and board.missing == ["NOPE"]


def test_candles_every_ten_minutes_and_curve_kept():
    s = CryptoService()
    first = s.fetch(coinbase_http({"BTC": 63000}, closes={"BTC": [1, 2, 3]}), cfg(coins=["BTC"]), None, NOW)
    http = coinbase_http({"BTC": 63100})
    second = s.fetch(http, cfg(coins=["BTC"]), first, NOW + 60)
    assert not http.called("GET", f"{CB}/BTC-USD/candles")
    assert second.quotes[0].spark == [1, 2, 3]
    http = coinbase_http({"BTC": 63100}, closes={"BTC": [4, 5]})
    third = s.fetch(http, cfg(coins=["BTC"]), second, NOW + 601)
    assert http.called("GET", f"{CB}/BTC-USD/candles") and third.quotes[0].spark == [4, 5]


def test_move_alert_threshold_default_five_percent():
    s = CryptoService()
    c = cfg(coins=["BTC"])
    p0 = s.fetch(coinbase_http({"BTC": 60000}), c, None, NOW)
    assert s.events(None, p0.state) == []
    p1 = s.fetch(coinbase_http({"BTC": 62900}), c, p0, NOW + 60)          # +4.83 %
    assert s.events(p0.state, p1.state) == []
    p2 = s.fetch(coinbase_http({"BTC": 63000}), c, p1, NOW + 120)         # +5.00 % since first seen
    events = s.events(p1.state, p2.state)
    assert [(e.kind, e.title, e.body) for e in events] == [
        ("crypto_move", "BTC +5.00 %", "BTC is at 63,000 USD (from 60,000 USD)")]
    assert p2.alert_symbol == "BTC"
    p3 = s.fetch(coinbase_http({"BTC": 64000}), c, p2, NOW + 180)         # +1.6 % since the alert
    assert s.events(p2.state, p3.state) == []
    p4 = s.fetch(coinbase_http({"BTC": 59800}), c, p3, NOW + 240)         # −5.08 % since the alert
    assert s.events(p3.state, p4.state)[0].title == "BTC −5.08 %"


def test_alert_off_and_custom_percent():
    s = CryptoService()
    off = cfg(coins=["BTC"], alert_enabled=False)
    p0 = s.fetch(coinbase_http({"BTC": 100}), off, None, NOW)
    p1 = s.fetch(coinbase_http({"BTC": 120}), off, p0, NOW + 60)
    assert s.events(p0.state, p1.state) == []
    two = cfg(coins=["BTC"], alert_percent=2)
    p0 = s.fetch(coinbase_http({"BTC": 100}), two, None, NOW)
    p1 = s.fetch(coinbase_http({"BTC": 102}), two, p0, NOW + 60)
    assert [e.kind for e in s.events(p0.state, p1.state)] == ["crypto_move"]


def test_settings_change_starts_over():
    s = CryptoService()
    p0 = s.fetch(coinbase_http({"BTC": 100}), cfg(coins=["BTC"]), None, NOW)
    p1 = s.fetch(coinbase_http({"BTC": 150}, closes={"BTC": [9]}), cfg(coins=["BTC"], currency="USD", exchange="coinbase",
                                                                       alert_percent=5, enabled=True,
                                                                       extra="x"), p0, NOW + 60)
    assert p1.alert_symbol == "BTC"     # same list: the alert fires
    eur = FakeHttp().add("GET", f"{CB}/BTC-EUR/stats", {"open": "90", "last": "140"})
    p2 = s.fetch(eur, cfg(coins=["BTC"], currency="EUR"), p1, NOW + 120)
    assert s.events(p1.state, p2.state) == [] and p2.alert_symbol is None
    assert eur.called("GET", f"{CB}/BTC-EUR/candles")              # curve re-read for the new pair
