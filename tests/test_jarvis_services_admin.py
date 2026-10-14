"""Settings → Services: what the config endpoints show (never a secret) and accept."""
from __future__ import annotations

import json

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from jarvis_services import admin, default_services
from jarvis_services.config import ServicesConfig
from jarvis_services.exchanges import coinbase_private_key
from jarvis_services.loop import ServicesHub
from jarvis_services.testing import FakeHttp

ETH = "0x" + "ab" * 20


def _writer(path, updates):
    from jarvis_services.config import _read_env_file
    values = _read_env_file(path)
    for k, v in updates.items():
        if v is None:
            values.pop(k, None)
        else:
            assert "\n" not in v and "\r" not in v       # what api.providers._write_env_file enforces
            values[k] = v
    path.write_text("".join(f"{k}={v}\n" for k, v in values.items()))


@pytest.fixture()
def hub(tmp_path):
    http = FakeHttp()
    h = ServicesHub(default_services(), ServicesConfig(home_fn=lambda: tmp_path, write_env=_writer), http=http,
                    publish=lambda *a: None, notify=lambda *a: None)
    h.home = tmp_path
    return h


def entry(payload, key, ident):
    return next(x for x in payload[key] if x["id"] == ident)


def test_payload_lists_every_service_exchange_and_network(hub):
    p = admin.config_payload(hub)
    assert [s["id"] for s in p["services"]] == ["github", "stripe", "vercel", "resend", "calcom", "n8n", "notion"]
    assert [e["id"] for e in p["exchanges"]] == ["binance", "okx", "bybit", "kraken", "coinbase"]
    assert len(p["networks"]) == 16
    n8n = entry(p, "services", "n8n")
    assert n8n == {"id": "n8n", "display_name": "n8n", "configured": False,
                   "secrets": [{"name": "api_key", "label": "API key", "has_key": False}],
                   "settings": {"url": "", "workflows": []}}
    assert p["crypto"]["enabled"] is False and p["crypto"]["alert_percent"] == 5.0
    assert p["crypto"]["exchanges"] == ["coinbase", "okx"] and p["crypto"]["max_coins"] == 8
    assert p["wallets"] == []


def test_set_and_clear_a_key_never_returns_it(hub):
    p = admin.update_config(hub, {"service": "stripe", "secrets": {"api_key": "sk_live_SECRET123"}})
    assert entry(p, "services", "stripe")["secrets"][0]["has_key"] is True
    assert entry(p, "services", "stripe")["configured"] is True
    assert "sk_live_SECRET123" not in json.dumps(p)
    assert "SERVICES_STRIPE_API_KEY=sk_live_SECRET123" in (hub.home / ".env").read_text()
    p = admin.update_config(hub, {"service": "stripe", "secrets": {"api_key": None}})
    assert entry(p, "services", "stripe")["secrets"][0]["has_key"] is False


def test_settings_go_to_services_json_not_env(hub):
    admin.update_config(hub, {"service": "n8n", "secrets": {"api_key": "n8n_key_123456"},
                              "settings": {"url": "https://n8n.example.com/", "workflows": ["Sync", " "]}})
    stored = json.loads((hub.home / "services.json").read_text())
    assert stored["n8n"] == {"url": "https://n8n.example.com", "workflows": ["Sync"]}
    assert "n8n.example.com" not in (hub.home / ".env").read_text()
    assert entry(admin.config_payload(hub), "services", "n8n")["configured"] is True


@pytest.mark.parametrize("body", [
    {"service": "nope", "secrets": {"api_key": "x" * 10}},
    {"service": "stripe", "secrets": {"token": "x" * 10}},
    {"service": "stripe", "secrets": {"api_key": "has space inside"}},
    {"service": "stripe", "secrets": {"api_key": "short"}},
    {"service": "stripe", "secrets": {"api_key": 12345678}},
    {"service": "stripe", "settings": {"anything": 1}},
    {"service": "n8n", "settings": {"url": "file:///etc/passwd"}},
    {"service": "n8n", "settings": {"url": "javascript:alert(1)"}},
    {"service": "vercel", "settings": {"projects": "site"}},
    {"service": "resend", "settings": {"from": "not-an-email"}},
    {"crypto": {"exchange": "binance"}},
    {"crypto": {"currency": "JPY"}},
    {"crypto": {"alert_percent": 0}},
    {"crypto": {"enabled": "yes"}},
    {"crypto": {"surprise": True}},
    {"exchange": "ftx", "secrets": {"key": "x" * 10}},
    {"exchange": "kraken", "secrets": {"secret": "not base64!!"}},
    {"exchange": "coinbase", "secrets": {"secret": "-----BEGIN EC PRIVATE KEY-----\nnope\n-----END EC PRIVATE KEY-----"}},
    {},
])
def test_bad_requests_are_refused(hub, body):
    with pytest.raises(ValueError):
        admin.update_config(hub, body)


def test_crypto_settings(hub):
    p = admin.update_config(hub, {"crypto": {"enabled": True, "coins": "btc, eth, doge", "exchange": "okx",
                                             "currency": "EUR", "alert_enabled": True, "alert_percent": 3}})
    assert p["crypto"]["coins"] == ["BTC", "ETH", "DOGE"] and p["crypto"]["exchange"] == "okx"
    assert json.loads((hub.home / "services.json").read_text())["crypto"]["alert_percent"] == 3.0


def test_okx_needs_all_three_and_passphrase_may_be_short(hub):
    admin.update_config(hub, {"exchange": "okx", "secrets": {"key": "okx-key-123", "secret": "okx-secret-123"}})
    assert entry(admin.config_payload(hub), "exchanges", "okx")["configured"] is False
    p = admin.update_config(hub, {"exchange": "okx", "secrets": {"passphrase": "pp"}})
    okx = entry(p, "exchanges", "okx")
    assert okx["configured"] is True and all(f["has_key"] for f in okx["secrets"])
    assert [f["name"] for f in okx["secrets"]] == ["key", "secret", "passphrase"]


def test_coinbase_private_key_is_stored_on_one_line(hub):
    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL,
                            serialization.NoEncryption()).decode()
    admin.update_config(hub, {"exchange": "coinbase",
                              "secrets": {"key": "organizations/o/apiKeys/k", "secret": pem}})
    stored = hub.config.load().secret("PORTFOLIO_COINBASE_SECRET")
    assert "\n" not in stored and " " not in stored
    assert coinbase_private_key(stored).private_numbers().private_value == key.private_numbers().private_value


def test_add_wallet_validates_and_test_fetches(hub):
    with pytest.raises(ValueError) as e:
        admin.update_wallets(hub, {"op": "add", "network": "ethereum", "address": "0x123"})
    assert "doesn't look like" in str(e.value)
    with pytest.raises(ValueError):
        admin.update_wallets(hub, {"op": "add", "network": "dogecoinz", "address": ETH})
    hub.http.add("POST", "https://ethereum-rpc.publicnode.com", {"error": "x"}, status=503)
    hub.http.add("POST", "https://cloudflare-eth.com", {"error": "x"}, status=503)
    with pytest.raises(ValueError) as e:
        admin.update_wallets(hub, {"op": "add", "network": "ethereum", "address": ETH})
    assert "Couldn't read" in str(e.value)
    assert admin.config_payload(hub)["wallets"] == []


def test_add_and_remove_wallet(hub):
    hub.http.add("POST", "https://ethereum-rpc.publicnode.com", {"result": "0xde0b6b3a7640000"})
    hub.http.add("POST", "https://mainnet.base.org", {"result": "0x0"})
    out = admin.update_wallets(hub, {"op": "add", "network": "ethereum", "address": ETH, "label": "Ledger"})
    assert out["ok"] is True and out["holdings"] == [{"symbol": "ETH", "amount": 1.0}]
    admin.update_wallets(hub, {"op": "add", "network": "base", "address": ETH})             # same address, other chain
    admin.update_wallets(hub, {"op": "add", "network": "ethereum", "address": ETH, "label": "Cold"})   # replaces
    wallets = admin.config_payload(hub)["wallets"]
    assert wallets == [{"network": "base", "address": ETH, "label": ""},
                       {"network": "ethereum", "address": ETH, "label": "Cold"}]
    out = admin.update_wallets(hub, {"op": "remove", "network": "base", "address": ETH})
    assert out["wallets"] == [{"network": "ethereum", "address": ETH, "label": "Cold"}]
    with pytest.raises(KeyError):
        admin.update_wallets(hub, {"op": "remove", "network": "base", "address": ETH})
    with pytest.raises(ValueError):
        admin.update_wallets(hub, {"op": "rename"})
