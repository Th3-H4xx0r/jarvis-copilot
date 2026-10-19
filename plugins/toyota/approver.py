"""Face ID for car commands: the phone's Secure Enclave key, and approvals waiting for it.

Pranav's iPhone holds a P-256 key in its Secure Enclave that only signs after Face ID. The server
keeps the public half and runs a gated command (everything but stop) only with a fresh signature
over ``jarvis-car|<command>|<nonce>|<unix_ts>`` from that key: under a minute old, the nonce never
seen before. A request from Jarvis becomes an approval the phone signs instead.

A second phone key, the button key, has no Face ID: it signs Control Center / widget / ring presses
set to skip Face ID, over ``jarvis-button|<domain>|<command>|<nonce>|<unix_ts>``. The Face ID key
vouches for it once; it is dropped whenever the Face ID key is replaced, and it only ever passes for
the door alarm's disarm/silence and the car's commands — never an approval or a key change.

Lives in the webui process, which owns the key file, the used nonces and the approvals. Limits, by
design: anything that can act as this server's user (a shell on it) can call Home Assistant
directly with the server's token — Face ID guards every client and tool, not a compromised host.
"""
from __future__ import annotations

import base64
import json
import os
import secrets
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Callable

MAX_AGE = 60          # seconds a signature stays good
NONCE_MEMORY = 300    # seconds a used nonce is remembered (well past MAX_AGE)
APPROVAL_TTL = 120    # seconds an approval waits for Face ID
CREATE_LIMIT = 6      # approvals Jarvis may ask for per minute (a looping or injected agent can't spam)

TITLES = {
    "start": "Start the car", "lock": "Lock the car", "unlock": "Unlock the car",
    "trunk_lock": "Lock the trunk", "trunk_unlock": "Unlock the trunk", "lights": "Turn on the headlights",
    "horn": "Sound the horn", "buzzer": "Sound the buzzer", "hazards_on": "Turn on the hazards",
    "hazards_off": "Turn off the hazards",
}
# What the button key may sign, per domain. Arming needs no proof at all; everything else stays Face ID.
BUTTON_COMMANDS = {"jarvis-home": frozenset({"disarm", "silence"}), "jarvis-car": frozenset(TITLES)}


class ApprovalError(Exception):
    """A signature, key or approval the server won't accept. ``code`` is for the phone."""

    def __init__(self, message: str, code: str) -> None:
        super().__init__(message)
        self.code = code


def message(command: str, nonce: str, ts: int, domain: str = "jarvis-car") -> bytes:
    """What a command approval is signed over. ``domain`` keeps the car's and the door alarm's
    ("jarvis-home") signatures apart: one can never be replayed as the other."""
    return f"{domain}|{command}|{nonce}|{ts}".encode()


def register_message(public_key: str, ts: int) -> bytes:
    """What a key registration is signed over — its own prefix, never a command's."""
    return f"jarvis-car-register|{public_key}|{ts}".encode()


def button_message(command: str, nonce: str, ts: int, domain: str = "jarvis-car") -> bytes:
    """What a button press that skips Face ID is signed over — its own prefix, so a button
    signature never passes as a Face ID one, or the other way round."""
    return f"jarvis-button|{domain}|{command}|{nonce}|{ts}".encode()


def button_register_message(button_key: str, ts: int) -> bytes:
    """What the Face ID key signs to vouch for a button key."""
    return f"jarvis-button-register|{button_key}|{ts}".encode()


def _key_file() -> Path:
    # The root home, not the active profile's: the webui swaps HERMES_HOME for profile-scoped runs.
    from jarviscopilot_constants import get_default_hermes_root

    return get_default_hermes_root() / "car" / "approver.json"


def _stamp(ts: Any) -> int:
    try:
        value = int(ts)
    except (TypeError, ValueError, OverflowError) as exc:
        raise ApprovalError("The approval is malformed.", "bad_request") from exc
    if not 0 < value < 10 ** 11:      # a unix time in seconds, nothing absurd
        raise ApprovalError("The approval is malformed.", "bad_request")
    return value


def _signature(raw: Any) -> bytes:
    try:
        return base64.b64decode(str(raw or ""), validate=True)
    except (TypeError, ValueError) as exc:
        raise ApprovalError("The approval is malformed.", "bad_request") from exc


def _load_key(raw_b64: str):
    from cryptography.hazmat.primitives.asymmetric import ec

    try:
        raw = base64.b64decode(raw_b64, validate=True)
        return ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), raw)
    except (ValueError, TypeError) as exc:
        raise ApprovalError("That isn't a P-256 public key.", "bad_key") from exc


class Approver:
    """The registered keys (Face ID, and the optional button key) and the nonces already signed.

    The keys are read once and then kept in memory: a later change to the file (by anything but
    ``register``/``register_button``/``clear_button``) is ignored until the webui restarts. A file
    that exists but can't be read locks everything rather than reopening registration; a button key
    in it that doesn't parse is just dropped (presses fall back to Face ID).
    """

    def __init__(self, path: Path | None = None, clock: Callable[[], float] = time.time) -> None:
        self.path = path or _key_file()
        self.clock = clock
        # A signature made before this process started may have been used already (nonces are kept in
        # memory only): refuse those.
        self.started = clock()
        self._used: dict[str, float] = {}
        self._lock = threading.Lock()
        self._loaded = False
        self._key: str | None = None
        self._button: str | None = None
        self._registered_at: Any = None
        self._locked = False

    def _load(self) -> None:
        if self._loaded:
            return
        self._loaded = True
        try:
            data = json.loads(self.path.read_text())
            key = data.get("public_key") if isinstance(data, dict) else None
            if not isinstance(key, str) or not key:
                raise ValueError("no public_key")
            _load_key(key)
            self._key = key
            self._registered_at = data.get("registered_at")
        except FileNotFoundError:
            self._key = None
            return
        except (OSError, ValueError, ApprovalError):
            self._locked = True
            return
        button = data.get("button_key")
        if isinstance(button, str) and button and button != self._key:
            try:
                _load_key(button)
                self._button = button
            except ApprovalError:
                pass

    def _save(self, key: str, button: str | None, registered_at: Any) -> None:
        """Atomically replace the key file. Call with the lock held."""
        payload: dict[str, Any] = {"public_key": key}
        if registered_at is not None:
            payload["registered_at"] = registered_at
        if button:
            payload["button_key"] = button
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".approver-", dir=str(self.path.parent))
        try:
            with os.fdopen(fd, "w") as handle:
                handle.write(json.dumps(payload))
            os.chmod(tmp, 0o600)
            os.replace(tmp, self.path)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)

    def registered(self) -> str | None:
        with self._lock:
            self._load()
            return self._key

    def button_key(self) -> str | None:
        with self._lock:
            self._load()
            return self._button

    def _require_unlocked(self) -> None:
        if self._locked:
            raise ApprovalError("The car's approval key file is unreadable; it needs a reset on the server.", "locked")

    def register(self, public_key: Any, ts: Any = None, signature: Any = None, from_host: bool = False) -> None:
        """A key proves itself: the first one signs its own registration; a replacement is signed by
        the key it replaces. Never from the host loopback (that is the agent's side)."""
        if from_host:
            raise ApprovalError("Register the car key from the iPhone.", "forbidden")
        public_key = str(public_key or "").strip()
        new_key = _load_key(public_key)
        with self._lock:
            self._load()
            self._require_unlocked()
            current = self._key
        if current == public_key:
            return
        signer = _load_key(current) if current else new_key
        stamp = _stamp(ts)
        self._check_time(stamp)
        self._check_signature(signer, _signature(signature), register_message(public_key, stamp),
                              "the old key" if current else "the new key")
        at = int(self.clock())
        with self._lock:
            # A new Face ID key drops the button key: the phone vouches for one again.
            self._save(public_key, None, at)
            self._key, self._button, self._registered_at = public_key, None, at

    def register_button(self, public_key: Any, ts: Any = None, signature: Any = None,
                        from_host: bool = False) -> None:
        """The button key is vouched for by the Face ID key (a signature over
        button_register_message), never by itself. Never from the host loopback."""
        if from_host:
            raise ApprovalError("Register the button key from the iPhone.", "forbidden")
        public_key = str(public_key or "").strip()
        _load_key(public_key)
        with self._lock:
            self._load()
            self._require_unlocked()
            current = self._key
        if not current:
            raise ApprovalError("No iPhone is set up to approve with Face ID yet.", "approver_unknown")
        if public_key == current:
            raise ApprovalError("The button key must be a different key from the Face ID one.", "bad_key")
        stamp = _stamp(ts)
        self._check_time(stamp)
        self._check_signature(_load_key(current), _signature(signature), button_register_message(public_key, stamp),
                              "the Face ID key")
        marker = f"button-register|{public_key}|{stamp}"   # never a nonce: those can't hold "|"
        now = self.clock()
        with self._lock:
            if self._key != current:
                raise ApprovalError("The Face ID key changed meanwhile. Try again.", "stale")
            if self._button == public_key:
                return
            self._forget_used(now)
            # A cleared button key can't be brought back by replaying its registration.
            if marker in self._used:
                raise ApprovalError("That registration was already used.", "replayed")
            self._save(current, public_key, self._registered_at)
            self._button = public_key
            self._used[marker] = now

    def clear_button(self, from_host: bool = False) -> None:
        """Forget the button key: presses that skip Face ID fall back to it. Never from the host loopback."""
        if from_host:
            raise ApprovalError("Remove the button key from the iPhone.", "forbidden")
        with self._lock:
            self._load()
            self._require_unlocked()
            if not self._button or not self._key:
                return
            self._save(self._key, None, self._registered_at)
            self._button = None

    def _forget_used(self, now: float) -> None:
        for old, at in list(self._used.items()):
            if now - at > NONCE_MEMORY:
                del self._used[old]

    def _check_time(self, stamp: int, what: str = "Face ID approval") -> None:
        now = self.clock()
        if abs(now - stamp) > MAX_AGE:
            raise ApprovalError(f"That {what} is too old. Try again.", "stale")
        if stamp < self.started - 1:
            raise ApprovalError(f"That {what} is from before the server restarted. Try again.", "stale")

    @staticmethod
    def _check_signature(key: Any, sig: bytes, signed: bytes, whose: str) -> None:
        from cryptography.exceptions import InvalidSignature
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.asymmetric import ec

        try:
            key.verify(sig, signed, ec.ECDSA(hashes.SHA256()))
        except InvalidSignature as exc:
            raise ApprovalError(f"The signature isn't from {whose}.", "bad_signature") from exc

    def verify(self, command: str, nonce: Any, ts: Any, signature: Any, domain: str = "jarvis-car",
               by_button: bool = False) -> None:
        """Raise ApprovalError unless this is a fresh, unused signature by the registered key — or,
        ``by_button``, by the button key over button_message, for BUTTON_COMMANDS only."""
        with self._lock:
            self._load()
            self._require_unlocked()
            current = self._button if by_button else self._key
        if by_button:
            if command not in BUTTON_COMMANDS.get(domain, ()):
                raise ApprovalError("A button can't do that without Face ID.", "forbidden")
            if not current:
                raise ApprovalError("This server has no button key. Approve it with Face ID.", "button_key_unknown")
        elif not current:
            raise ApprovalError("No iPhone is set up to approve car commands yet.", "approver_unknown")
        nonce = str(nonce or "")
        if not nonce or len(nonce) > 128 or "|" in nonce:
            raise ApprovalError("The approval is missing its one-time code.", "bad_request")
        stamp = _stamp(ts)
        sig = _signature(signature)
        self._check_time(stamp, "button press" if by_button else "Face ID approval")
        signed = (button_message if by_button else message)(command, nonce, stamp, domain)
        try:
            self._check_signature(_load_key(current), sig, signed, "this iPhone")
        except ApprovalError as exc:
            what = "The button press" if by_button else "Face ID approval"
            raise ApprovalError(f"{what} didn't check out on this server.", exc.code) from exc
        now = self.clock()
        with self._lock:
            self._forget_used(now)
            if nonce in self._used:
                raise ApprovalError("That approval was already used.", "replayed")
            self._used[nonce] = now


class Approvals:
    """Commands Jarvis asked for, waiting for Face ID on the phone."""

    def __init__(self, clock: Callable[[], float] = time.time, titles: dict | None = None,
                 label: str = "car") -> None:
        self.clock = clock
        self.titles = TITLES if titles is None else titles
        self.label = label
        self._items: dict[str, dict] = {}
        self._asked: list[float] = []
        self._lock = threading.Lock()

    def _sweep(self) -> None:
        now = self.clock()
        for key, item in list(self._items.items()):
            if now - item["created"] > APPROVAL_TTL:
                del self._items[key]

    def create(self, command: str, source: str = "Jarvis") -> dict:
        item = {"id": secrets.token_hex(12), "command": command, "title": self.titles.get(command, command),
                "source": source, "created": self.clock()}
        with self._lock:
            self._sweep()
            now = self.clock()
            self._asked = [at for at in self._asked if now - at < 60]
            if len(self._asked) >= CREATE_LIMIT:
                raise ApprovalError(f"Too many {self.label} approvals asked for. Wait a minute.", "rate_limited")
            self._asked.append(now)
            # One waiting approval per command: asking twice replaces the older one.
            for key, other in list(self._items.items()):
                if other["command"] == command:
                    del self._items[key]
            self._items[item["id"]] = item
        return self.public(item)

    def pending(self) -> list[dict]:
        with self._lock:
            self._sweep()
            return [self.public(i) for i in sorted(self._items.values(), key=lambda i: i["created"])]

    def take(self, approval_id: str) -> dict:
        """Remove and return a waiting approval (approve or deny ends it either way)."""
        with self._lock:
            self._sweep()
            item = self._items.pop(str(approval_id), None)
        if item is None:
            raise ApprovalError("That approval has expired or was already answered.", "gone")
        return item

    def peek(self, approval_id: str) -> dict:
        with self._lock:
            self._sweep()
            item = self._items.get(str(approval_id))
        if item is None:
            raise ApprovalError("That approval has expired or was already answered.", "gone")
        return item

    def public(self, item: dict) -> dict:
        return {"id": item["id"], "command": item["command"], "title": item["title"], "source": item["source"],
                "age_s": int(self.clock() - item["created"]),
                "expires_in_s": max(0, int(APPROVAL_TTL - (self.clock() - item["created"])))}


_approver: Approver | None = None
_approvals = Approvals()


def approver() -> Approver:
    global _approver
    if _approver is None:
        _approver = Approver()
    return _approver


def approvals() -> Approvals:
    return _approvals
