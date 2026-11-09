"""Security Advisor settings: the ``security_advisor`` section of config.yaml."""
from __future__ import annotations

import copy
import ipaddress
import time

DEFAULTS = {
    "alert_cap_per_hour": 3,
    "digest_hour": 8,
    "block_ttl_hours": 24,
    "quiet_hours": [23, 7],
    "usual_hours": [6, 23],
    "file_poll_s": 300,
    "disabled_rules": [],
    "known_ssh_ips": [],
    # ip -> unix time the "Allow" exception expires (set from an alert's Allow button)
    "exceptions": {},
}

MAX_LIST = 200
EXCEPTION_MAX_S = 7 * 86400  # an Allow lasts a week at most

_INT_RANGES = {
    "alert_cap_per_hour": (0, 60),
    "digest_hour": (0, 23),
    "block_ttl_hours": (1, 24 * 30),
    "file_poll_s": (30, 86400),
}


def _hours(value, key):
    if (not isinstance(value, (list, tuple)) or len(value) != 2
            or not all(isinstance(h, int) and not isinstance(h, bool) and 0 <= h <= 23 for h in value)):
        raise ValueError(f"{key} must be two hours 0-23")
    return [int(value[0]), int(value[1])]


def _clean(patch: dict) -> dict:
    if not isinstance(patch, dict):
        raise ValueError("settings must be an object")
    out = {}
    for key, value in patch.items():
        if key not in DEFAULTS:
            raise ValueError(f"unknown setting: {key}")
        if key in _INT_RANGES:
            lo, hi = _INT_RANGES[key]
            if isinstance(value, bool) or not isinstance(value, int) or not lo <= value <= hi:
                raise ValueError(f"{key} must be a whole number {lo}-{hi}")
            out[key] = value
        elif key in ("quiet_hours", "usual_hours"):
            out[key] = _hours(value, key)
        elif key == "disabled_rules":
            from plugins.security_advisor.rules import RULES
            names = {r["name"] for r in RULES}
            if (not isinstance(value, list) or len(value) > MAX_LIST
                    or not all(isinstance(v, str) and v in names for v in value)):
                raise ValueError("disabled_rules must be a list of rule names")
            out[key] = sorted(set(value))
        elif key == "known_ssh_ips":
            if (not isinstance(value, list) or len(value) > MAX_LIST
                    or not all(isinstance(v, str) for v in value)):
                raise ValueError(f"known_ssh_ips must be a list of at most {MAX_LIST} addresses")
            try:
                out[key] = [str(ipaddress.ip_address(str(v).strip())) for v in value]
            except ValueError:
                raise ValueError("known_ssh_ips must hold IP addresses") from None
        elif key == "exceptions":
            if not isinstance(value, dict) or len(value) > MAX_LIST:
                raise ValueError("exceptions must map IP to expiry")
            cap = time.time() + EXCEPTION_MAX_S
            try:
                out[key] = {str(ipaddress.ip_address(k)): min(float(v), cap)
                            for k, v in value.items()}
            except (TypeError, ValueError):
                raise ValueError("exceptions must map IP to expiry") from None
    return out


def load() -> dict:
    """Current settings: defaults overlaid with config.yaml ``security_advisor``."""
    merged = copy.deepcopy(DEFAULTS)
    try:
        from jarviscopilot_cli.config import read_raw_config
        raw = read_raw_config().get("security_advisor") or {}
    except Exception:
        raw = {}
    if isinstance(raw, dict):
        for key, value in raw.items():
            if key in DEFAULTS:
                try:
                    merged.update(_clean({key: value}))
                except ValueError:
                    pass  # a hand-edited bad value falls back to the default
    return merged


def save(patch: dict) -> dict:
    """Validate ``patch`` (ValueError on anything bad), write it, return the new settings."""
    clean = _clean(patch)
    from jarviscopilot_cli.config import read_raw_config, save_config
    cfg = read_raw_config()
    section = cfg.get("security_advisor") if isinstance(cfg.get("security_advisor"), dict) else {}
    section.update(clean)
    cfg["security_advisor"] = section
    save_config(cfg)
    return load()
