"""JarvisCopilot device pairing.

The CLI (`jarviscopilot pair`) and the webui server coordinate through a
shared file under ``STATE_DIR``. This avoids the chicken-and-egg of "the
CLI needs to create a pairing code, but the webui's API requires auth":
the CLI doesn't talk HTTP to the webui at all — it just appends a code
to a 0600-mode file that the webui reads on claim.

Flow:
1. CLI calls ``create_pairing_code()`` → appends a row to
   ``.pending_pair.json`` and returns the code + expiry.
2. CLI displays the code in its TUI and polls
   ``poll_pairing_code(code)`` every ~500ms.
3. User opens ``/pair`` on a new device, types the code.
4. Webui calls ``claim_pairing_code(code, device_name, ip, ua)`` which:
     - validates the code is present and not expired,
     - marks the row claimed,
     - registers the device in ``.devices.json``,
     - returns a freshly-issued session cookie value (via
       ``auth.create_session()``).
5. CLI sees ``claimed=True``, reports success, exits 0.

Pairing codes are 7 chars (``XXX-XXX``) drawn from an alphabet that
excludes ambiguous glyphs (0/O, 1/I/L). At 28^6 ≈ 481M combos, with a
10-minute TTL and 5-attempts-per-minute rate limiting on the claim
endpoint, brute force is not a realistic threat.
"""
from __future__ import annotations

import json
import logging
import os
import secrets
import tempfile
import threading
import time
import uuid
from pathlib import Path
from typing import Optional

from api.config import STATE_DIR

logger = logging.getLogger(__name__)

# Alphabet excludes O/0, I/1/L to keep codes unambiguous when read aloud
# or copied off a screen onto a phone.
_PAIR_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
_PAIR_CODE_LEN = 6  # split as XXX-XXX → 7 visible chars w/ dash

_PENDING_FILE = STATE_DIR / ".pending_pair.json"
_DEVICES_FILE = STATE_DIR / ".devices.json"

_PAIR_DEFAULT_TTL = 600  # 10 minutes
_PAIR_MAX_PENDING = 16   # cap entries so a runaway CLI can't bloat the file

_LOCK = threading.Lock()


# ── env / settings helpers ──────────────────────────────────────────────────

def is_pairing_required() -> bool:
    """True when every non-public request must present a valid session.

    Source priority: env var ``JARVISCOPILOT_PAIRING_REQUIRED`` > settings
    key ``pairing_required`` > default OFF. The env var wins so the
    systemd unit / launcher can flip it on without rewriting settings.
    """
    env = os.getenv("JARVISCOPILOT_PAIRING_REQUIRED", "").strip().lower()
    if env in ("1", "true", "yes", "on"):
        return True
    if env in ("0", "false", "no", "off"):
        return False
    try:
        from api.config import load_settings
        return bool(load_settings().get("pairing_required"))
    except Exception:
        return False


# ── disk IO ─────────────────────────────────────────────────────────────────

def _atomic_write_json(path: Path, data) -> None:
    """Write JSON atomically with 0600 perms. Replaces existing file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, suffix=path.name + ".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, separators=(",", ":"))
        try:
            os.chmod(tmp, 0o600)
        except OSError:
            pass  # Windows; chmod is best-effort there
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _read_pending() -> dict:
    """Read .pending_pair.json or return empty shape. Prunes expired rows."""
    try:
        if _PENDING_FILE.exists():
            data = json.loads(_PENDING_FILE.read_text(encoding="utf-8"))
            if isinstance(data, dict) and isinstance(data.get("codes"), list):
                now = time.time()
                # Keep claimed entries around for a short grace window so
                # the CLI can read the "claimed" state before we drop it.
                data["codes"] = [
                    c for c in data["codes"]
                    if isinstance(c, dict)
                    and isinstance(c.get("expires"), (int, float))
                    and (c["expires"] > now or (c.get("claimed") and c.get("claimed_at", 0) > now - 60))
                ]
                return data
    except Exception as exc:
        logger.debug("pending pair read failed (resetting): %s", exc)
    return {"codes": []}


def _write_pending(data: dict) -> None:
    _atomic_write_json(_PENDING_FILE, data)


def _read_devices() -> dict:
    try:
        if _DEVICES_FILE.exists():
            data = json.loads(_DEVICES_FILE.read_text(encoding="utf-8"))
            if isinstance(data, dict) and isinstance(data.get("devices"), list):
                return data
    except Exception as exc:
        logger.debug("devices read failed (resetting): %s", exc)
    return {"devices": []}


def _write_devices(data: dict) -> None:
    _atomic_write_json(_DEVICES_FILE, data)


# ── code lifecycle ──────────────────────────────────────────────────────────

def _gen_code() -> str:
    raw = "".join(secrets.choice(_PAIR_ALPHABET) for _ in range(_PAIR_CODE_LEN))
    return f"{raw[:3]}-{raw[3:]}"


def create_pairing_code(label: Optional[str] = None,
                        ttl: int = _PAIR_DEFAULT_TTL) -> dict:
    """Generate a fresh pairing code and persist it for the webui to claim.

    Returns ``{"code", "expires_at", "ttl", "created_at"}``. Caller (the
    CLI) shows ``code`` to the user and polls ``poll_pairing_code(code)``.
    """
    ttl = max(60, min(int(ttl), 3600))
    with _LOCK:
        pending = _read_pending()
        # Prevent collisions with any live code (cheap because list is small).
        live = {c.get("code") for c in pending["codes"]}
        for _ in range(10):
            code = _gen_code()
            if code not in live:
                break
        else:
            # Astronomically unlikely; just use the last one and let the
            # claim path fail if it ever does collide.
            pass
        now = time.time()
        row = {
            "code": code,
            "label": (label or "").strip()[:64] or None,
            "created_at": now,
            "expires": now + ttl,
            "claimed": False,
            "claimed_at": None,
            "device_name": None,
            "device_ip": None,
        }
        pending["codes"].append(row)
        # Trim oldest unclaimed entries if cap exceeded.
        if len(pending["codes"]) > _PAIR_MAX_PENDING:
            pending["codes"].sort(key=lambda c: (c.get("claimed", False), c.get("created_at", 0)))
            pending["codes"] = pending["codes"][-_PAIR_MAX_PENDING:]
        _write_pending(pending)
        return {
            "code": code,
            "created_at": now,
            "expires_at": now + ttl,
            "ttl": ttl,
        }


def poll_pairing_code(code: str) -> dict:
    """Return the current state of a pairing code for the CLI.

    Status values:
      - ``waiting`` — code is valid, still unclaimed
      - ``claimed`` — a device has successfully paired
      - ``expired`` — TTL elapsed without a claim
      - ``unknown`` — code not in the pending file (already pruned or never created)
    """
    pending = _read_pending()
    now = time.time()
    for row in pending["codes"]:
        if row.get("code") != code:
            continue
        if row.get("claimed"):
            return {
                "status": "claimed",
                "device_name": row.get("device_name"),
                "device_ip": row.get("device_ip"),
                "claimed_at": row.get("claimed_at"),
            }
        if row.get("expires", 0) <= now:
            return {"status": "expired"}
        return {
            "status": "waiting",
            "expires_at": row.get("expires"),
            "ttl_remaining": max(0, int(row.get("expires", now) - now)),
        }
    return {"status": "unknown"}


def cancel_pairing_code(code: str) -> bool:
    """Remove a code (CLI calls this on Ctrl-C). Returns True if removed."""
    with _LOCK:
        pending = _read_pending()
        before = len(pending["codes"])
        pending["codes"] = [c for c in pending["codes"] if c.get("code") != code]
        if len(pending["codes"]) != before:
            _write_pending(pending)
            return True
        return False


def claim_pairing_code(code: str, *, device_name: str = "",
                       device_ip: str = "", user_agent: str = "") -> Optional[str]:
    """Validate ``code`` and, on success, return a new session cookie value.

    Called by the webui's ``/api/auth/pair/claim`` POST handler. Returns
    None when the code is invalid / expired / already claimed. On success
    the pending row is marked claimed (so the CLI's poll picks it up) and
    a device record is persisted to ``.devices.json``.
    """
    code = (code or "").strip().upper().replace(" ", "")
    # Tolerate both "ABC-XYZ" and "ABCXYZ" input.
    if len(code) == _PAIR_CODE_LEN and "-" not in code:
        code = f"{code[:3]}-{code[3:]}"
    with _LOCK:
        pending = _read_pending()
        now = time.time()
        for row in pending["codes"]:
            if row.get("code") != code:
                continue
            if row.get("claimed") or row.get("expires", 0) <= now:
                return None
            # Mint a session via the existing auth module so cookie sign /
            # verify / TTL behavior is identical to password-based logins.
            from api.auth import create_session
            cookie_val = create_session()
            row["claimed"] = True
            row["claimed_at"] = now
            row["device_name"] = (device_name or "").strip()[:64] or "device"
            row["device_ip"] = device_ip or ""
            _write_pending(pending)
            # Persist a device entry. Token *value* isn't stored — we only
            # keep the prefix for display in `jarviscopilot pair list` so a
            # compromised devices.json can't be replayed.
            devices = _read_devices()
            devices["devices"].append({
                "id": uuid.uuid4().hex,
                "name": row["device_name"],
                "ip": row["device_ip"],
                "user_agent": (user_agent or "")[:200],
                "paired_at": now,
                "session_prefix": cookie_val.split(".", 1)[0][:8],
                "last_seen": now,
            })
            # Cap device list at 64 most recent.
            devices["devices"] = devices["devices"][-64:]
            _write_devices(devices)
            return cookie_val
        return None


# ── device management (for future CLI subcommands / settings page) ─────────

def list_devices() -> list:
    return list(_read_devices().get("devices", []))


def revoke_device(device_id: str) -> bool:
    """Remove a device record. Sessions live in auth's .sessions.json and
    expire on their own TTL; full revocation also requires invalidating
    the corresponding session, which we don't track here yet."""
    with _LOCK:
        devices = _read_devices()
        before = len(devices["devices"])
        devices["devices"] = [d for d in devices["devices"] if d.get("id") != device_id]
        if len(devices["devices"]) != before:
            _write_devices(devices)
            return True
        return False
