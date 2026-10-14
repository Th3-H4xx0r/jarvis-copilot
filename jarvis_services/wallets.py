"""Public wallet balances on 16 networks, read from the same free endpoints coucou
uses (no key, no account), plus a local address-format check before any request.

after coucou (github.com/Louis-CFM/coucou, MIT)
"""
from __future__ import annotations

import re
from dataclasses import dataclass

from jarvis_services.base import HttpError, ServiceError, call_json, num


@dataclass(frozen=True)
class Network:
    id: str
    name: str
    symbol: str
    placeholder: str


_EVM_HINT = "0x…"
NETWORKS = {n.id: n for n in (
    Network("bitcoin", "Bitcoin", "BTC", "bc1q… or 1… or 3…"),
    Network("dogecoin", "Dogecoin", "DOGE", "D…"),
    Network("litecoin", "Litecoin", "LTC", "ltc1… or L… or M…"),
    Network("ethereum", "Ethereum", "ETH", _EVM_HINT),
    Network("polygon", "Polygon", "POL", _EVM_HINT),
    Network("bnb_chain", "BNB Chain", "BNB", _EVM_HINT),
    Network("avalanche", "Avalanche", "AVAX", _EVM_HINT),
    Network("arbitrum", "Arbitrum", "ETH", _EVM_HINT),
    Network("optimism", "Optimism", "ETH", _EVM_HINT),
    Network("base", "Base", "ETH", _EVM_HINT),
    Network("solana", "Solana", "SOL", "base58 address"),
    Network("tron", "TRON", "TRX", "T…"),
    Network("xrp", "XRP Ledger", "XRP", "r…"),
    Network("cardano", "Cardano", "ADA", "addr1…"),
    Network("cosmos", "Cosmos", "ATOM", "cosmos1…"),
    Network("near", "NEAR", "NEAR", "alice.near or 64-char hex"),
)}

# Two public RPCs per chain: the second answers when the first is down or rate-limited.
EVM_RPCS = {
    "ethereum": ("https://ethereum-rpc.publicnode.com", "https://cloudflare-eth.com"),
    "polygon": ("https://polygon-bor-rpc.publicnode.com", "https://polygon-rpc.com"),
    "bnb_chain": ("https://bsc-dataseed.binance.org", "https://bsc-rpc.publicnode.com"),
    "avalanche": ("https://api.avax.network/ext/bc/C/rpc", "https://avalanche-c-chain-rpc.publicnode.com"),
    "arbitrum": ("https://arb1.arbitrum.io/rpc", "https://arbitrum-one-rpc.publicnode.com"),
    "optimism": ("https://mainnet.optimism.io", "https://optimism-rpc.publicnode.com"),
    "base": ("https://mainnet.base.org", "https://base-rpc.publicnode.com"),
}

_SAFE = re.compile(r"^[A-Za-z0-9._-]+$")
_HEX40 = re.compile(r"^[0-9a-fA-F]{40}$")
_HEX64 = re.compile(r"^[0-9a-f]{64}$")


def is_plausible(address: str, network: str) -> bool:
    """A quick local check of the address format (no checksum), before any request."""
    a = (address or "").strip()
    if network not in NETWORKS or not _SAFE.match(a):
        return False
    n = len(a)
    if network == "bitcoin":
        if a.lower().startswith("bc1"):
            return 14 <= n <= 90
        return a[0] in "13" and 25 <= n <= 34
    if network == "dogecoin":
        return a[0] in "DA" and 25 <= n <= 34
    if network == "litecoin":
        if a.lower().startswith("ltc1"):
            return 26 <= n <= 90
        return a[0] in "LM" and 25 <= n <= 34
    if network in EVM_RPCS:
        return a.lower().startswith("0x") and bool(_HEX40.match(a[2:]))
    if network == "solana":
        return 32 <= n <= 44
    if network == "tron":
        return a.startswith("T") and n == 34
    if network == "xrp":
        return a.startswith("r") and 25 <= n <= 35
    if network == "cardano":
        return a.lower().startswith("addr1") and n >= 50
    if network == "cosmos":
        return a.startswith("cosmos1") and n == 45
    if network == "near":
        if n == 64:
            return bool(_HEX64.match(a))
        return 5 <= n <= 64 and "." in a
    return False


def _unreadable(network: str) -> ServiceError:
    return ServiceError(f"Unexpected answer from the {NETWORKS[network].name} network.")


def _jsonrpc(http, url: str, body: dict):
    return call_json(http, "POST", url, json=body, headers={"Content-Type": "application/json"}, timeout=10)


def _evm(http, network: str, address: str) -> float:
    error: Exception = ServiceError("No answer.")
    for url in EVM_RPCS[network]:
        try:
            body = _jsonrpc(http, url, {"jsonrpc": "2.0", "id": 1, "method": "eth_getBalance",
                                        "params": [address, "latest"]})
            hex_wei = body.get("result") if isinstance(body, dict) else None
            if not isinstance(hex_wei, str):
                raise _unreadable(network)
            return int(hex_wei, 16) / 1e18
        except (HttpError, ServiceError, ValueError) as e:
            error = e
    raise error


def _amount(http, network: str, a: str) -> float:
    get = {"Accept": "application/json"}
    if network == "bitcoin":
        body = call_json(http, "GET", f"https://blockchain.info/balance?active={a}&cors=true", headers=get, timeout=10)
        return body[a]["final_balance"] / 1e8
    if network in ("dogecoin", "litecoin"):
        body = call_json(http, "GET", f"https://api.blockchair.com/{network}/dashboards/address/{a}",
                         headers=get, timeout=10)
        value = num(body["data"][a]["address"]["balance"])
        if value is None:
            raise _unreadable(network)
        return value / 1e8
    if network in EVM_RPCS:
        return _evm(http, network, a)
    if network == "solana":
        body = _jsonrpc(http, "https://api.mainnet-beta.solana.com",
                        {"jsonrpc": "2.0", "id": 1, "method": "getBalance", "params": [a]})
        return body["result"]["value"] / 1e9
    if network == "tron":
        rows = call_json(http, "GET", f"https://api.trongrid.io/v1/accounts/{a}", headers=get, timeout=10)["data"]
        return (rows[0].get("balance") or 0) / 1e6 if rows else 0.0
    if network == "xrp":
        body = _jsonrpc(http, "https://xrplcluster.com",
                        {"method": "account_info", "params": [{"account": a, "ledger_index": "current"}]})
        return float(body["result"]["account_data"]["Balance"]) / 1e6
    if network == "cardano":
        rows = call_json(http, "POST", "https://api.koios.rest/api/v1/address_info", json={"_addresses": [a]},
                         headers={"Content-Type": "application/json", "Accept": "application/json"}, timeout=10)
        return float(rows[0].get("balance") or 0) / 1e6
    if network == "cosmos":
        body = call_json(http, "GET", f"https://rest.cosmos.directory/cosmoshub/cosmos/bank/v1beta1/balances/{a}",
                         headers=get, timeout=10)
        return sum(float(b["amount"]) for b in body["balances"] if b.get("denom") == "uatom") / 1e6
    if network == "near":
        body = _jsonrpc(http, "https://rpc.mainnet.near.org", {
            "jsonrpc": "2.0", "id": "dontcare", "method": "query",
            "params": {"request_type": "view_account", "finality": "final", "account_id": a}})
        return int(body["result"]["amount"]) / 1e24   # yoctoNEAR
    raise ServiceError("Unknown network.")


def fetch(http, network: str, address: str) -> list:
    """``[(symbol, amount)]`` for one address. Raises ``ServiceError``/``HttpError``."""
    address = (address or "").strip()
    if not is_plausible(address, network):
        raise ServiceError("That doesn't look like an address on this network.")
    try:
        amount = _amount(http, network, address)
    except (HttpError, ServiceError):
        raise
    except (KeyError, IndexError, TypeError, ValueError, AttributeError):
        raise _unreadable(network) from None
    return [(NETWORKS[network].symbol, amount)]
