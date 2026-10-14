"""Settings → Services: the config the clients edit, validated, never echoing a secret.

* ``config_payload(hub)``: every service, exchange, the crypto watchlist, wallets and
  networks, with ``has_key`` booleans in place of secrets.
* ``update_config(hub, body)``: one of ``{"service": id, "secrets": {...}, "settings": {...}}``,
  ``{"exchange": id, "secrets": {...}}`` or ``{"crypto": {...}}``; a secret set to null or
  "" is removed. Raises ``ValueError`` (a message to show) on a bad request.
* ``update_wallets(hub, body)``: ``{"op": "add", "network", "address", "label"?}`` (format
  check + one test fetch first) or ``{"op": "remove", "network", "address"}``.

after coucou (github.com/Louis-CFM/coucou, MIT)
"""
from __future__ import annotations

import base64
import binascii
import re
from typing import Any, Optional
from urllib.parse import urlsplit

from cryptography.hazmat.primitives import serialization

from jarvis_services import crypto, exchanges, wallets
from jarvis_services.base import ServiceError, describe
from jarvis_services.portfolio import configured_wallets, short_address

_KEY = re.compile(r"^\S{8,1024}$")
_PASSPHRASE = re.compile(r"^[^\r\n]{1,256}$")
_EMAIL = re.compile(r"^[^@\s]{1,64}@[^@\s]{1,189}\.[^@\s]{1,63}$")
MAX_WALLETS = 50
MAX_LIST = 50


def _has(view, env: str) -> bool:
    return bool(view.secret(env))


def config_payload(hub) -> dict:
    view = hub.config.load()
    services = []
    for svc in hub.services:
        if svc.topic != "services":
            continue
        services.append({
            "id": svc.id, "display_name": svc.display_name, "configured": svc.configured(view),
            "secrets": [{"name": f, "label": svc.secret_labels.get(f, f), "has_key": _has(view, env)}
                        for f, env in svc.secrets.items()],
            "settings": {k: view.setting(svc.id, k, default) for k, default in svc.settings.items()},
        })
    exchange_rows = []
    for spec in exchanges.EXCHANGES.values():
        fields = [{"name": f, "label": spec.labels[f], "has_key": _has(view, exchanges.env_name(spec.id, f))}
                  for f in spec.fields]
        exchange_rows.append({"id": spec.id, "display_name": spec.name,
                              "configured": all(f["has_key"] for f in fields), "secrets": fields})
    return {
        "services": services,
        "exchanges": exchange_rows,
        "crypto": {**crypto.CryptoService.options(view), "exchanges": list(crypto.EXCHANGES),
                   "currencies": list(crypto.CURRENCIES), "max_coins": crypto.MAX_COINS},
        "wallets": configured_wallets(view),
        "networks": [{"id": n.id, "name": n.name, "symbol": n.symbol, "placeholder": n.placeholder}
                     for n in wallets.NETWORKS.values()],
    }


# ── validation ──────────────────────────────────────────────────────────────────

def _secret_value(owner: str, field: str, raw: Any) -> Optional[str]:
    """The value to store, or None to remove it."""
    if raw is None or raw == "":
        return None
    if not isinstance(raw, str):
        raise ValueError(f"{field} must be text.")
    value = raw.strip()
    if owner == "coinbase" and field == "secret":
        key = exchanges.coinbase_private_key(value)
        if key is None:
            raise ValueError("That Coinbase private key couldn't be read. Paste the whole EC private key.")
        # One line, no spaces: the DER body (PKCS#8), which .env files keep intact.
        der = key.private_bytes(serialization.Encoding.DER, serialization.PrivateFormat.PKCS8,
                                serialization.NoEncryption())
        return base64.b64encode(der).decode()
    if field == "passphrase":
        if not _PASSPHRASE.match(value):
            raise ValueError("The passphrase must be one line.")
        return value
    if not _KEY.match(value):
        raise ValueError("That doesn't look like a key (8+ characters, no spaces).")
    if owner == "kraken" and field == "secret":
        try:
            base64.b64decode(value, validate=True)
        except (binascii.Error, ValueError):
            raise ValueError("The Kraken private key is base64 text; copy it again.") from None
    return value


def _text_list(field: str, raw: Any) -> list:
    if not isinstance(raw, list) or len(raw) > MAX_LIST or not all(isinstance(x, str) for x in raw):
        raise ValueError(f"{field} must be a list of names.")
    return [x.strip()[:200] for x in raw if x.strip()]


def _setting(service_id: str, key: str, raw: Any) -> Any:
    if service_id == "n8n" and key == "url":
        url = str(raw or "").strip().rstrip("/") if isinstance(raw, (str, type(None))) else None
        if url is None:
            raise ValueError("The n8n address must be text.")
        if url:
            parts = urlsplit(url)
            if parts.scheme not in ("http", "https") or not parts.netloc or len(url) > 512:
                raise ValueError("The n8n address must start with https:// (or http://).")
        return url
    if key in ("workflows", "projects"):
        return _text_list(key, raw)
    if service_id == "resend" and key == "from":
        value = str(raw or "").strip() if isinstance(raw, (str, type(None))) else None
        if value is None or (value and not _EMAIL.match(value)):
            raise ValueError("The from address must be an email address.")
        return value
    raise ValueError(f"Unknown setting: {key}")


def _crypto_settings(raw: Any) -> dict:
    if not isinstance(raw, dict):
        raise ValueError("crypto must be an object.")
    out: dict = {}
    for key, value in raw.items():
        if key in ("enabled", "alert_enabled"):
            if not isinstance(value, bool):
                raise ValueError(f"{key} must be true or false.")
            out[key] = value
        elif key == "exchange":
            if value not in crypto.EXCHANGES:
                raise ValueError("The exchange must be Coinbase or OKX.")
            out[key] = value
        elif key == "currency":
            if value not in crypto.CURRENCIES:
                raise ValueError("The currency must be USD or EUR.")
            out[key] = value
        elif key == "coins":
            if not isinstance(value, (str, list)):
                raise ValueError("coins must be text or a list.")
            out[key] = crypto.parse_coins(value)
        elif key == "alert_percent":
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not 0.1 <= value <= 100:
                raise ValueError("The alert threshold must be between 0.1 and 100 %.")
            out[key] = float(value)
        else:
            raise ValueError(f"Unknown crypto setting: {key}")
    return out


def _secrets_updates(owner: str, envs: dict, raw: Any) -> dict:
    if raw is None:
        return {}
    if not isinstance(raw, dict):
        raise ValueError("secrets must be an object.")
    updates = {}
    for field, value in raw.items():
        if field not in envs:
            raise ValueError(f"Unknown field: {field}")
        updates[envs[field]] = _secret_value(owner, field, value)
    return updates


def update_config(hub, body: Any) -> dict:
    body = body if isinstance(body, dict) else {}
    if "crypto" in body:
        hub.config.save_settings("crypto", _crypto_settings(body["crypto"]))
        hub.wake("crypto")
        return config_payload(hub)
    if "exchange" in body:
        spec = exchanges.EXCHANGES.get(body.get("exchange"))
        if spec is None:
            raise ValueError("Unknown exchange.")
        envs = {f: exchanges.env_name(spec.id, f) for f in spec.fields}
        updates = _secrets_updates(spec.id, envs, body.get("secrets"))
        if updates:
            hub.config.set_secrets(updates)
        hub.wake("portfolio")
        return config_payload(hub)
    svc = next((s for s in hub.services if s.topic == "services" and s.id == body.get("service")), None)
    if svc is None:
        raise ValueError("Unknown service.")
    updates = _secrets_updates(svc.id, dict(svc.secrets), body.get("secrets"))
    raw_settings = body.get("settings") or {}
    if not isinstance(raw_settings, dict):
        raise ValueError("settings must be an object.")
    settings = {}
    for key, value in raw_settings.items():
        if key not in svc.settings:
            raise ValueError(f"Unknown setting: {key}")
        settings[key] = _setting(svc.id, key, value)
    if settings:
        hub.config.save_settings(svc.id, settings)
    if updates:
        hub.config.set_secrets(updates)
    hub.wake(svc.id)
    return config_payload(hub)


def update_wallets(hub, body: Any) -> dict:
    body = body if isinstance(body, dict) else {}
    op, network = body.get("op"), body.get("network")
    address = str(body.get("address") or "").strip()
    current = configured_wallets(hub.config.load())
    if op == "remove":
        kept = [w for w in current if not (w["network"] == network and w["address"] == address)]
        if len(kept) == len(current):
            raise KeyError("wallet not found")
        hub.config.save_settings("portfolio", {"wallets": kept})
        hub.wake("portfolio")
        return {"ok": True, "wallets": kept}
    if op != "add":
        raise ValueError('op must be "add" or "remove".')
    net = wallets.NETWORKS.get(network)
    if net is None:
        raise ValueError("Unknown network.")
    if not wallets.is_plausible(address, network):
        raise ValueError(f"That doesn't look like a {net.name} address ({net.placeholder}).")
    label = body.get("label")
    if label is not None and (not isinstance(label, str) or len(label) > 64):
        raise ValueError("The label must be text, 64 characters at most.")
    kept = [w for w in current if not (w["network"] == network and w["address"] == address)]
    if len(kept) >= MAX_WALLETS:
        raise ValueError(f"At most {MAX_WALLETS} wallets.")
    try:
        holdings = wallets.fetch(hub.http, network, address)
    except ServiceError as e:
        raise ValueError(f"Couldn't read {short_address(address)} on {net.name}: {describe(e, net.name)}") from None
    kept.append({"network": network, "address": address, "label": (label or "").strip()})
    hub.config.save_settings("portfolio", {"wallets": kept})
    hub.wake("portfolio")
    return {"ok": True, "wallets": kept, "holdings": [{"symbol": s, "amount": a} for s, a in holdings]}
