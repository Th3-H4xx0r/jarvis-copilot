"""Public wallet balances on 16 networks: parsers per family, request shapes, address
format checks."""
from __future__ import annotations

import pytest

from jarvis_services import wallets
from jarvis_services.base import HttpError, ServiceError
from jarvis_services.testing import FakeHttp
from jarvis_services.wallets import NETWORKS, is_plausible

BTC = "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq"
ETH = "0x" + "ab" * 20


def test_sixteen_networks():
    assert list(NETWORKS) == ["bitcoin", "dogecoin", "litecoin", "ethereum", "polygon", "bnb_chain", "avalanche",
                              "arbitrum", "optimism", "base", "solana", "tron", "xrp", "cardano", "cosmos", "near"]
    assert NETWORKS["arbitrum"].symbol == "ETH" and NETWORKS["polygon"].symbol == "POL"


def test_bitcoin_blockchain_info():
    http = FakeHttp().add("GET", f"https://blockchain.info/balance?active={BTC}&cors=true",
                          {BTC: {"final_balance": 150_000_000, "n_tx": 3}})
    assert wallets.fetch(http, "bitcoin", BTC) == [("BTC", 1.5)]


@pytest.mark.parametrize("network,chain,symbol,balance", [
    ("dogecoin", "dogecoin", "DOGE", 250_000_000), ("litecoin", "litecoin", "LTC", "50000000")])
def test_utxo_blockchair(network, chain, symbol, balance):
    addr = "DH5yaieqoZN36fDVciNyRueRGvGLR3mr7L" if network == "dogecoin" else "LcHKx7tLtXAVQ7TzP9Fz3L5kfUpd9oYQ4Z"
    http = FakeHttp().add("GET", f"https://api.blockchair.com/{chain}/dashboards/address/{addr}",
                          {"data": {addr: {"address": {"balance": balance}}}})
    assert wallets.fetch(http, network, addr) == [(symbol, int(balance) / 1e8)]


def test_evm_eth_get_balance_with_rpc_fallback():
    http = FakeHttp().add("POST", "https://ethereum-rpc.publicnode.com", {"error": "busy"}, status=503)
    http.add("POST", "https://cloudflare-eth.com", {"jsonrpc": "2.0", "id": 1, "result": "0x1bc16d674ec80000"})
    assert wallets.fetch(http, "ethereum", ETH) == [("ETH", 2.0)]
    assert http.calls[0].json == {"jsonrpc": "2.0", "id": 1, "method": "eth_getBalance", "params": [ETH, "latest"]}
    assert len(http.calls) == 2


def test_evm_l2_uses_its_own_rpc_and_eth_symbol():
    http = FakeHttp().add("POST", "https://mainnet.base.org", {"result": "0x0"})
    assert wallets.fetch(http, "base", ETH) == [("ETH", 0.0)]


def test_evm_all_rpcs_down_raises():
    http = FakeHttp().fail("POST", "https://polygon-bor-rpc.publicnode.com").fail("POST", "https://polygon-rpc.com")
    with pytest.raises(HttpError):
        wallets.fetch(http, "polygon", ETH)


def test_solana():
    addr = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM"
    http = FakeHttp().add("POST", "https://api.mainnet-beta.solana.com",
                          {"jsonrpc": "2.0", "result": {"context": {"slot": 1}, "value": 3_500_000_000}, "id": 1})
    assert wallets.fetch(http, "solana", addr) == [("SOL", 3.5)]
    assert http.calls[0].json["method"] == "getBalance"


def test_tron_and_empty_account():
    addr = "TLyqzVGLV1srkB7dToTAEqgDSfPtXRJZYH"
    http = FakeHttp().add("GET", f"https://api.trongrid.io/v1/accounts/{addr}", {"data": [{"balance": 12_000_000}]})
    assert wallets.fetch(http, "tron", addr) == [("TRX", 12.0)]
    empty = FakeHttp().add("GET", f"https://api.trongrid.io/v1/accounts/{addr}", {"data": [], "success": True})
    assert wallets.fetch(empty, "tron", addr) == [("TRX", 0.0)]


def test_xrp():
    addr = "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh"
    http = FakeHttp().add("POST", "https://xrplcluster.com",
                          {"result": {"account_data": {"Balance": "25000000"}, "status": "success"}})
    assert wallets.fetch(http, "xrp", addr) == [("XRP", 25.0)]
    assert http.calls[0].json == {"method": "account_info",
                                  "params": [{"account": addr, "ledger_index": "current"}]}


def test_cardano_koios():
    addr = "addr1" + "q" * 98
    http = FakeHttp().add("POST", "https://api.koios.rest/api/v1/address_info", [{"balance": "7500000"}])
    assert wallets.fetch(http, "cardano", addr) == [("ADA", 7.5)]
    assert http.calls[0].json == {"_addresses": [addr]}


def test_cosmos_only_uatom():
    addr = "cosmos1" + "q" * 38
    http = FakeHttp().add("GET", f"https://rest.cosmos.directory/cosmoshub/cosmos/bank/v1beta1/balances/{addr}",
                          {"balances": [{"denom": "uatom", "amount": "4200000"}, {"denom": "ibc/X", "amount": "9"}]})
    assert wallets.fetch(http, "cosmos", addr) == [("ATOM", 4.2)]


def test_near_yocto():
    http = FakeHttp().add("POST", "https://rpc.mainnet.near.org",
                          {"result": {"amount": "1500000000000000000000000"}})
    assert wallets.fetch(http, "near", "alice.near") == [("NEAR", 1.5)]
    assert http.calls[0].json["params"] == {"request_type": "view_account", "finality": "final",
                                             "account_id": "alice.near"}


def test_unreadable_answer_is_a_service_error():
    http = FakeHttp().add("POST", "https://api.mainnet-beta.solana.com", {"jsonrpc": "2.0", "error": {"code": -1}})
    with pytest.raises(ServiceError):
        wallets.fetch(http, "solana", "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM")


@pytest.mark.parametrize("network,address,ok", [
    ("bitcoin", BTC, True), ("bitcoin", "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2", True),
    ("bitcoin", "3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy", True), ("bitcoin", "xyz", False),
    ("dogecoin", "DH5yaieqoZN36fDVciNyRueRGvGLR3mr7L", True), ("dogecoin", "XH5yaieqoZN36fDVciNyRueRGvGLR3mr7L", False),
    ("litecoin", "ltc1qg82e8w9a7c4w5xk0jm3gk5r0x9yqz7v5a4h8d0", True),
    ("litecoin", "LcHKx7tLtXAVQ7TzP9Fz3L5kfUpd9oYQ4Z", True),
    ("ethereum", ETH, True), ("base", "0x" + "g" * 40, False), ("bnb_chain", "0x1234", False),
    ("solana", "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM", True), ("solana", "short", False),
    ("tron", "TLyqzVGLV1srkB7dToTAEqgDSfPtXRJZYH", True), ("tron", "ALyqzVGLV1srkB7dToTAEqgDSfPtXRJZYH", False),
    ("xrp", "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh", True), ("xrp", "xHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh", False),
    ("cardano", "addr1" + "q" * 98, True), ("cardano", "addr1short", False),
    ("cosmos", "cosmos1" + "q" * 38, True), ("cosmos", "cosmos1" + "q" * 10, False),
    ("near", "alice.near", True), ("near", "a" * 64, True), ("near", "nodot", False),
    ("solana", "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYd/../x", False),     # never anything that could leave the path
    ("unknown", BTC, False),
])
def test_is_plausible(network, address, ok):
    assert is_plausible(address, network) is ok


def test_fetch_refuses_implausible_addresses():
    with pytest.raises(ServiceError):
        wallets.fetch(FakeHttp(), "tron", "T/../../x")
