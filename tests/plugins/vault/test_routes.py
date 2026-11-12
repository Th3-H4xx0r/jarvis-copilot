"""/api/vault/* — unlock and session gating, passcode lockout, the write-only inbox, uploads,
folders, and Jarvis's tools (nothing runs without a Face ID approval, then exactly once)."""
import base64
import io
import json
import os
import uuid

import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

from plugins.toyota.approver import Approver, message, register_message
from plugins.vault import tools as vault_tools
from plugins.vault.crypto import SEGMENT
from plugins.vault.service import VaultService
from plugins.vault.store import CHUNK_SIZE
from webui.api.vault_routes import Raw, handle_vault_request, parse_range

DOMAIN = "jarvis-vault"


class Phone:
    def __init__(self):
        self.key = ec.generate_private_key(ec.SECP256R1())

    @property
    def public(self):
        raw = self.key.public_key().public_bytes(serialization.Encoding.X962,
                                                 serialization.PublicFormat.UncompressedPoint)
        return base64.b64encode(raw).decode()

    def sign(self, data: bytes) -> str:
        return base64.b64encode(self.key.sign(data, ec.ECDSA(hashes.SHA256()))).decode()

    def proof(self, command, ts, nonce=None):
        nonce = nonce or uuid.uuid4().hex
        return {"nonce": nonce, "ts": ts, "signature": self.sign(message(command, nonce, ts, DOMAIN))}


@pytest.fixture
def clock():
    return [1_800_000_000.0]


@pytest.fixture
def phone():
    return Phone()


@pytest.fixture
def svc(tmp_path, clock, phone):
    keys = Approver(tmp_path / "approver.json", clock=lambda: clock[0])
    ts = int(clock[0])
    keys.register(phone.public, ts, phone.sign(register_message(phone.public, ts)))
    return VaultService(root=tmp_path, approver=keys, clock=lambda: clock[0], notify=lambda item: None,
                        fetch_preview=lambda url: None, preview_wait_s=2.0)


class Body:
    """A PUT body as the route reads it."""

    def __init__(self, data: bytes):
        self.data = data

    def __call__(self, limit):
        if len(self.data) > limit:
            raise ValueError("That upload part is the wrong size.")
        return self.data


def call(svc, method, path, body=None, token=None, raw=None, host=False, headers=None):
    hdrs = dict(headers or {})
    if token:
        hdrs["X-Vault-Token"] = token
    return handle_vault_request(method, path, body, headers=hdrs, read_raw=Body(raw or b""),
                                host_signed=host, service=svc)


def unlock(svc, phone, clock):
    status, payload = call(svc, "POST", "/unlock", phone.proof("unlock", int(clock[0])))
    assert status == 200, payload
    return payload["token"]


def raw_bytes(out):
    assert isinstance(out, Raw)
    return out.body if isinstance(out.body, bytes) else b"".join(out.body)


# ── unlock + sessions ─────────────────────────────────────────────────────

def test_status_needs_no_token_and_says_nothing_readable(svc):
    status, payload = call(svc, "GET", "/status")
    assert status == 200 and payload == {"ok": True, "passcode_set": False, "approver_registered": True}


@pytest.mark.parametrize("method,path", [("GET", "/tree"), ("GET", "/folders/root"), ("GET", "/recent"),
                                         ("GET", "/search?q=x"), ("POST", "/items"), ("POST", "/uploads"),
                                         ("GET", "/items/" + "a" * 24 + "/content")])
def test_every_vault_route_needs_a_token(svc, method, path):
    status, payload = call(svc, method, path, {})
    assert status == 401 and payload["code"] == "locked" and payload["ok"] is False
    status, payload = call(svc, method, path, {}, token="made-up")
    assert status == 401 and payload["code"] == "locked"


def test_unlock_gives_a_token_that_expires_idle_and_at_max(svc, phone, clock):
    token = unlock(svc, phone, clock)
    assert call(svc, "GET", "/tree", token=token)[0] == 200
    clock[0] += 299
    assert call(svc, "GET", "/tree", token=token)[0] == 200      # use restarts the idle clock
    clock[0] += 301
    assert call(svc, "GET", "/tree", token=token)[0] == 401      # 5 min idle
    token = unlock(svc, phone, clock)
    for _ in range(8):                                           # used every 4 min, still capped at 30
        clock[0] += 240
        call(svc, "GET", "/tree", token=token)
    assert call(svc, "GET", "/tree", token=token)[0] == 401


def test_lock_revokes_the_token(svc, phone, clock):
    token = unlock(svc, phone, clock)
    assert call(svc, "POST", "/lock", {}, token=token) == (200, {"ok": True})
    assert call(svc, "GET", "/tree", token=token)[0] == 401


def test_unlock_refuses_replays_bad_signatures_and_other_domains(svc, phone, clock):
    proof = phone.proof("unlock", int(clock[0]))
    assert call(svc, "POST", "/unlock", proof)[0] == 200
    status, payload = call(svc, "POST", "/unlock", proof)
    assert status == 403 and payload["code"] == "replayed"
    nonce = uuid.uuid4().hex
    car_sig = phone.sign(message("unlock", nonce, int(clock[0]), "jarvis-car"))   # the car's unlock
    status, payload = call(svc, "POST", "/unlock", {"nonce": nonce, "ts": int(clock[0]), "signature": car_sig})
    assert status == 403 and payload["code"] == "bad_signature"
    status, _ = call(svc, "POST", "/unlock", Phone().proof("unlock", int(clock[0])))
    assert status == 403


def test_jarvis_cannot_unlock_or_use_a_token(svc, phone, clock):
    token = unlock(svc, phone, clock)
    assert call(svc, "GET", "/tree", token=token, host=True)[0] == 403
    assert call(svc, "POST", "/unlock", phone.proof("unlock", int(clock[0])), host=True)[0] == 403
    assert call(svc, "POST", "/inbox", {"kind": "note", "body": "x"}, host=True)[0] == 403


# ── passcode ──────────────────────────────────────────────────────────────

def test_passcode_needs_face_id_to_set_then_unlocks(svc, phone, clock):
    assert call(svc, "POST", "/passcode", {"passcode": "123456"})[0] == 400       # no proof
    status, _ = call(svc, "POST", "/passcode", {"passcode": "123456", **phone.proof("passcode", int(clock[0]))})
    assert status == 200 and call(svc, "GET", "/status")[1]["passcode_set"] is True
    status, payload = call(svc, "POST", "/unlock/passcode", {"passcode": "123456"})
    assert status == 200 and payload["token"] and payload["idle_s"] == 300 and payload["max_s"] == 1800
    assert call(svc, "POST", "/unlock/passcode", {"passcode": "654321"})[0] == 401
    # A Face ID proof for unlock can't set the passcode.
    status, _ = call(svc, "POST", "/passcode", {"passcode": "111111", **phone.proof("unlock", int(clock[0]))})
    assert status == 403


def test_passcode_locks_out_after_five_wrong_tries_doubling(svc, phone, clock):
    call(svc, "POST", "/passcode", {"passcode": "123456", **phone.proof("passcode", int(clock[0]))})
    for _ in range(5):
        assert call(svc, "POST", "/unlock/passcode", {"passcode": "000000"})[0] == 401
    status, payload = call(svc, "POST", "/unlock/passcode", {"passcode": "123456"})   # even the right one
    assert status == 429 and payload["retry_after_s"] == 30
    assert call(svc, "GET", "/status")[1]["retry_after_s"] == 30
    clock[0] += 31
    assert call(svc, "POST", "/unlock/passcode", {"passcode": "000000"})[0] == 401
    assert call(svc, "POST", "/unlock/passcode", {"passcode": "123456"})[1]["retry_after_s"] == 60
    clock[0] += 61
    assert call(svc, "POST", "/unlock/passcode", {"passcode": "123456"})[0] == 200
    assert "retry_after_s" not in call(svc, "GET", "/status")[1]


# ── items + folders ───────────────────────────────────────────────────────

def test_folders_notes_links_listing_and_search(svc, phone, clock):
    t = unlock(svc, phone, clock)
    travel = call(svc, "POST", "/folders", {"parent_id": "root", "name": "Travel"}, token=t)[1]["folder"]
    japan = call(svc, "POST", "/folders", {"parent_id": travel["id"], "name": "Japan 2026"}, token=t)[1]["folder"]
    note = call(svc, "POST", "/items", {"kind": "note", "parent_id": japan["id"], "title": "Hotels",
                                        "body": "Park Hyatt Tokyo, 3 nights"}, token=t)[1]["item"]
    status, payload = call(svc, "POST", "/items", {"kind": "link", "parent_id": travel["id"],
                                                   "url": "https://www.youtube.com/watch?v=abcdefghijk",
                                                   "note": "watch before"}, token=t)
    assert status == 200 and payload["item"]["preview_status"] == "failed"
    assert payload["item"]["link"]["domain"] == "youtube.com" and payload["item"]["note"] == "watch before"
    tree = {f["name"]: f for f in call(svc, "GET", "/tree", token=t)[1]["folders"]}
    assert tree["Travel"]["count"] == 2 and tree["Japan 2026"]["count"] == 1
    view = call(svc, "GET", f"/folders/{japan['id']}", token=t)[1]
    assert [p["name"] for p in view["folder"]["path"]] == ["Vault", "Travel", "Japan 2026"]
    assert view["items"][0]["snippet"].startswith("Park Hyatt")
    found = call(svc, "GET", "/search?q=hyatt", token=t)[1]
    assert [i["id"] for i in found["items"]] == [note["id"]] and found["items"][0]["path"] == "Travel › Japan 2026"
    assert call(svc, "GET", f"/items/{note['id']}", token=t)[1]["item"]["body"] == "Park Hyatt Tokyo, 3 nights"
    assert len(call(svc, "GET", "/recent?limit=30", token=t)[1]["items"]) == 2


def test_nothing_readable_is_stored_in_plaintext(svc, phone, clock, tmp_path):
    t = unlock(svc, phone, clock)
    call(svc, "POST", "/folders", {"parent_id": "root", "name": "ZebraFolderName"}, token=t)
    call(svc, "POST", "/items", {"kind": "note", "parent_id": "root", "title": "ZebraTitle",
                                 "body": "ZebraBody"}, token=t)
    for path in (tmp_path / "vault").rglob("*"):
        if path.is_file():
            assert b"Zebra" not in path.read_bytes(), path


def test_move_into_own_descendant_is_refused(svc, phone, clock):
    t = unlock(svc, phone, clock)
    a = call(svc, "POST", "/folders", {"parent_id": "root", "name": "A"}, token=t)[1]["folder"]
    b = call(svc, "POST", "/folders", {"parent_id": a["id"], "name": "B"}, token=t)[1]["folder"]
    assert call(svc, "PATCH", f"/folders/{a['id']}", {"parent_id": b["id"]}, token=t)[0] == 400
    assert call(svc, "PATCH", f"/folders/{a['id']}", {"parent_id": a["id"]}, token=t)[0] == 400
    assert call(svc, "POST", "/items/move", {"ids": [a["id"]], "parent_id": b["id"]}, token=t)[0] == 400
    status, payload = call(svc, "PATCH", f"/folders/{b['id']}", {"parent_id": "root", "name": "B2"}, token=t)
    assert status == 200 and payload["folder"]["parent_id"] == "root" and payload["folder"]["name"] == "B2"


def _upload(svc, t, data, kind="video", mime="video/mp4", parent="root", inbox=False, thumb=None, skip=()):
    base = "/inbox/uploads" if inbox else "/uploads"
    status, up = call(svc, "POST", base, {"parent_id": parent, "kind": kind, "filename": "clip.mp4", "mime": mime,
                                          "size": len(data), "duration_s": 12.5}, token=t)
    assert status == 200, up
    assert up["chunk_size"] == CHUNK_SIZE and up["received"] == []
    n = (len(data) + CHUNK_SIZE - 1) // CHUNK_SIZE
    for i in range(n):
        if i in skip:
            continue
        status, payload = call(svc, "PUT", f"{base}/{up['upload_id']}/{i}", token=t,
                               raw=data[i * CHUNK_SIZE:(i + 1) * CHUNK_SIZE])
        assert status == 200, payload
    if thumb:
        assert call(svc, "PUT", f"{base}/{up['upload_id']}/thumb", token=t, raw=thumb)[0] == 200
    return base, up["upload_id"]


def test_upload_resume_then_finish_then_range_stream(svc, phone, clock, tmp_path):
    t = unlock(svc, phone, clock)
    data = os.urandom(CHUNK_SIZE + 3 * SEGMENT // 2)
    base, upload_id = _upload(svc, t, data, skip=(0,))
    status, payload = call(svc, "POST", f"{base}/{upload_id}/finish", {}, token=t)
    assert status == 400 and "missing" in payload["error"]
    assert call(svc, "GET", f"{base}/{upload_id}", token=t)[1]["received"] == [1]
    assert call(svc, "PUT", f"{base}/{upload_id}/0", token=t, raw=data[:100])[0] == 400       # wrong size
    assert call(svc, "PUT", f"{base}/{upload_id}/0", token=t, raw=data[:CHUNK_SIZE])[1]["received"] == 2
    assert call(svc, "PUT", f"{base}/{upload_id}/0", token=t, raw=data[:CHUNK_SIZE])[1]["received"] == 2  # idempotent
    item = call(svc, "POST", f"{base}/{upload_id}/finish", {}, token=t)[1]["item"]
    assert item["size"] == len(data) and item["mime"] == "video/mp4" and item["duration_s"] == 12.5
    full = call(svc, "GET", f"/items/{item['id']}/content", token=t)
    assert full.status == 200 and full.length == len(data) and raw_bytes(full) == data
    lo, hi = SEGMENT - 5, CHUNK_SIZE + 10
    part = call(svc, "GET", f"/items/{item['id']}/content", token=t, headers={"Range": f"bytes={lo}-{hi}"})
    assert part.status == 206 and part.headers["Content-Range"] == f"bytes {lo}-{hi}/{len(data)}"
    assert raw_bytes(part) == data[lo:hi + 1] and part.length == hi - lo + 1
    bad = call(svc, "GET", f"/items/{item['id']}/content", token=t, headers={"Range": f"bytes={len(data)}-"})
    assert bad.status == 416
    assert b"".join(p.read_bytes() for p in (tmp_path / "vault").rglob("*") if p.is_file()).find(data[:4096]) == -1


def test_parse_range_forms():
    assert parse_range("bytes=0-1", 10) == (0, 1)
    assert parse_range("bytes=5-", 10) == (5, 9)
    assert parse_range("bytes=-3", 10) == (7, 9)
    assert parse_range("bytes=0-99", 10) == (0, 9)
    assert parse_range("bytes=10-", 10) == "unsatisfiable"
    assert parse_range(None, 10) is None


def test_folder_delete_is_recursive_and_removes_blobs(svc, phone, clock, tmp_path):
    t = unlock(svc, phone, clock)
    a = call(svc, "POST", "/folders", {"parent_id": "root", "name": "A"}, token=t)[1]["folder"]
    b = call(svc, "POST", "/folders", {"parent_id": a["id"], "name": "B"}, token=t)[1]["folder"]
    base, upload_id = _upload(svc, t, os.urandom(5000), parent=b["id"], thumb=_jpeg())
    item = call(svc, "POST", f"{base}/{upload_id}/finish", {}, token=t)[1]["item"]
    assert item["has_thumb"] and item["thumb_w"] == 40
    assert item["parent_id"] == b["id"]
    blobs = list((tmp_path / "vault" / "blobs").glob(f"{item['id']}.*"))
    assert len(blobs) == 2
    assert call(svc, "DELETE", f"/folders/{a['id']}", {}, token=t) == (200, {"ok": True})
    assert not any(p.exists() for p in blobs)
    assert call(svc, "GET", "/tree", token=t)[1]["folders"] == []
    assert call(svc, "GET", f"/items/{item['id']}", token=t)[0] == 404


def _jpeg(size=(40, 30)):
    from PIL import Image

    out = io.BytesIO()
    Image.new("RGB", size, (200, 10, 10)).save(out, "JPEG")
    return out.getvalue()


# ── inbox ─────────────────────────────────────────────────────────────────

def test_inbox_is_write_only(svc, phone, clock):
    status, payload = call(svc, "POST", "/inbox", {"kind": "note", "title": "Secret", "body": "the body",
                                                   "parent_id": "nope"})
    assert status == 200 and set(payload) == {"ok", "id"}
    status, payload = call(svc, "POST", "/inbox", {"kind": "link", "url": "https://example.com/x"})
    assert status == 200 and set(payload) == {"ok", "id"}
    base, upload_id = _upload(svc, None, _jpeg((1200, 900)), kind="image", mime="image/jpeg", inbox=True)
    status, payload = call(svc, "POST", f"{base}/{upload_id}/finish", {})
    assert status == 200 and set(payload) == {"ok", "id"}
    # Nothing to read through the inbox, and no other route works without a token.
    for path in ("/inbox", f"/inbox/{payload['id']}", "/inbox/uploads"):
        status, out = call(svc, "GET", path)
        assert status == 404 and "Secret" not in json.dumps(out)
    assert call(svc, "GET", f"/items/{payload['id']}")[0] == 401
    # It all landed in the root, and the server made the image's thumbnail.
    t = unlock(svc, phone, clock)
    items = {i["kind"]: i for i in call(svc, "GET", "/folders/root", token=t)[1]["items"]}
    assert items["note"]["title"] == "Secret"
    assert items["image"]["has_thumb"] and items["image"]["thumb_w"] <= 640 and items["image"]["width"] == 1200
    assert raw_bytes(call(svc, "GET", f"/items/{items['image']['id']}/thumb", token=t))[:2] == b"\xff\xd8"


def test_the_inbox_ignores_folder_ids_and_saves_to_the_top(svc, phone, clock):
    """The share sheet can't see folders, so it can't place (or probe for) one either."""
    t = unlock(svc, phone, clock)
    folder = call(svc, "POST", "/folders", {"name": "Private", "parent_id": "root"}, token=t)[1]["folder"]
    call(svc, "POST", "/inbox", {"kind": "note", "title": "n", "body": "b", "parent_id": folder["id"]})
    call(svc, "POST", "/inbox", {"kind": "link", "url": "https://example.com/y", "parent_id": folder["id"]})
    base, upload_id = _upload(svc, None, b"x" * 10, kind="file", mime="application/octet-stream",
                              parent=folder["id"], inbox=True)
    assert call(svc, "POST", f"{base}/{upload_id}/finish", {})[0] == 200
    assert call(svc, "GET", f"/folders/{folder['id']}", token=t)[1]["items"] == []
    kinds = sorted(i["kind"] for i in call(svc, "GET", "/folders/root", token=t)[1]["items"])
    assert kinds == ["file", "link", "note"]


def test_an_inbox_upload_cant_be_driven_through_the_token_routes_or_back(svc, phone, clock):
    t = unlock(svc, phone, clock)
    _, inbox_id = _upload(svc, None, b"x" * 10, inbox=True, skip=(0,))
    assert call(svc, "GET", f"/uploads/{inbox_id}", token=t)[0] == 404
    _, own_id = _upload(svc, t, b"x" * 10, skip=(0,))
    assert call(svc, "GET", f"/inbox/uploads/{own_id}")[0] == 404


# ── Jarvis's approvals and tools ─────────────────────────────────────────

def _host_api(svc):
    def api(method, path, body=None, timeout=15.0):
        assert path.startswith("/api/vault")
        status, payload = handle_vault_request(method, path[len("/api/vault"):], body, host_signed=True, service=svc)
        return payload
    return api


def test_approval_routes_are_split_between_jarvis_and_the_phone(svc, phone, clock):
    assert call(svc, "POST", "/approvals", {"command": "search", "args": {"query": "x"}})[0] == 403
    status, payload = call(svc, "POST", "/approvals", {"command": "search", "args": {"query": "tax"}}, host=True)
    assert status == 200
    approval = payload["approval"]
    assert "tax" not in json.dumps(payload)
    listed = call(svc, "GET", "/approvals")[1]["approvals"]
    assert [a["id"] for a in listed] == [approval["id"]] and "tax" not in json.dumps(listed)
    assert call(svc, "GET", f"/approvals/{approval['id']}/result")[0] == 403       # the phone can't collect
    assert call(svc, "POST", f"/approvals/{approval['id']}/approve", {}, host=True)[0] == 403


def test_tool_refuses_without_approval_and_runs_once_after(svc, phone, clock):
    t = unlock(svc, phone, clock)
    call(svc, "POST", "/items", {"kind": "note", "parent_id": "root", "title": "Doomed", "body": "x"}, token=t)
    target = call(svc, "GET", "/recent", token=t)[1]["items"][0]["id"]
    api = _host_api(svc)

    # No approval: the tool gives up and nothing is deleted.
    ticks = [0.0]
    out = vault_tools.ask_and_wait("delete", {"ids": [target]}, api=api, sleep=lambda s: ticks.__setitem__(0, ticks[0] + s),
                                   clock=lambda: ticks[0], wait_s=5)
    assert out.get("expired") and call(svc, "GET", f"/items/{target}", token=t)[0] == 200

    # Denied: nothing deleted.
    def deny_first(_):
        for a in call(svc, "GET", "/approvals")[1]["approvals"]:
            call(svc, "POST", f"/approvals/{a['id']}/deny", {})
    out = vault_tools.ask_and_wait("delete", {"ids": [target]}, api=api, sleep=deny_first, wait_s=5)
    assert out.get("denied") and call(svc, "GET", f"/items/{target}", token=t)[0] == 200

    # Approved with Face ID: runs once; a second approve of the same id is refused.
    answers = []

    def approve_first(_):
        for a in call(svc, "GET", "/approvals")[1]["approvals"]:
            body = {"ts": int(clock[0]), "signature": phone.sign(message(a["command"], a["id"], int(clock[0]), DOMAIN))}
            answers.append(call(svc, "POST", f"/approvals/{a['id']}/approve", body))
            answers.append(call(svc, "POST", f"/approvals/{a['id']}/approve", body))
    out = vault_tools.ask_and_wait("delete", {"ids": [target]}, api=api, sleep=approve_first, wait_s=5)
    assert out == {"ok": True, "result": {"deleted": 1}}
    assert answers[0] == (200, {"ok": True, "result_summary": "Deleted 1"})
    assert answers[1][0] in (403, 410)
    assert call(svc, "GET", f"/items/{target}", token=t)[0] == 404


def test_an_approval_signed_for_another_command_is_refused(svc, phone, clock):
    status, payload = call(svc, "POST", "/approvals", {"command": "delete", "args": {"ids": ["a" * 24]}}, host=True)
    approval = payload["approval"]
    body = {"ts": int(clock[0]), "signature": phone.sign(message("search", approval["id"], int(clock[0]), DOMAIN))}
    assert call(svc, "POST", f"/approvals/{approval['id']}/approve", body)[0] == 403
    assert svc.collect(approval["id"])["status"] == "pending"


def test_tool_actions_resolve_folders_by_path_and_save_files(svc, phone, clock, tmp_path):
    t = unlock(svc, phone, clock)
    travel = call(svc, "POST", "/folders", {"parent_id": "root", "name": "Travel"}, token=t)[1]["folder"]
    call(svc, "POST", "/folders", {"parent_id": travel["id"], "name": "Japan 2026"}, token=t)
    japan = svc.resolve_folder("travel/japan 2026")
    assert svc.resolve_folder("Japan 2026") == japan
    with pytest.raises(ValueError):
        svc.resolve_folder("Nowhere")
    attachment = tmp_path / "scan.pdf"
    attachment.write_bytes(b"%PDF-1.4 fake")
    result, _ = svc.run("save", {"kind": "file", "folder": "Taxes/2026", "title": "", "path": str(attachment)})
    assert result["saved"]["kind"] == "pdf" and result["saved"]["filename"] == "scan.pdf"
    result, _ = svc.run("list", {"folder": "taxes/2026"})
    assert result["folder"] == "Vault › Taxes › 2026" and len(result["items"]) == 1
    result, _ = svc.run("save", {"kind": "note", "folder": "", "title": "Wifi", "body": "pw hunter2"})
    read, _ = svc.run("read", {"id": result["saved"]["id"]})
    assert read["body"] == "pw hunter2"
    with pytest.raises(ValueError):
        svc.import_file("root", str(tmp_path / "secrets" / "vault_master.key"))


def test_vault_toolset_matches_the_plugin_tools():
    from toolsets import TOOLSETS

    assert TOOLSETS["vault"]["tools"] == [name for name, *_ in vault_tools.TOOLS]


def test_links_from_an_older_preview_engine_are_fetched_again(svc, phone, clock):
    """A link the old engine saved with a bot wall's title and no picture gets the new engine."""
    t = unlock(svc, phone, clock)
    store = svc.store
    item = store.create_link("root", "https://tube.example/videos/clip-xh1")
    store.mark_preview_attempt(item["id"])
    store.save_preview(item["id"], {"title": "Please update your browser", "kind": "page"})
    with store._lock, store._db() as conn:          # what the old engine left: no engine stamp
        row = store._row(conn, item["id"])
        dk, meta = store._open(row)
        meta.pop("preview_engine", None)
        store._update_meta(conn, row, dk, meta, touch=False)
    assert [i for i, _ in store.links_pending()] == [item["id"]]
    svc._fetch = lambda url: {"preview": {"title": "The real clip", "kind": "video"}, "image": None, "favicon": None}
    status, payload = call(svc, "POST", f"/items/{item['id']}/preview", {}, token=t)
    assert status == 200 and payload["item"]["title"] == "The real clip"
