"""Security-review regressions: protected paths for agent tools, content-free approval details,
image bombs, header injection, failure cleanup, idempotent uploads, sessions and the passcode pepper."""
import hashlib
import json
import os
import struct
import zlib
from pathlib import Path

import pytest

from plugins.toyota.approver import message
from plugins.vault import store as store_mod
from plugins.vault.store import make_thumbnail, safe_mime

from .test_routes import DOMAIN, _jpeg, call, raw_bytes, unlock  # noqa: F401  (fixtures below)
from .test_routes import clock, phone, svc  # noqa: F401


# ── 1. agent tools can't reach the keys or the vault ─────────────────────

@pytest.mark.parametrize("rel", ["secrets/vault_master.key", "vault/vault.db", "vault/blobs/x.content",
                                 "car/approver.json"])
def test_file_tools_refuse_protected_state(rel):
    from agent.file_safety import get_read_block_error, is_write_denied
    from jarviscopilot_constants import get_default_hermes_root

    target = get_default_hermes_root() / rel
    assert get_read_block_error(str(target)) is not None
    assert is_write_denied(str(target)) is True


def test_file_tools_still_allow_neighbours():
    from agent.file_safety import get_read_block_error, is_write_denied
    from jarviscopilot_constants import get_default_hermes_root

    target = get_default_hermes_root() / "vaults-notes.txt"
    assert get_read_block_error(str(target)) is None and is_write_denied(str(target)) is False


@pytest.mark.parametrize("command,flagged", [
    ("cat ~/.jarviscopilot/secrets/vault_master.key", True),
    ("sqlite3 /root/.jarviscopilot/vault/vault.db .dump", True),
    ("cp $HERMES_HOME/car/approver.json /tmp/x", True),
    ("cd ~/.jarviscopilot && tar czf /tmp/v.tgz vault", True),
    ("python3 -c \"open('/root/.jarviscopilot/secrets/vault_master.key').read()\"", True),
    ("ls ~/.jarviscopilot/vaults", False),
    ("echo vault", False),
])
def test_terminal_flags_protected_state(command, flagged):
    from tools.approval import detect_dangerous_command

    assert detect_dangerous_command(command)[0] is flagged


# ── 2. approvals say what, never which ──────────────────────────────────

def test_approval_details_are_content_free(svc, phone, clock):
    t = unlock(svc, phone, clock)
    a = call(svc, "POST", "/folders", {"parent_id": "root", "name": "SecretFolderName"}, token=t)[1]["folder"]
    b = call(svc, "POST", "/folders", {"parent_id": a["id"], "name": "Inner"}, token=t)[1]["folder"]
    ids = []
    for parent in (a["id"], b["id"], "root"):
        ids.append(call(svc, "POST", "/items", {"kind": "note", "parent_id": parent, "title": "SecretTitle",
                                                "body": "x"}, token=t)[1]["item"]["id"])
    cases = {
        ("delete", json.dumps({"ids": [a["id"], ids[2]]})): "2 items, including 1 folder with 2 items inside",
        ("move", json.dumps({"ids": [ids[2]], "folder": "Inner"})): "1 item into another folder",
        ("search", json.dumps({"query": "SecretQuery"})): "a search",
        ("list", json.dumps({"folder": "SecretFolderName"})): "one folder's list",
        ("read", json.dumps({"id": ids[0]})): "one item",
        ("save", json.dumps({"kind": "link", "url": "https://secret.example/x"})): "a new link",
    }
    for (command, args), want in cases.items():
        status, payload = call(svc, "POST", "/approvals", {"command": command, "args": json.loads(args)}, host=True)
        assert status == 200 and payload["approval"]["detail"] == want
    listed = json.dumps(call(svc, "GET", "/approvals")[1])
    for secret in ("Secret", "secret.example"):
        assert secret not in listed


# ── 3. image bombs ──────────────────────────────────────────────────────

def _png_header_only(width, height):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(b"\x00" * 16)) + chunk(b"IEND", b"")


def test_huge_images_are_refused_before_decoding():
    assert make_thumbnail(_png_header_only(20000, 20000)) is None
    made = make_thumbnail(_jpeg((1600, 1200)))
    assert made and made[1][0] <= 640 and made[2] == (1600, 1200)


def test_a_preview_attempt_is_counted_before_the_fetch(svc, phone, clock):
    seen = []

    def fetch(url):
        item_id = svc.store.links_pending(max_tries=99)[0][0]
        seen.append(svc.store.item_meta(item_id)[1]["preview_tries"])
        raise RuntimeError("worker crash")

    svc._fetch = fetch
    t = unlock(svc, phone, clock)
    item = call(svc, "POST", "/items", {"kind": "link", "parent_id": "root", "url": "https://a.example/"},
                token=t)[1]["item"]
    assert seen == [1] and item["preview_status"] == "failed"


# ── 4. header injection through a MIME type ─────────────────────────────

@pytest.mark.parametrize("raw,want", [("video/mp4", "video/mp4"), ("Image/JPEG", "image/jpeg"),
                                      ("text/html\r\nSet-Cookie: a=b", "application/octet-stream"),
                                      ("text/html; charset=utf-8", "application/octet-stream"),
                                      ("", "application/octet-stream")])
def test_safe_mime(raw, want):
    assert safe_mime(raw) == want


def test_an_injected_mime_never_reaches_the_header(svc, phone, clock):
    t = unlock(svc, phone, clock)
    status, up = call(svc, "POST", "/uploads", {"parent_id": "root", "kind": "file", "filename": "a",
                                                "mime": "text/plain\r\nSet-Cookie: x=1", "size": 3}, token=t)
    call(svc, "PUT", f"/uploads/{up['upload_id']}/0", token=t, raw=b"abc")
    item = call(svc, "POST", f"/uploads/{up['upload_id']}/finish", {}, token=t)[1]["item"]
    out = call(svc, "GET", f"/items/{item['id']}/content", token=t)
    assert out.content_type == "application/octet-stream" and item["mime"] == "application/octet-stream"


# ── 6. DNS rebinding in vault previews ──────────────────────────────────

def test_vault_preview_refuses_a_private_peer(monkeypatch):
    import httpx

    from plugins.vault import preview

    real = httpx.Client
    monkeypatch.setattr(httpx, "Client", lambda **kw: real(transport=httpx.MockTransport(
        lambda req: httpx.Response(200, headers={"content-type": "text/html"}, text="<title>in</title>")), **kw))
    monkeypatch.setattr("tools.url_safety.is_safe_url", lambda url: True)
    monkeypatch.setattr("tools.url_safety.response_peer_is_public", lambda resp: False)
    assert preview.fetch("https://rebind.example/") is None
    monkeypatch.setattr("tools.url_safety.response_peer_is_public", lambda resp: True)
    assert preview.fetch("https://rebind.example/")["preview"]["title"] == "in"


# ── 7. failures after an approval, and partial imports ──────────────────

def test_an_unexpected_failure_after_approval_is_stored_generically(svc, phone, clock, monkeypatch):
    def boom(command, args):
        raise RuntimeError("SecretDetail /root/path")

    monkeypatch.setattr(svc, "run", boom)
    approval = call(svc, "POST", "/approvals", {"command": "search", "args": {"query": "q"}}, host=True)[1]["approval"]
    body = {"ts": int(clock[0]), "signature": phone.sign(message("search", approval["id"], int(clock[0]), DOMAIN))}
    status, payload = call(svc, "POST", f"/approvals/{approval['id']}/approve", body)
    assert status == 200 and payload["ok"] is True and payload["result_summary"]
    got = svc.collect(approval["id"])
    assert got["status"] == "error" and "Secret" not in json.dumps(got)


def test_a_failed_import_leaves_nothing_behind(svc, tmp_path, monkeypatch):
    src = tmp_path / "doc.bin"
    src.write_bytes(b"x" * 100)

    def fail(upload_id, inbox=False):
        raise RuntimeError("disk full")

    monkeypatch.setattr(svc.store, "finish_upload", fail)
    with pytest.raises(RuntimeError):
        svc.import_file("root", str(src))
    with svc.store._db() as conn:
        assert conn.execute("SELECT COUNT(*) FROM uploads").fetchone()[0] == 0
    assert list((tmp_path / "vault" / "blobs").iterdir()) == []


# ── 9 / 10. empty files and repeated finishes ───────────────────────────

def test_a_zero_byte_file_is_one_empty_chunk(svc, phone, clock):
    t = unlock(svc, phone, clock)
    up = call(svc, "POST", "/uploads", {"parent_id": "root", "kind": "file", "filename": "empty", "size": 0},
              token=t)[1]
    assert call(svc, "POST", f"/uploads/{up['upload_id']}/finish", {}, token=t)[0] == 400   # chunk 0 not sent
    assert call(svc, "PUT", f"/uploads/{up['upload_id']}/0", token=t, raw=b"")[0] == 200
    item = call(svc, "POST", f"/uploads/{up['upload_id']}/finish", {}, token=t)[1]["item"]
    out = call(svc, "GET", f"/items/{item['id']}/content", token=t)
    assert item["size"] == 0 and out.status == 200 and raw_bytes(out) == b""


def test_finish_is_idempotent(svc, phone, clock):
    t = unlock(svc, phone, clock)
    up = call(svc, "POST", "/uploads", {"parent_id": "root", "kind": "file", "filename": "f", "size": 2}, token=t)[1]
    call(svc, "PUT", f"/uploads/{up['upload_id']}/0", token=t, raw=b"hi")
    first = call(svc, "POST", f"/uploads/{up['upload_id']}/finish", {}, token=t)[1]["item"]
    again = call(svc, "POST", f"/uploads/{up['upload_id']}/finish", {}, token=t)[1]["item"]
    assert first["id"] == again["id"] and len(call(svc, "GET", "/recent", token=t)[1]["items"]) == 1
    status = call(svc, "GET", f"/uploads/{up['upload_id']}", token=t)[1]
    assert status["finished"] is True and status["item_id"] == first["id"]
    inbox = call(svc, "POST", "/inbox/uploads", {"kind": "file", "filename": "g", "size": 1})[1]
    call(svc, "PUT", f"/inbox/uploads/{inbox['upload_id']}/0", raw=b"x")
    a = call(svc, "POST", f"/inbox/uploads/{inbox['upload_id']}/finish", {})[1]
    b = call(svc, "POST", f"/inbox/uploads/{inbox['upload_id']}/finish", {})[1]
    assert a == b and set(a) == {"ok", "id"}


def test_open_inbox_uploads_are_capped(svc):
    for _ in range(store_mod.MAX_OPEN_INBOX_UPLOADS):
        assert call(svc, "POST", "/inbox/uploads", {"kind": "file", "filename": "f", "size": 1})[0] == 200
    status, payload = call(svc, "POST", "/inbox/uploads", {"kind": "file", "filename": "f", "size": 1})
    assert status == 429 and payload["code"] == "busy"


# ── 11. lock and passcode changes end every session ─────────────────────

def test_lock_and_passcode_change_revoke_every_token(svc, phone, clock):
    a, b = unlock(svc, phone, clock), unlock(svc, phone, clock)
    call(svc, "POST", "/lock", {}, token=a)
    assert call(svc, "GET", "/tree", token=b)[0] == 401
    c = unlock(svc, phone, clock)
    call(svc, "POST", "/passcode", {"passcode": "123456", **phone.proof("passcode", int(clock[0]))})
    assert call(svc, "GET", "/tree", token=c)[0] == 401


# ── 15. the passcode hash is peppered; an old hash still works and migrates ──

def test_passcode_is_peppered_and_legacy_hashes_migrate(svc, phone, clock):
    call(svc, "POST", "/passcode", {"passcode": "123456", **phone.proof("passcode", int(clock[0]))})
    data = json.loads(svc.passcode.path.read_text())
    plain = hashlib.scrypt(b"123456", salt=bytes.fromhex(data["salt"]), n=data["n"], r=data["r"], p=data["p"],
                           maxmem=256 * 1024 * 1024, dklen=32)
    assert data["v"] == 2 and bytes.fromhex(data["hash"]) != plain
    # A hash written before the pepper existed.
    svc.passcode.path.write_text(json.dumps({**data, "v": 1, "hash": plain.hex()}))
    assert call(svc, "POST", "/unlock/passcode", {"passcode": "123456"})[0] == 200
    migrated = json.loads(svc.passcode.path.read_text())
    assert migrated["v"] == 2 and bytes.fromhex(migrated["hash"]) != plain
    assert call(svc, "POST", "/unlock/passcode", {"passcode": "123456"})[0] == 200


# ── iOS review: raw_title and root paths ─────────────────────────────────

def test_raw_title_and_root_search_path(svc, phone, clock):
    t = unlock(svc, phone, clock)
    item = call(svc, "POST", "/items", {"kind": "note", "parent_id": "root", "title": "", "body": "first line\nmore"},
                token=t)[1]["item"]
    assert item["title"] == "first line" and item["raw_title"] == ""
    found = call(svc, "GET", "/search?q=first", token=t)[1]["items"]
    assert found[0]["path"] is None
