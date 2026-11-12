"""Secure Vault encryption: the master key, per-item data keys, and segmented blobs.

- The master key (32 random bytes) lives at ``<root>/secrets/vault_master.key`` (0600), outside the
  data folder ``<root>/vault/``: a copy of the data folder alone decrypts nothing.
- Each item has its own 256-bit data key, AES-GCM-wrapped by the master key (AAD binds it to the item id).
- Metadata is one JSON blob per item, AES-GCM under the item's key (AAD ``<item_id>|meta``).
- A blob (content, thumb, favicon) is a 4-byte random prefix followed by 1 MiB plaintext segments,
  each AES-256-GCM with nonce = prefix + 8-byte big-endian segment index and AAD
  ``<item_id>|<blob_kind>|<index>``. The segment key is derived per blob from the data key, the blob
  kind and the prefix (HKDF), so two blobs of one item never share a (key, nonce) pair. Segments can't
  be reordered, swapped between blobs or items, or edited without the read failing. The plaintext
  size of each blob is kept in the (authenticated) metadata, so a truncated blob fails too.
"""
from __future__ import annotations

import json
import os
import secrets
import threading
from pathlib import Path

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

SEGMENT = 1024 * 1024          # plaintext bytes per segment
TAG = 16                       # GCM tag per segment
PREFIX = 4                     # random nonce prefix at the head of every blob file


class VaultCryptoError(Exception):
    """A key, metadata row or blob segment that doesn't decrypt (tampered, swapped or truncated)."""


def secrets_dir() -> Path:
    # The root home, not the active profile's: the webui swaps HERMES_HOME for profile-scoped runs
    # (same reason plugins/toyota/approver.py and the door alarm use it).
    from jarviscopilot_constants import get_default_hermes_root

    return get_default_hermes_root() / "secrets"


_master_lock = threading.Lock()


def load_master_key(path: Path | None = None) -> bytes:
    """The master key, created (0600, exclusive create) on first use."""
    path = path or (secrets_dir() / "vault_master.key")
    with _master_lock:
        try:
            raw = path.read_bytes()
        except FileNotFoundError:
            path.parent.mkdir(parents=True, exist_ok=True)
            try:
                os.chmod(path.parent, 0o700)
            except OSError:
                pass
            key = secrets.token_bytes(32)
            try:
                fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            except FileExistsError:
                raw = path.read_bytes()
            else:
                with os.fdopen(fd, "wb") as handle:
                    handle.write(key)
                    handle.flush()
                    os.fsync(handle.fileno())
                return key
        if len(raw) != 32:
            raise VaultCryptoError("The vault master key file is damaged.")
        return raw


def new_data_key() -> bytes:
    return secrets.token_bytes(32)


def wrap_key(master: bytes, item_id: str, data_key: bytes) -> bytes:
    nonce = secrets.token_bytes(12)
    return nonce + AESGCM(master).encrypt(nonce, data_key, f"wrap|{item_id}".encode())


def unwrap_key(master: bytes, item_id: str, wrapped: bytes) -> bytes:
    try:
        return AESGCM(master).decrypt(bytes(wrapped[:12]), bytes(wrapped[12:]), f"wrap|{item_id}".encode())
    except (InvalidTag, ValueError) as exc:
        raise VaultCryptoError("An item key doesn't decrypt.") from exc


def seal_meta(data_key: bytes, item_id: str, meta: dict) -> bytes:
    nonce = secrets.token_bytes(12)
    raw = json.dumps(meta, separators=(",", ":"), ensure_ascii=False).encode()
    return nonce + AESGCM(data_key).encrypt(nonce, raw, f"{item_id}|meta".encode())


def open_meta(data_key: bytes, item_id: str, sealed: bytes) -> dict:
    try:
        raw = AESGCM(data_key).decrypt(bytes(sealed[:12]), bytes(sealed[12:]), f"{item_id}|meta".encode())
    except (InvalidTag, ValueError) as exc:
        raise VaultCryptoError("An item's details don't decrypt.") from exc
    return json.loads(raw)


def _blob_key(data_key: bytes, item_id: str, kind: str, prefix: bytes) -> AESGCM:
    derived = HKDF(algorithm=hashes.SHA256(), length=32, salt=prefix,
                   info=f"jarvis-vault-blob|{item_id}|{kind}".encode()).derive(data_key)
    return AESGCM(derived)


def segment_count(size: int) -> int:
    return (size + SEGMENT - 1) // SEGMENT


def segment_offset(index: int) -> int:
    """Where encrypted segment ``index`` starts in a blob file (all but the last are full)."""
    return PREFIX + index * (SEGMENT + TAG)


class BlobWriter:
    """Encrypts segments of one blob into its file at their fixed offsets, in any order."""

    def __init__(self, data_key: bytes, item_id: str, kind: str, path: Path, prefix: bytes | None = None):
        self.item_id, self.kind, self.path = item_id, kind, path
        path.parent.mkdir(parents=True, exist_ok=True)
        if prefix is None:
            if path.exists() and path.stat().st_size >= PREFIX:
                prefix = _read_prefix(path)       # resuming an upload: keep its prefix
            else:
                prefix = secrets.token_bytes(PREFIX)
                fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                with os.fdopen(fd, "wb") as handle:
                    handle.write(prefix)
        self.prefix = prefix
        self._aead = _blob_key(data_key, item_id, kind, prefix)

    def write_segment(self, index: int, plain: bytes) -> None:
        if len(plain) > SEGMENT:
            raise ValueError("segment too large")
        nonce = self.prefix + index.to_bytes(8, "big")
        sealed = self._aead.encrypt(nonce, plain, f"{self.item_id}|{self.kind}|{index}".encode())
        with open(self.path, "r+b") as handle:
            handle.seek(segment_offset(index))
            handle.write(sealed)
            handle.flush()
            os.fsync(handle.fileno())

    def write_span(self, first_index: int, plain: bytes) -> int:
        """Encrypt ``plain`` as consecutive segments from ``first_index``; returns segments written."""
        n = 0
        for start in range(0, len(plain), SEGMENT):
            self.write_segment(first_index + n, plain[start:start + SEGMENT])
            n += 1
        return n


def _read_prefix(path: Path) -> bytes:
    with open(path, "rb") as handle:
        return handle.read(PREFIX)


def write_blob(data_key: bytes, item_id: str, kind: str, path: Path, plain: bytes) -> None:
    """Encrypt a whole (small) blob into a fresh file: a new prefix every time."""
    tmp = path.with_name(path.name + ".tmp")
    if tmp.exists():
        tmp.unlink()
    writer = BlobWriter(data_key, item_id, kind, tmp, prefix=None)
    writer.write_span(0, plain)
    os.replace(tmp, path)


def read_range(data_key: bytes, item_id: str, kind: str, path: Path, size: int, start: int = 0,
               end: int | None = None):
    """Yield the plaintext bytes ``[start, end]`` (inclusive) of a blob of ``size`` plaintext bytes,
    decrypting only the segments the range touches."""
    if size <= 0:
        return
    end = size - 1 if end is None else min(end, size - 1)
    if start > end:
        return
    try:
        handle = open(path, "rb")
    except FileNotFoundError as exc:
        raise VaultCryptoError("A vault blob is missing.") from exc
    with handle:
        prefix = handle.read(PREFIX)
        if len(prefix) != PREFIX:
            raise VaultCryptoError("A vault blob is truncated.")
        aead = _blob_key(data_key, item_id, kind, prefix)
        last = segment_count(size) - 1
        for index in range(start // SEGMENT, end // SEGMENT + 1):
            plain_len = SEGMENT if index < last else size - last * SEGMENT
            handle.seek(segment_offset(index))
            sealed = handle.read(plain_len + TAG)
            if len(sealed) != plain_len + TAG:
                raise VaultCryptoError("A vault blob is truncated.")
            try:
                plain = aead.decrypt(prefix + index.to_bytes(8, "big"), sealed,
                                     f"{item_id}|{kind}|{index}".encode())
            except InvalidTag as exc:
                raise VaultCryptoError("A vault blob segment doesn't decrypt.") from exc
            seg_start = index * SEGMENT
            lo = max(start, seg_start) - seg_start
            hi = min(end, seg_start + plain_len - 1) - seg_start + 1
            yield plain[lo:hi]


def read_blob(data_key: bytes, item_id: str, kind: str, path: Path, size: int) -> bytes:
    return b"".join(read_range(data_key, item_id, kind, path, size))
