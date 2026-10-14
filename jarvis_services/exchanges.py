"""Read-only balances on Binance, OKX, Bybit, Kraken and Coinbase (Advanced Trade).

Each request is signed as the exchange documents it: HMAC-SHA256 hex (Binance,
Bybit), HMAC-SHA256 base64 (OKX), HMAC-SHA512 of path + SHA256(nonce + body) with
the base64-decoded secret (Kraken), and a fresh ES256 JWT per request from a CDP
key (Coinbase). Only balance endpoints are called: give the keys read-only rights.

after coucou (github.com/Louis-CFM/coucou, MIT)
"""
from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import secrets as _secrets
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Mapping, Optional

import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from jarvis_services.base import HttpError, ServiceError, call_json, num

MIN_AMOUNT = 0.000001


@dataclass(frozen=True)
class ExchangeSpec:
    id: str
    name: str
    fields: tuple
    labels: Mapping[str, str]


EXCHANGES = {
    "binance": ExchangeSpec("binance", "Binance", ("key", "secret"), {"key": "API key", "secret": "API secret"}),
    "okx": ExchangeSpec("okx", "OKX", ("key", "secret", "passphrase"),
                        {"key": "API key", "secret": "API secret", "passphrase": "Passphrase"}),
    "bybit": ExchangeSpec("bybit", "Bybit", ("key", "secret"), {"key": "API key", "secret": "API secret"}),
    "kraken": ExchangeSpec("kraken", "Kraken", ("key", "secret"), {"key": "API key", "secret": "Private key"}),
    # CDP API keys: a key name and an EC private key.
    "coinbase": ExchangeSpec("coinbase", "Coinbase", ("key", "secret"), {"key": "Key name", "secret": "Private key"}),
}


def env_name(exchange: str, field: str) -> str:
    return f"PORTFOLIO_{exchange.upper()}_{field.upper()}"


# ── signing ─────────────────────────────────────────────────────────────────────

def _hmac(key: bytes, message: bytes, algo) -> bytes:
    return hmac.new(key, message, algo).digest()


def binance_signature(secret: str, query: str) -> str:
    return _hmac(secret.encode(), query.encode(), hashlib.sha256).hex()


def okx_signature(secret: str, timestamp: str, method: str, path: str, body: str = "") -> str:
    return base64.b64encode(_hmac(secret.encode(), f"{timestamp}{method}{path}{body}".encode(),
                                  hashlib.sha256)).decode()


def bybit_signature(secret: str, timestamp: str, key: str, recv_window: str, query: str) -> str:
    return _hmac(secret.encode(), f"{timestamp}{key}{recv_window}{query}".encode(), hashlib.sha256).hex()


def kraken_signature(secret_b64: str, path: str, nonce: str, body: str) -> str:
    try:
        key = base64.b64decode(secret_b64, validate=True)
    except (binascii.Error, ValueError):
        raise ServiceError("The Kraken private key isn't valid base64.") from None
    inner = hashlib.sha256(f"{nonce}{body}".encode()).digest()
    return base64.b64encode(_hmac(key, path.encode() + inner, hashlib.sha512)).decode()


def coinbase_private_key(raw: str) -> Optional[ec.EllipticCurvePrivateKey]:
    """The P-256 key from what was pasted: a PEM ("EC PRIVATE KEY" or "PRIVATE KEY"),
    its lines joined on one line, or with ``\\n`` escapes as in cdp_api_key.json."""
    text = (raw or "").replace("\\n", "\n").strip().strip("\"' \n\r\t")
    for marker in ("-----BEGIN EC PRIVATE KEY-----", "-----END EC PRIVATE KEY-----",
                   "-----BEGIN PRIVATE KEY-----", "-----END PRIVATE KEY-----"):
        text = text.replace(marker, "")
    try:
        der = base64.b64decode("".join(text.split()), validate=True)
    except (binascii.Error, ValueError):
        return None
    try:
        key = serialization.load_der_private_key(der, password=None)
        if isinstance(key, ec.EllipticCurvePrivateKey) and isinstance(key.curve, ec.SECP256R1):
            return key
    except (ValueError, TypeError):
        pass
    # SEC1 ECPrivateKey: SEQUENCE { INTEGER 1, OCTET STRING (32-byte key), … }.
    i = der.find(bytes([0x02, 0x01, 0x01, 0x04, 0x20]))
    if i >= 0 and len(der) >= i + 37:
        return ec.derive_private_key(int.from_bytes(der[i + 5:i + 37], "big"), ec.SECP256R1())
    return None


def coinbase_jwt(key_name: str, private_key, method: str, host: str, path: str, *, now: float,
                 nonce: Optional[str] = None) -> str:
    """Header {alg ES256, kid, nonce, typ}, claims {sub, iss "cdp", nbf, exp +120 s,
    uri "GET host/path"}, as Coinbase documents for CDP keys. One per request."""
    key = coinbase_private_key(private_key) if isinstance(private_key, str) else private_key
    if key is None:
        raise ServiceError("That Coinbase private key couldn't be read. Paste the whole EC private key.")
    claims = {"sub": key_name, "iss": "cdp", "nbf": int(now), "exp": int(now) + 120,
              "uri": f"{method} {host}{path}"}
    headers = {"kid": key_name, "nonce": nonce or _secrets.token_hex(16), "typ": "JWT"}
    return jwt.encode(claims, key, algorithm="ES256", headers=headers)


# ── fetchers: each returns [(symbol, amount)] ───────────────────────────────────

def _positive(rows) -> list:
    return [(s, a) for s, a in rows if a > MIN_AMOUNT]


def _binance(http, creds: dict, now: float) -> list:
    query = f"timestamp={int(now * 1000)}"
    sig = binance_signature(creds["secret"], query)
    body = call_json(http, "GET", f"https://api.binance.com/api/v3/account?{query}&signature={sig}",
                     headers={"X-MBX-APIKEY": creds["key"]}, timeout=10)
    rows = []
    for b in body.get("balances") or []:
        free, locked = num(b.get("free")), num(b.get("locked"))
        if isinstance(b.get("asset"), str) and free is not None and locked is not None:
            rows.append((b["asset"], free + locked))
    return _positive(rows)


def _okx(http, creds: dict, now: float) -> list:
    path = "/api/v5/account/balance"
    ts = datetime.fromtimestamp(now, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + f"{int(now * 1000) % 1000:03d}Z"
    body = call_json(http, "GET", f"https://www.okx.com{path}", timeout=10, headers={
        "Content-Type": "application/json", "OK-ACCESS-KEY": creds["key"],
        "OK-ACCESS-SIGN": okx_signature(creds["secret"], ts, "GET", path),
        "OK-ACCESS-TIMESTAMP": ts, "OK-ACCESS-PASSPHRASE": creds["passphrase"]})
    if str(body.get("code")) != "0":
        raise ServiceError(f"OKX: {body.get('msg') or 'error ' + str(body.get('code'))}")
    data = body.get("data") or [{}]
    rows = []
    for d in (data[0] or {}).get("details") or []:
        avail, frozen = num(d.get("availBal")), num(d.get("frozenBal"))
        if isinstance(d.get("ccy"), str) and avail is not None and frozen is not None:
            rows.append((d["ccy"], avail + frozen))
    return _positive(rows)


def _bybit(http, creds: dict, now: float) -> list:
    ts, recv, query = str(int(now * 1000)), "5000", "accountType=UNIFIED"
    body = call_json(http, "GET", f"https://api.bybit.com/v5/account/wallet-balance?{query}", timeout=10, headers={
        "X-BAPI-API-KEY": creds["key"], "X-BAPI-SIGN": bybit_signature(creds["secret"], ts, creds["key"], recv, query),
        "X-BAPI-TIMESTAMP": ts, "X-BAPI-RECV-WINDOW": recv})
    if body.get("retCode") not in (0, None):
        raise ServiceError(f"Bybit: {body.get('retMsg') or 'error ' + str(body.get('retCode'))}")
    accounts = (body.get("result") or {}).get("list") or [{}]
    rows = [(c["coin"], num(c.get("walletBalance")) or 0.0) for c in (accounts[0] or {}).get("coin") or []
            if isinstance(c.get("coin"), str)]
    return _positive(rows)


_KRAKEN = {"XXBT": "BTC", "XETH": "ETH", "XLTC": "LTC", "XXLM": "XLM", "XXMR": "XMR", "XXRP": "XRP",
           "XZEC": "ZEC", "ZUSD": "USD", "ZEUR": "EUR", "ZGBP": "GBP", "ZCAD": "CAD", "ZJPY": "JPY"}


def kraken_symbol(raw: str) -> str:
    """Kraken's X/Z-prefixed names: XXBT = BTC, ZUSD = USD…"""
    return _KRAKEN.get(raw) or (raw[1:] if raw[:1] in ("X", "Z") else raw)


def _kraken(http, creds: dict, now: float) -> list:
    path, nonce = "/0/private/Balance", str(int(now * 1000))
    body = f"nonce={nonce}"
    answer = call_json(http, "POST", f"https://api.kraken.com{path}", data=body.encode(), timeout=10, headers={
        "Content-Type": "application/x-www-form-urlencoded", "API-Key": creds["key"],
        "API-Sign": kraken_signature(creds["secret"], path, nonce, body)})
    errors = answer.get("error") or []
    if errors or not isinstance(answer.get("result"), dict):
        raise ServiceError(f"Kraken: {errors[0] if errors else 'unreadable answer'}")
    return _positive([(kraken_symbol(k), num(v) or 0.0) for k, v in answer["result"].items()])


def _coinbase(http, creds: dict, now: float) -> list:
    key_name = creds["key"].strip()
    key = coinbase_private_key(creds["secret"])
    if key is None:
        raise ServiceError("That Coinbase private key couldn't be read. Paste the whole EC private key.")
    host, path = "api.coinbase.com", "/api/v3/brokerage/accounts"
    totals: dict = {}
    cursor = None
    for _ in range(10):   # 250 accounts a page; ten pages is more than any account has
        params = {"limit": "250", **({"cursor": cursor} if cursor else {})}
        token = coinbase_jwt(key_name, key, "GET", host, path, now=now)
        body = call_json(http, "GET", f"https://{host}{path}", params=params, timeout=10,
                         headers={"Authorization": f"Bearer {token}", "Accept": "application/json"})
        for account in body.get("accounts") or []:
            currency = account.get("currency")
            if not isinstance(currency, str):
                continue
            available = num((account.get("available_balance") or {}).get("value")) or 0.0
            hold = num((account.get("hold") or {}).get("value")) or 0.0
            totals[currency] = totals.get(currency, 0.0) + available + hold
        cursor = body.get("cursor")
        if body.get("has_next") is not True or not cursor:
            break
    return _positive(totals.items())


_FETCHERS = {"binance": _binance, "okx": _okx, "bybit": _bybit, "kraken": _kraken, "coinbase": _coinbase}


def fetch(http, exchange: str, creds: Mapping[str, str], now: float) -> list:
    """``[(symbol, amount)]`` held on the exchange. Raises ``ServiceError``/``HttpError``."""
    spec = EXCHANGES.get(exchange)
    if spec is None:
        raise ServiceError("Unknown exchange.")
    if not all((creds.get(f) or "").strip() for f in spec.fields):
        raise ServiceError(f"No {spec.name} key yet.")
    try:
        return _FETCHERS[exchange](http, dict(creds), now)
    except (HttpError, ServiceError):
        raise
    except (KeyError, TypeError, AttributeError, IndexError):
        raise ServiceError(f"{spec.name}'s answer couldn't be read.") from None
