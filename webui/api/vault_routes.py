"""HTTP API for the iPhone's Secure Vault: ``/api/vault/*`` (plugins/vault/ holds the logic).

Who may do what:
- Every route needs normal webui auth (the server enforces it for /api).
- ``/status``, ``/unlock``, ``/unlock/passcode``, ``/passcode`` and ``/inbox*`` need no vault token.
  ``/inbox*`` (the share extension) is write-only: its replies carry ids and chunk numbers, never a
  title, content or listing.
- ``/approvals`` (list) and ``/approvals/<id>/approve|deny`` are the phone answering Jarvis; the
  Face ID signature over ``jarvis-vault|<command>|<approval id>|<ts>`` is the proof, no token.
- ``POST /approvals {command, args}`` and ``GET /approvals/<id>/result`` are Jarvis's tools over the
  host-signed loopback only.
- Everything else needs the ``X-Vault-Token`` header from an unlock; the host loopback (the agent's
  side) is refused there, on unlock and on the inbox — Jarvis reaches the vault only through a
  Face ID approval.

Security events carry the path and HTTP status only — never a query, title, content or URL.
"""
from __future__ import annotations

import logging
import re

log = logging.getLogger(__name__)

VAULT_PATH_PREFIX = "/api/vault"
_NO_TOKEN = ("/status", "/unlock", "/unlock/passcode", "/passcode")
_INBOX_FIELDS = ("parent_id", "kind", "filename", "mime", "size", "title", "duration_s", "width", "height", "pages")


class Raw:
    """A non-JSON reply: bytes (or an iterator of bytes) with its headers."""

    def __init__(self, status: int, body, length: int, content_type: str, headers: dict | None = None):
        self.status, self.body, self.length = status, body, length
        self.content_type, self.headers = content_type, headers or {}


def _err(status: int, error: str, code: str | None = None, **extra):
    out = {"ok": False, "error": error, **extra}
    if code:
        out["code"] = code
    return status, out


def parse_range(header: str | None, size: int):
    """(start, end) inclusive for a ``Range: bytes=…`` header, None for no/ignored range, or
    "unsatisfiable"."""
    if not header:
        return None
    m = re.fullmatch(r"\s*bytes\s*=\s*(\d*)\s*-\s*(\d*)\s*(?:,.*)?", header)
    if not m:
        return None
    a, b = m.groups()
    if a == "" and b == "":
        return None
    if a == "":
        n = int(b)
        if n == 0 or size == 0:
            return "unsatisfiable"
        return max(0, size - n), size - 1
    start = int(a)
    end = int(b) if b else size - 1
    if start >= size or end < start:
        return "unsatisfiable"
    return start, min(end, size - 1)


def handle_vault_request(method: str, path: str, body=None, *, headers=None, read_raw=None,
                         host_signed: bool = False, service=None):
    """``(status, payload)`` for JSON, or a Raw. ``read_raw(limit)`` returns a PUT's body bytes
    (ValueError when it's over ``limit``); ``headers`` is the request's headers mapping."""
    from plugins.toyota.approver import ApprovalError
    from plugins.vault.crypto import VaultCryptoError
    from plugins.vault.service import COMMANDS, VaultService
    from plugins.vault.session import PasscodeLocked
    from plugins.vault.store import MAX_THUMB, Busy, NotFound

    svc = service or VaultService.instance()
    headers = headers or {}
    body = body if isinstance(body, dict) else {}
    raw_path, _, query = (path or "").partition("?")
    p = raw_path.rstrip("/") or "/"
    parts = p.strip("/").split("/")
    from urllib.parse import parse_qs
    params = {k: v[-1] for k, v in parse_qs(query).items()}

    def forbid(msg="Jarvis reaches the vault only through a Face ID approval."):
        return _err(403, msg, "forbidden")

    try:
        # ── Jarvis's approvals ────────────────────────────────────────────
        if parts[0] == "approvals":
            if method == "GET" and p == "/approvals":
                return 200, {"approvals": svc.approvals.pending()}
            if method == "POST" and p == "/approvals":
                if not host_signed:
                    return forbid("Only Jarvis asks for vault approvals.")
                command = str(body.get("command") or "")
                if command not in COMMANDS:
                    return _err(400, "Unknown vault action.")
                return 200, {"ok": True, "approval": svc.request(command, body.get("args") or {})}
            if method == "GET" and len(parts) == 3 and parts[2] == "result":
                if not host_signed:
                    return forbid("Only Jarvis collects its vault results.")
                return 200, svc.collect(parts[1])
            if method == "POST" and len(parts) == 3 and parts[2] in ("approve", "deny"):
                if host_signed:
                    return forbid("Approvals are answered on the iPhone.")
                if parts[2] == "deny":
                    return 200, svc.deny(parts[1])
                if body.get("by") == "button":
                    return forbid("Jarvis's vault approvals are answered with Face ID.")
                return 200, svc.approve(parts[1], body)
            return _err(404, "unknown vault endpoint")

        if host_signed:
            return forbid()

        # ── no token ──────────────────────────────────────────────────────
        if p == "/status" and method == "GET":
            return 200, svc.status()
        if method == "POST" and p == "/unlock":
            return 200, svc.unlock_face_id(body)
        if method == "POST" and p == "/unlock/passcode":
            if not svc.passcode.is_set():
                return _err(409, "No vault passcode is set.", "no_passcode")
            if svc.passcode.check(body.get("passcode")):
                return 200, svc.sessions.issue()
            return _err(401, "Wrong passcode.", "wrong_passcode")
        if method == "POST" and p == "/passcode":
            return 200, svc.set_passcode(body)
        if parts[0] == "inbox":
            return _inbox(svc, method, p, parts, body, read_raw, MAX_THUMB)

        # ── everything else: the vault token ──────────────────────────────
        token = headers.get("X-Vault-Token") or headers.get("x-vault-token")
        if p == "/lock" and method == "POST":
            svc.sessions.revoke_all()       # one person's vault: locking ends every session
            return 200, {"ok": True}
        if not svc.sessions.check(token):
            return _err(401, "The vault is locked.", "locked")
        return _locked_routes(svc, method, p, parts, body, params, headers, read_raw, MAX_THUMB)
    except PasscodeLocked as exc:
        return _err(429, str(exc), "lockout", retry_after_s=exc.retry_after_s)
    except ApprovalError as exc:
        status = {"gone": 410, "bad_request": 400, "bad_key": 400, "rate_limited": 429}.get(exc.code, 403)
        return _err(status, str(exc), exc.code)
    except NotFound:
        return _err(404, "Not found.", "not_found")
    except Busy as exc:
        return _err(429, str(exc), "busy", retry_after_s=5)
    except VaultCryptoError:
        log.error("vault: an item failed to decrypt (path %s)", p)
        return _err(500, "That item couldn't be decrypted.", "decrypt_failed")
    except ValueError as exc:
        return _err(400, str(exc))


def _inbox(svc, method, p, parts, body, read_raw, max_thumb):
    """The share extension: save only. Replies never carry anything readable."""
    store = svc.store
    if method == "POST" and p == "/inbox":
        kind = str(body.get("kind") or "")
        if kind == "link":
            item = svc.create_link(body.get("parent_id"), body.get("url"), note=body.get("body"),
                                   title=body.get("title"), fallback_root=True, wait=False)
        elif kind == "note":
            item = store.create_note(body.get("parent_id"), body.get("title"), body.get("body"), fallback_root=True)
        else:
            return _err(400, "The inbox takes a link or a note.")
        return 200, {"ok": True, "id": item["id"]}
    if len(parts) >= 2 and parts[1] == "uploads":
        if method == "POST" and len(parts) == 2:
            fields = {k: body.get(k) for k in _INBOX_FIELDS}
            return 200, store.start_upload(fields, inbox=True)
        if len(parts) >= 3:
            upload_id = parts[2]
            if method == "GET" and len(parts) == 3:
                return 200, store.upload_status(upload_id, inbox=True)
            if method == "PUT" and len(parts) == 4 and parts[3] == "thumb":
                store.put_upload_thumb(upload_id, read_raw(max_thumb), inbox=True)
                return 200, {"ok": True}
            if method == "PUT" and len(parts) == 4 and parts[3].isdigit():
                index = int(parts[3])
                want = store.expected_chunk_len(upload_id, index, inbox=True)
                return 200, {"ok": True, "received": store.put_chunk(upload_id, index, read_raw(want), inbox=True)}
            if method == "POST" and len(parts) == 4 and parts[3] == "finish":
                return 200, {"ok": True, "id": store.finish_upload(upload_id, inbox=True)["id"]}
    return _err(404, "unknown vault endpoint")


def _locked_routes(svc, method, p, parts, body, params, headers, read_raw, max_thumb):
    from plugins.vault.store import FILE_KINDS, NotFound, safe_mime

    store = svc.store
    if method == "GET":
        if p == "/tree":
            return 200, {"ok": True, "folders": store.tree()}
        if parts[0] == "folders" and len(parts) == 2:
            view = store.folder_view(parts[1])
            svc.retry_previews()
            return 200, {"ok": True, **view}
        if p == "/recent":
            try:
                limit = int(params.get("limit") or 30)
            except ValueError:
                limit = 30
            items = store.recent(limit)
            svc.retry_previews()
            return 200, {"ok": True, "items": items}
        if p == "/search":
            return 200, {"ok": True, **store.search(params.get("q") or "")}
        if parts[0] == "items" and len(parts) == 2:
            return 200, {"ok": True, "item": store.get_item(parts[1], body=True)}
        if parts[0] == "items" and len(parts) == 3 and parts[2] in ("thumb", "favicon"):
            dk_size = store.blob(parts[1], parts[2])
            meta = dk_size[3]
            raw = b"".join(store.read_blob(parts[1], parts[2]))
            ctype = "image/jpeg" if parts[2] == "thumb" else safe_mime(meta.get("favicon_mime"), "image/x-icon")
            return Raw(200, raw, len(raw), ctype)
        if parts[0] == "items" and len(parts) == 3 and parts[2] == "content":
            _, size, _, meta = store.blob(parts[1], "content")
            ctype = safe_mime(meta.get("mime"))
            rng = parse_range(headers.get("Range") or headers.get("range"), size)
            if rng == "unsatisfiable":
                return Raw(416, b"", 0, ctype, {"Content-Range": f"bytes */{size}", "Accept-Ranges": "bytes"})
            if rng is None:
                return Raw(200, store.read_blob(parts[1], "content"), size, ctype, {"Accept-Ranges": "bytes"})
            start, end = rng
            return Raw(206, store.read_blob(parts[1], "content", start, end), end - start + 1, ctype,
                       {"Accept-Ranges": "bytes", "Content-Range": f"bytes {start}-{end}/{size}"})
        if parts[0] == "uploads" and len(parts) == 2:
            return 200, store.upload_status(parts[1])
        return _err(404, "unknown vault endpoint")

    if method == "POST":
        if p == "/folders":
            return 200, {"ok": True, "folder": store.create_folder(body.get("parent_id"), body.get("name"))}
        if p == "/items":
            kind = str(body.get("kind") or "")
            if kind == "note":
                return 200, {"ok": True, "item": store.create_note(body.get("parent_id"), body.get("title"),
                                                                    body.get("body"))}
            if kind == "link":
                return 200, {"ok": True, "item": svc.create_link(body.get("parent_id"), body.get("url"),
                                                                 note=body.get("note"), title=body.get("title"))}
            return _err(400, "Notes and links are created here; files go through /uploads.")
        if p == "/link-preview":
            return 200, svc.live_preview(body.get("url"))
        if p == "/items/move":
            return 200, {"ok": True, "moved": store.move(body.get("ids") or [], body.get("parent_id"))}
        if p == "/items/delete":
            return 200, {"ok": True, "deleted": store.delete(body.get("ids") or [])}
        if p == "/uploads":
            fields = {k: body.get(k) for k in _INBOX_FIELDS}
            if fields.get("kind") not in FILE_KINDS:
                fields["kind"] = "file"
            return 200, store.start_upload(fields)
        if parts[0] == "uploads" and len(parts) == 3 and parts[2] == "finish":
            return 200, {"ok": True, "item": store.finish_upload(parts[1])}
        return _err(404, "unknown vault endpoint")

    if method == "PUT" and parts[0] == "uploads" and len(parts) == 3:
        if parts[2] == "thumb":
            store.put_upload_thumb(parts[1], read_raw(max_thumb))
            return 200, {"ok": True}
        if parts[2].isdigit():
            index = int(parts[2])
            want = store.expected_chunk_len(parts[1], index)
            return 200, {"ok": True, "received": store.put_chunk(parts[1], index, read_raw(want))}
        return _err(404, "unknown vault endpoint")

    if method == "PATCH":
        if parts[0] == "folders" and len(parts) == 2:
            return 200, {"ok": True, "folder": store.update_folder(parts[1], name=body.get("name"),
                                                                    parent_id=body.get("parent_id"))}
        if parts[0] == "items" and len(parts) == 2:
            return 200, {"ok": True, "item": store.update_item(parts[1], title=body.get("title"), body=body.get("body"),
                                                                note=body.get("note"), parent_id=body.get("parent_id"))}
        return _err(404, "unknown vault endpoint")

    if method == "DELETE" and parts[0] == "folders" and len(parts) == 2:
        if parts[1] == "root":
            return _err(400, "The vault's root can't be deleted.")
        store.delete_folder(parts[1])
        return 200, {"ok": True}
    if method == "DELETE":
        raise NotFound("no such route")
    return _err(405, f"method {method} not allowed")


# ── HTTP glue ─────────────────────────────────────────────────────────────

def _reader(handler):
    """read_raw(exact_or_limit) for a PUT body: refuses bodies over the limit before reading them."""

    def read_raw(limit: int) -> bytes:
        try:
            length = int(handler.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if length < 0 or length > limit:
            handler.close_connection = True        # the body stays unread
            raise ValueError("That upload part is the wrong size.")
        data = handler.rfile.read(length) if length else b""
        if len(data) != length:
            raise ValueError("The upload part was cut off.")
        return data

    return read_raw


def _send_raw(handler, raw: Raw) -> None:
    from api.helpers import _security_headers
    from plugins.vault.crypto import VaultCryptoError

    body = raw.body
    first = b""
    if not isinstance(body, (bytes, bytearray)):
        # Decrypt the first segment before any header goes out, so a bad blob is a clean error.
        body = iter(body)
        first = next(body, b"")
    handler.send_response(raw.status)
    handler.send_header("Content-Type", raw.content_type)
    handler.send_header("Content-Length", str(raw.length))
    handler.send_header("Cache-Control", "no-store, private")
    for k, v in raw.headers.items():
        handler.send_header(k, v)
    _security_headers(handler)
    handler.end_headers()
    if isinstance(body, (bytes, bytearray)):
        handler.wfile.write(body)
        return
    try:
        if first:
            handler.wfile.write(first)
        for chunk in body:
            handler.wfile.write(chunk)
    except VaultCryptoError:
        log.error("vault: a blob failed to decrypt mid-stream")
        handler.close_connection = True


def _emit(req, status: int) -> None:
    """Security advisor: path and status only."""
    try:
        from security.events import emit
        from security.netid import actor_for
        emit("device", "vault.request", actor_for(req.handler), path=req.sub, method=req.method,
             result=int(status), caller="host" if req.host_signed else "session")
    except Exception:
        log.debug("vault security event failed", exc_info=True)


def route(req) -> bool:
    """Mounted at /api/vault (api/mounts.py)."""
    from plugins.vault.crypto import VaultCryptoError

    body = req.body if req.method in ("POST", "PATCH", "DELETE") else None
    try:
        out = handle_vault_request(req.method, req.sub_with_query, body, headers=req.handler.headers,
                                   read_raw=_reader(req.handler), host_signed=req.host_signed)
        if isinstance(out, Raw):
            _send_raw(req.handler, out)
            status = out.status
        else:
            status, payload = out
            req.reply(status, payload)
    except VaultCryptoError:
        status = 500
        req.reply(500, {"ok": False, "error": "That item couldn't be decrypted.", "code": "decrypt_failed"})
    if req.method == "PUT" and status != 200:
        req.handler.close_connection = True       # a refused PUT may leave its body unread
    if req.method != "GET" or status in (401, 403, 429):
        _emit(req, status)
    return True
