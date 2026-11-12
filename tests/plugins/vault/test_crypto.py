"""Vault encryption: blobs round-trip, any tampering fails, Range reads decrypt only what they touch."""
import os

import pytest

from plugins.vault import crypto
from plugins.vault.crypto import SEGMENT, TAG, VaultCryptoError

ITEM = "a" * 24


@pytest.fixture
def key():
    return crypto.new_data_key()


def _blob(tmp_path, key, plain, item=ITEM, kind="content"):
    path = tmp_path / f"{item}.{kind}"
    crypto.write_blob(key, item, kind, path, plain)
    return path


def test_master_key_is_created_once_private(tmp_path):
    path = tmp_path / "secrets" / "vault_master.key"
    first = crypto.load_master_key(path)
    assert len(first) == 32 and crypto.load_master_key(path) == first
    assert oct(path.stat().st_mode & 0o777) == "0o600"


def test_round_trip_and_no_plaintext_on_disk(tmp_path, key):
    plain = os.urandom(2 * SEGMENT + 12345)
    path = _blob(tmp_path, key, plain)
    assert crypto.read_blob(key, ITEM, "content", path, len(plain)) == plain
    marker = b"PLAINTEXT-MARKER-" * 1000
    path2 = _blob(tmp_path, key, marker, kind="thumb")
    assert b"PLAINTEXT-MARKER" not in path2.read_bytes()


def test_key_wrap_and_meta_are_bound_to_the_item(tmp_path, key):
    master = crypto.new_data_key()
    wrapped = crypto.wrap_key(master, ITEM, key)
    assert crypto.unwrap_key(master, ITEM, wrapped) == key
    with pytest.raises(VaultCryptoError):
        crypto.unwrap_key(master, "b" * 24, wrapped)
    sealed = crypto.seal_meta(key, ITEM, {"title": "x"})
    assert crypto.open_meta(key, ITEM, sealed) == {"title": "x"}
    with pytest.raises(VaultCryptoError):
        crypto.open_meta(key, "b" * 24, sealed)


def test_a_flipped_byte_fails(tmp_path, key):
    plain = os.urandom(SEGMENT + 10)
    path = _blob(tmp_path, key, plain)
    raw = bytearray(path.read_bytes())
    raw[crypto.PREFIX + 100] ^= 0x01
    path.write_bytes(bytes(raw))
    with pytest.raises(VaultCryptoError):
        crypto.read_blob(key, ITEM, "content", path, len(plain))


def test_swapped_segments_fail(tmp_path, key):
    plain = os.urandom(2 * SEGMENT)
    path = _blob(tmp_path, key, plain)
    raw = path.read_bytes()
    seg = SEGMENT + TAG
    head, a, b = raw[:crypto.PREFIX], raw[crypto.PREFIX:crypto.PREFIX + seg], raw[crypto.PREFIX + seg:]
    path.write_bytes(head + b + a)
    with pytest.raises(VaultCryptoError):
        crypto.read_blob(key, ITEM, "content", path, len(plain))


def test_wrong_item_or_kind_fails(tmp_path, key):
    plain = b"hello vault"
    path = _blob(tmp_path, key, plain)
    with pytest.raises(VaultCryptoError):
        crypto.read_blob(key, "b" * 24, "content", path, len(plain))
    with pytest.raises(VaultCryptoError):
        crypto.read_blob(key, ITEM, "thumb", path, len(plain))


def test_truncation_fails(tmp_path, key):
    plain = os.urandom(SEGMENT + 500)
    path = _blob(tmp_path, key, plain)
    path.write_bytes(path.read_bytes()[:-10])
    with pytest.raises(VaultCryptoError):
        crypto.read_blob(key, ITEM, "content", path, len(plain))


@pytest.mark.parametrize("start,end", [
    (0, 0), (SEGMENT - 1, SEGMENT - 1), (SEGMENT - 1, SEGMENT), (SEGMENT, SEGMENT),
    (10, 2 * SEGMENT + 5), (2 * SEGMENT, 2 * SEGMENT + 999), (SEGMENT - 3, 3 * SEGMENT + 10_000),
])
def test_range_reads_at_and_across_segment_boundaries(tmp_path, key, start, end):
    plain = os.urandom(2 * SEGMENT + 1000)
    path = _blob(tmp_path, key, plain)
    got = b"".join(crypto.read_range(key, ITEM, "content", path, len(plain), start, end))
    assert got == plain[start:min(end, len(plain) - 1) + 1]


def test_a_range_only_decrypts_the_segments_it_touches(tmp_path, key):
    plain = os.urandom(3 * SEGMENT)
    path = _blob(tmp_path, key, plain)
    raw = bytearray(path.read_bytes())
    raw[crypto.segment_offset(2) + 5] ^= 0xFF          # damage the last segment only
    path.write_bytes(bytes(raw))
    assert b"".join(crypto.read_range(key, ITEM, "content", path, len(plain), 0, SEGMENT + 9)) == plain[:SEGMENT + 10]
    with pytest.raises(VaultCryptoError):
        b"".join(crypto.read_range(key, ITEM, "content", path, len(plain), 2 * SEGMENT, 2 * SEGMENT + 1))
