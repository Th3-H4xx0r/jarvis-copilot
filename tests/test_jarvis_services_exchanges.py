"""Exchange balances: request signing against fixed vectors (computed with the openssl
CLI from each exchange's documented algorithm), request shape and parsing."""
from __future__ import annotations

import json

import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from jarvis_services import exchanges
from jarvis_services.base import HttpError, ServiceError
from jarvis_services.exchanges import (
    EXCHANGES, binance_signature, bybit_signature, coinbase_jwt, coinbase_private_key, env_name,
    kraken_signature, kraken_symbol, okx_signature,
)
from jarvis_services.testing import FakeHttp

NOW = 1_700_000_000.0          # → nonce / timestamp 1700000000000
KRAKEN_SECRET = "a3Jha2VuLXByaXZhdGUta2V5LWZvci10ZXN0cy1vbmx5"   # base64("kraken-private-key-for-tests-only")


# ── signing vectors ─────────────────────────────────────────────────────────────

def test_binance_hmac_sha256_hex():
    assert binance_signature("binance_secret", "timestamp=1700000000000") == \
        "482fb5c501a53f3066dd630cdad10bac95bc6354289a909282f98017f153ced2"


def test_okx_hmac_sha256_base64():
    assert okx_signature("okx_secret", "2026-10-14T00:00:00.000Z", "GET", "/api/v5/account/balance") == \
        "KjI/pzh1+KXWVQ1+R41YpRfQEIgzCb3nyLANwpgNuDM="


def test_bybit_hmac_sha256_hex():
    assert bybit_signature("bybit_secret", "1700000000000", "bybit_key", "5000", "accountType=UNIFIED") == \
        "8db36c67e968a4a744125c1a62baece4f1c65636322d4aebc638ba99057b6239"


def test_kraken_hmac_sha512_of_path_and_sha256():
    assert kraken_signature(KRAKEN_SECRET, "/0/private/Balance", "1700000000000", "nonce=1700000000000") == \
        "AoR3a/9v55G8R9qp+Za1j32CRVI72w4TscCuo9/65dEAVW1/JZU8feKXpqfLEjy6qwbPXZzR1yO5miWfZDcXTA=="


# ── Coinbase ES256 JWT ──────────────────────────────────────────────────────────

def _ec_key():
    key = ec.generate_private_key(ec.SECP256R1())
    sec1 = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL,
                             serialization.NoEncryption()).decode()
    pkcs8 = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                              serialization.NoEncryption()).decode()
    return key, sec1, pkcs8


def test_coinbase_jwt_header_claims_and_signature():
    key, sec1, _ = _ec_key()
    name = "organizations/org-1/apiKeys/key-1"
    token = coinbase_jwt(name, sec1, "GET", "api.coinbase.com", "/api/v3/brokerage/accounts", now=NOW)
    header = jwt.get_unverified_header(token)
    assert header["alg"] == "ES256" and header["kid"] == name and header["typ"] == "JWT"
    assert len(header["nonce"]) == 32 and int(header["nonce"], 16) >= 0
    claims = jwt.decode(token, key.public_key(), algorithms=["ES256"],
                        options={"verify_exp": False, "verify_nbf": False})
    assert claims == {"sub": name, "iss": "cdp", "nbf": int(NOW), "exp": int(NOW) + 120,
                      "uri": "GET api.coinbase.com/api/v3/brokerage/accounts"}


def test_coinbase_key_accepts_escaped_newlines_quotes_and_pkcs8():
    key, sec1, pkcs8 = _ec_key()
    want = key.private_numbers().private_value
    escaped = '"' + sec1.strip().replace("\n", "\\n") + '"'          # as in cdp_api_key.json
    one_line = sec1.replace("\n", " ")
    for raw in (sec1, escaped, one_line, pkcs8):
        assert coinbase_private_key(raw).private_numbers().private_value == want
    assert coinbase_private_key("not a key") is None


# ── fetchers ────────────────────────────────────────────────────────────────────

def test_binance_request_and_parse():
    http = FakeHttp().add("GET", "https://api.binance.com/api/v3/account", {"balances": [
        {"asset": "BTC", "free": "0.40000000", "locked": "0.10000000"},
        {"asset": "DUST", "free": "0.00000001", "locked": "0.00000000"}]})
    got = exchanges.fetch(http, "binance", {"key": "bk", "secret": "binance_secret"}, NOW)
    assert got == [("BTC", 0.5)]
    call = http.calls[0]
    assert call.url == ("https://api.binance.com/api/v3/account?timestamp=1700000000000&signature="
                        "482fb5c501a53f3066dd630cdad10bac95bc6354289a909282f98017f153ced2")
    assert call.headers == {"X-MBX-APIKEY": "bk"}


def test_okx_request_and_parse():
    http = FakeHttp().add("GET", "https://www.okx.com/api/v5/account/balance", {"code": "0", "data": [
        {"details": [{"ccy": "ETH", "availBal": "1.5", "frozenBal": "0.5"},
                     {"ccy": "USDT", "availBal": "0", "frozenBal": "0"}]}]})
    got = exchanges.fetch(http, "okx", {"key": "ok", "secret": "okx_secret", "passphrase": "pp"}, NOW)
    assert got == [("ETH", 2.0)]
    h = http.calls[0].headers
    assert h["OK-ACCESS-KEY"] == "ok" and h["OK-ACCESS-PASSPHRASE"] == "pp"
    assert h["OK-ACCESS-TIMESTAMP"] == "2023-11-14T22:13:20.000Z"
    assert h["OK-ACCESS-SIGN"] == okx_signature("okx_secret", "2023-11-14T22:13:20.000Z", "GET",
                                                "/api/v5/account/balance")


def test_okx_error_code_is_an_error():
    http = FakeHttp().add("GET", "https://www.okx.com/api/v5/account/balance",
                          {"code": "50113", "msg": "Invalid Sign", "data": []})
    with pytest.raises(ServiceError) as e:
        exchanges.fetch(http, "okx", {"key": "ok", "secret": "s", "passphrase": "p"}, NOW)
    assert "Invalid Sign" in e.value.message


def test_bybit_request_and_parse():
    http = FakeHttp().add("GET", "https://api.bybit.com/v5/account/wallet-balance?accountType=UNIFIED",
                          {"retCode": 0, "result": {"list": [{"coin": [
                              {"coin": "SOL", "walletBalance": "12.5"}, {"coin": "XRP", "walletBalance": "0"}]}]}})
    got = exchanges.fetch(http, "bybit", {"key": "bybit_key", "secret": "bybit_secret"}, NOW)
    assert got == [("SOL", 12.5)]
    h = http.calls[0].headers
    assert h == {"X-BAPI-API-KEY": "bybit_key", "X-BAPI-TIMESTAMP": "1700000000000", "X-BAPI-RECV-WINDOW": "5000",
                 "X-BAPI-SIGN": "8db36c67e968a4a744125c1a62baece4f1c65636322d4aebc638ba99057b6239"}


def test_kraken_request_symbols_and_errors():
    http = FakeHttp().add("POST", "https://api.kraken.com/0/private/Balance", {"error": [], "result": {
        "XXBT": "0.2500000000", "ZUSD": "100.0000", "XETH": "0.0000", "DOT": "3.0"}})
    got = exchanges.fetch(http, "kraken", {"key": "kk", "secret": KRAKEN_SECRET}, NOW)
    assert sorted(got) == [("BTC", 0.25), ("DOT", 3.0), ("USD", 100.0)]
    call = http.calls[0]
    assert call.data == b"nonce=1700000000000"
    assert call.headers["API-Key"] == "kk"
    assert call.headers["Content-Type"] == "application/x-www-form-urlencoded"
    assert call.headers["API-Sign"].startswith("AoR3a/9v55G8")
    bad = FakeHttp().add("POST", "https://api.kraken.com/0/private/Balance", {"error": ["EAPI:Invalid key"]})
    with pytest.raises(ServiceError) as e:
        exchanges.fetch(bad, "kraken", {"key": "kk", "secret": KRAKEN_SECRET}, NOW)
    assert "EAPI:Invalid key" in e.value.message
    assert kraken_symbol("XXDG") == "XDG" and kraken_symbol("ZEUR") == "EUR"


def test_coinbase_pages_and_sums_hold():
    _, sec1, _ = _ec_key()
    pages = {None: {"accounts": [{"currency": "BTC", "available_balance": {"value": "0.1"}, "hold": {"value": "0.05"}},
                                 {"currency": "USD", "available_balance": {"value": "0"}, "hold": {"value": "0"}}],
                    "has_next": True, "cursor": "c2"},
             "c2": {"accounts": [{"currency": "BTC", "available_balance": {"value": "0.1"}, "hold": {"value": "0"}}],
                    "has_next": False, "cursor": ""}}

    def answer(call):
        from jarvis_services.base import Response
        return Response(200, json.dumps(pages[(call.params or {}).get("cursor")]).encode())

    http = FakeHttp().add("GET", "https://api.coinbase.com/api/v3/brokerage/accounts", answer)
    got = exchanges.fetch(http, "coinbase", {"key": "organizations/o/apiKeys/k", "secret": sec1}, NOW)
    assert [(s, round(a, 8)) for s, a in got] == [("BTC", 0.25)]
    assert len(http.calls) == 2
    assert all(c.headers["Authorization"].startswith("Bearer ey") for c in http.calls)
    assert http.calls[0].params == {"limit": "250"}


def test_coinbase_bad_key_and_http_errors():
    with pytest.raises(ServiceError) as e:
        exchanges.fetch(FakeHttp(), "coinbase", {"key": "k", "secret": "garbage"}, NOW)
    assert "private key" in e.value.message.lower()
    http = FakeHttp().add("GET", "https://api.binance.com/api/v3/account", {"msg": "Invalid API-key"}, status=401)
    with pytest.raises(HttpError) as e:
        exchanges.fetch(http, "binance", {"key": "k", "secret": "s"}, NOW)
    assert e.value.status == 401


def test_specs_and_env_names():
    assert list(EXCHANGES) == ["binance", "okx", "bybit", "kraken", "coinbase"]
    assert EXCHANGES["okx"].fields == ("key", "secret", "passphrase")
    assert env_name("okx", "passphrase") == "PORTFOLIO_OKX_PASSPHRASE"
    assert EXCHANGES["coinbase"].labels["secret"] == "Private key"
