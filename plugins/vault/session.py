"""Vault sessions (the X-Vault-Token) and the 6-digit vault passcode.

A token comes only from a fresh Face ID proof or the passcode. It lasts IDLE_S without use and
MAX_S at most, lives in memory only (a webui restart locks the vault) and is revoked by /lock.
Only a SHA-256 of each token is kept.

The passcode is stored as an scrypt hash, peppered with an HMAC key derived from the vault master
key (so the hash file alone can't be brute-forced offline: 10^6 codes is nothing for scrypt), in
``<root>/vault/passcode.json`` with the failure count. A hash from before the pepper (v1) still
checks, and is rewritten peppered on its next successful unlock.
after FREE_TRIES wrong tries it locks out for 30 s, doubling with each further wrong try, and the
lockout survives a restart.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import secrets
import tempfile
import threading
import time
from pathlib import Path
from typing import Callable

IDLE_S = 5 * 60
MAX_S = 30 * 60
FREE_TRIES = 5
FIRST_LOCKOUT_S = 30
MAX_LOCKOUT_S = 24 * 3600
_SCRYPT = {"n": 2 ** 15, "r": 8, "p": 1}
_PASSCODE = re.compile(r"^\d{6}$")


class Sessions:
    def __init__(self, clock: Callable[[], float] = time.time) -> None:
        self.clock = clock
        self._tokens: dict[str, dict] = {}
        self._lock = threading.Lock()

    @staticmethod
    def _digest(token: str) -> str:
        return hashlib.sha256(token.encode()).hexdigest()

    def _sweep(self, now: float) -> None:
        for key, s in list(self._tokens.items()):
            if now - s["last"] > IDLE_S or now - s["created"] > MAX_S:
                del self._tokens[key]

    def issue(self) -> dict:
        token = secrets.token_urlsafe(32)
        now = self.clock()
        with self._lock:
            self._sweep(now)
            self._tokens[self._digest(token)] = {"created": now, "last": now}
        return {"ok": True, "token": token, "idle_s": IDLE_S, "max_s": MAX_S}

    def check(self, token) -> bool:
        """True (and the idle clock restarts) for a live token."""
        if not isinstance(token, str) or not token or len(token) > 200:
            return False
        now = self.clock()
        with self._lock:
            self._sweep(now)
            s = self._tokens.get(self._digest(token))
            if s is None:
                return False
            s["last"] = now
            return True

    def revoke(self, token) -> None:
        if isinstance(token, str) and token:
            with self._lock:
                self._tokens.pop(self._digest(token), None)

    def revoke_all(self) -> None:
        with self._lock:
            self._tokens.clear()


class PasscodeLocked(Exception):
    def __init__(self, retry_after_s: int) -> None:
        super().__init__(f"Too many wrong passcodes. Try again in {retry_after_s} s.")
        self.retry_after_s = retry_after_s


class Passcode:
    def __init__(self, path: Path, clock: Callable[[], float] = time.time,
                 pepper: Callable[[], bytes] | None = None) -> None:
        self.path = path
        self.clock = clock
        self._pepper = pepper
        self._lock = threading.Lock()

    def _peppered(self, digest: bytes) -> bytes:
        if self._pepper is None:
            raise RuntimeError("no pepper")
        return hmac.new(self._pepper(), digest, hashlib.sha256).digest()

    def _read(self) -> dict:
        try:
            data = json.loads(self.path.read_text())
            return data if isinstance(data, dict) else {}
        except (FileNotFoundError, ValueError):
            return {}

    def _write(self, data: dict) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".passcode-", dir=str(self.path.parent))
        try:
            with os.fdopen(fd, "w") as handle:
                handle.write(json.dumps(data))
            os.chmod(tmp, 0o600)
            os.replace(tmp, self.path)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)

    @staticmethod
    def _hash(code: str, salt: bytes, params: dict) -> bytes:
        return hashlib.scrypt(code.encode(), salt=salt, n=params["n"], r=params["r"], p=params["p"],
                              maxmem=256 * 1024 * 1024, dklen=32)

    def is_set(self) -> bool:
        return bool(self._read().get("hash"))

    def retry_after(self) -> int:
        left = float(self._read().get("locked_until") or 0) - self.clock()
        return max(0, int(left + 0.999)) if left > 0 else 0

    def set(self, code) -> None:
        code = str(code or "")
        if not _PASSCODE.match(code):
            raise ValueError("The vault passcode is 6 digits.")
        salt = secrets.token_bytes(16)
        with self._lock:
            self._write({"v": 2, "salt": salt.hex(), "hash": self._peppered(self._hash(code, salt, _SCRYPT)).hex(),
                         **_SCRYPT, "fails": 0, "locked_until": 0})

    def check(self, code) -> bool:
        """True for the right passcode. Raises PasscodeLocked during a lockout (nothing is checked)."""
        with self._lock:
            data = self._read()
            if not data.get("hash"):
                return False
            now = self.clock()
            left = float(data.get("locked_until") or 0) - now
            if left > 0:
                raise PasscodeLocked(max(1, int(left + 0.999)))
            params = {k: int(data.get(k) or _SCRYPT[k]) for k in _SCRYPT}
            digest = self._hash(str(code or ""), bytes.fromhex(data["salt"]), params)
            legacy = int(data.get("v") or 1) < 2
            good = hmac.compare_digest(digest if legacy else self._peppered(digest), bytes.fromhex(data["hash"]))
            if good:
                data["fails"], data["locked_until"] = 0, 0
                if legacy and self._pepper is not None:
                    data["v"], data["hash"] = 2, self._peppered(digest).hex()
            else:
                data["fails"] = int(data.get("fails") or 0) + 1
                over = data["fails"] - FREE_TRIES
                if over >= 0:
                    data["locked_until"] = now + min(MAX_LOCKOUT_S, FIRST_LOCKOUT_S * (2 ** min(over, 20)))
            self._write(data)
            return good
