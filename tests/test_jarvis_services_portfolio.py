"""Portfolio: exchange + wallet holdings every 120 s, priced from Coinbase (exchange
rates for everything, market stats + 7-day curve for crypto), stablecoins at $1."""
from __future__ import annotations

from jarvis_services.config import ConfigView
import pytest

from jarvis_services.portfolio import Account, Holding, PortfolioService, fetch_prices, merge_prices
from jarvis_services.testing import FakeHttp

NOW = 1_791_936_000.0
ETH_ADDR = "0x" + "ab" * 20
RATES = "https://api.coinbase.com/v2/exchange-rates?currency=USD"
CB = "https://api.exchange.coinbase.com/products"


def cfg(env=None, wallets=()):
    return ConfigView(env or {}, {"portfolio": {"wallets": list(wallets)}}, environ={})


BINANCE = {"PORTFOLIO_BINANCE_KEY": "bk", "PORTFOLIO_BINANCE_SECRET": "bs"}
WALLET = {"network": "ethereum", "address": ETH_ADDR, "label": "Ledger"}


def price_http(http):
    http.add("GET", RATES, {"data": {"currency": "USD", "rates": {
        "BTC": "0.00002", "ETH": "0.0005", "EUR": "0.8", "USDT": "1.0", "USD": "1"}}})
    http.add("GET", f"{CB}/BTC-USD/stats", {"open": "48000", "last": "50000"})
    http.add("GET", f"{CB}/BTC-USD/candles?granularity=86400",
             [[9 - i, 1, 1, 1, 50000 - i * 100, 1] for i in range(9)])
    return http


def test_configured():
    s = PortfolioService()
    assert s.interval == 120 and s.topic == "portfolio"
    assert s.configured(cfg(BINANCE))
    assert not s.configured(cfg({"PORTFOLIO_BINANCE_KEY": "bk"}))                 # half a key pair
    assert not s.configured(cfg({"PORTFOLIO_OKX_KEY": "k", "PORTFOLIO_OKX_SECRET": "s"}))   # no passphrase
    assert s.configured(cfg(wallets=[WALLET]))
    assert not s.configured(cfg())


def test_fetch_prices_rates_then_market():
    http = price_http(FakeHttp())
    prices = fetch_prices(http, ["BTC", "EUR", "USD", "USDT", "ETH"])
    price, change, history = prices["BTC"]
    assert price == 50000.0 and change == pytest.approx(4.1666667)
    assert history == [49400, 49500, 49600, 49700, 49800, 49900, 50000]
    assert prices["EUR"] == (1.25, None, [])
    assert prices["USD"] == (1.0, None, [])
    assert prices["ETH"] == (2000.0, None, [])                    # no market answer: rate only
    assert not http.called("GET", f"{CB}/EUR-USD") and not http.called("GET", f"{CB}/USD-USD")


def test_merge_prices_and_stablecoin_fallback():
    accounts = [Account("binance", "exchange", "binance", "Binance", "Binance",
                        holdings=[Holding("BTC", 0.5), Holding("DAI", 10), Holding("XYZ", 3)])]
    merged = merge_prices(accounts, {"BTC": (50000.0, 4.0, [1, 2])})
    h = merged[0].holdings
    assert (h[0].price, h[0].value, h[0].change_24h, h[0].history) == (50000.0, 25000.0, 4.0, [1, 2])
    assert (h[1].price, h[1].value) == (1.0, 10.0)
    assert (h[2].price, h[2].value) == (0.0, 0.0)
    assert merged[0].total_usd == 25010.0


def test_fetch_accounts_with_one_failing():
    http = price_http(FakeHttp())
    http.add("GET", "https://api.binance.com/api/v3/account", {"balances": [
        {"asset": "BTC", "free": "0.1", "locked": "0"}, {"asset": "USDT", "free": "250", "locked": "0"}]})
    http.add("POST", "https://ethereum-rpc.publicnode.com", {"error": "down"}, status=503)
    http.add("POST", "https://cloudflare-eth.com", {"error": "down"}, status=503)
    board = PortfolioService().fetch(http, cfg(BINANCE, [WALLET]), None, NOW)
    binance, wallet = board.accounts
    assert (binance.id, binance.kind, binance.name, binance.error) == ("binance", "exchange", "Binance", None)
    assert [(x.symbol, x.value) for x in binance.holdings] == [("BTC", 5000.0), ("USDT", 250.0)]
    assert binance.total_usd == 5250.0
    assert wallet.id == f"ethereum:{ETH_ADDR}" and wallet.label == "Ledger" and wallet.address == ETH_ADDR
    assert wallet.error and wallet.holdings == []
    assert board.total_usd == 5250.0
    d = board.to_dict()
    assert set(d) == {"accounts", "total_usd", "updated_at", "error"}
    assert set(d["accounts"][0]) == {"id", "kind", "source", "name", "label", "address", "holdings",
                                     "total_usd", "error"}
    assert set(d["accounts"][0]["holdings"][0]) == {"symbol", "amount", "price", "value", "change_24h", "history"}


def test_wallet_default_label_and_no_secrets_in_output():
    http = price_http(FakeHttp()).add("POST", "https://ethereum-rpc.publicnode.com", {"result": "0xde0b6b3a7640000"})
    board = PortfolioService().fetch(http, cfg({**BINANCE, "PORTFOLIO_BINANCE_SECRET": "TOPSECRET"},
                                               [{"network": "ethereum", "address": ETH_ADDR}]), None, NOW)
    assert board.accounts[1].label == "0xabab…abab"
    assert board.accounts[1].holdings[0].value == 2000.0
    assert "TOPSECRET" not in repr(board.to_dict())
