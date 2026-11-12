"""The vault as the webui runs it: store, sessions, passcode, Jarvis's approvals and link previews.

Jarvis's vault tools never touch the store themselves. A tool asks the webui for an approval
(host-signed loopback); the arguments stay here, bound to the approval id; the phone signs
``jarvis-vault|<command>|<approval id>|<ts>`` with its Face ID key; the action then runs exactly once
and its result waits here for the tool to collect it (once). Approval titles, push text and security
events never carry vault contents.
"""
from __future__ import annotations

import logging
import mimetypes
import secrets
import threading
import time
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeout
from pathlib import Path
from typing import Callable

from plugins.toyota.approver import CREATE_LIMIT, ApprovalError, Approvals
from plugins.vault.session import Passcode, Sessions
from plugins.vault.store import CHUNK_SIZE, MAX_SIZE, ROOT, NotFound, VaultStore, valid_id

log = logging.getLogger(__name__)

DOMAIN = "jarvis-vault"
COMMANDS = ("search", "list", "read", "save", "move", "delete")
TITLES = {"search": "Search your vault", "list": "Look in your vault", "read": "Open a vault item",
          "save": "Save to your vault", "move": "Move vault items", "delete": "Delete vault items"}
RESULT_TTL = 300          # seconds a finished result waits for the tool to collect it
PREVIEW_WAIT_S = 13.0
TOOL_FILE_MAX = MAX_SIZE
PDF_TEXT_MAX = 60_000
NOTE_TEXT_MAX = 60_000

# Link previews run on a small shared pool, so a burst of shares can't start a thread each.
_PREVIEW_POOL = ThreadPoolExecutor(max_workers=2, thread_name_prefix="vault-preview")
_INSTANCE_LOCK = threading.Lock()


def _plural(n: int, word: str) -> str:
    return f"{n} {word}{'' if n == 1 else 's'}"


class VaultApprovals(Approvals):
    """Toyota's approvals, except two waiting vault requests never replace each other (Jarvis may
    read two items at once)."""

    def create(self, command: str, source: str = "Jarvis", detail: str = "") -> dict:
        item = {"id": secrets.token_hex(12), "command": command, "title": self.titles.get(command, command),
                "source": source, "created": self.clock(), "detail": detail}
        with self._lock:
            self._sweep()
            now = self.clock()
            self._asked = [at for at in self._asked if now - at < 60]
            if len(self._asked) >= CREATE_LIMIT:
                raise ApprovalError("Too many vault approvals asked for. Wait a minute.", "rate_limited")
            self._asked.append(now)
            self._items[item["id"]] = item
        return self.public(item)

    def public(self, item: dict) -> dict:
        # "detail" is content-free (counts and kinds, never a title, query or URL).
        return {**super().public(item), "detail": item.get("detail") or ""}


def _notify_phone(item: dict) -> None:
    """A push with fixed text (never what Jarvis asked for), and the phone's approval sheet if the
    app is connected. Best effort, off the request thread."""

    def send():
        try:
            from api.coding_routes import _push_device_alert
            _push_device_alert("Jarvis wants to use your vault", "Approve it with Face ID.",
                               data={"type": "vault_approval"})
        except Exception as exc:
            log.warning("vault approval push failed: %s", type(exc).__name__)
        try:
            from api import device_bridge
            device = device_bridge.device_offering("vault_show_approvals")
            if device and device in device_bridge.connected_device_ids():
                device_bridge.invoke_skill(device, "vault_show_approvals", {}, timeout=8.0)
        except Exception as exc:
            log.debug("vault approval sheet nudge failed: %s", type(exc).__name__)

    threading.Thread(target=send, name="vault-approval-notify", daemon=True).start()


class VaultService:
    _instance: "VaultService | None" = None

    def __init__(self, root: Path | None = None, approver=None, clock: Callable[[], float] = time.time,
                 notify: Callable[[dict], None] | None = None, fetch_preview=None,
                 preview_wait_s: float = PREVIEW_WAIT_S) -> None:
        self.store = VaultStore(root, clock=clock)
        self.sessions = Sessions(clock)
        self.passcode = Passcode(self.store.dir / "passcode.json", clock, pepper=self._pepper)
        self._approver = approver
        self.approvals = VaultApprovals(clock=clock, titles=TITLES, label="vault")
        self.clock = clock
        self.notify = notify or _notify_phone
        self._fetch = fetch_preview
        self.preview_wait_s = preview_wait_s
        self._args: dict[str, dict] = {}
        self._results: dict[str, dict] = {}
        self._lock = threading.Lock()
        self._retry_at = 0.0
        self._retrying = False

    @classmethod
    def instance(cls) -> "VaultService":
        if cls._instance is None:
            with _INSTANCE_LOCK:
                if cls._instance is None:
                    cls._instance = cls()
        return cls._instance

    def _pepper(self) -> bytes:
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.kdf.hkdf import HKDF

        return HKDF(algorithm=hashes.SHA256(), length=32, salt=None,
                    info=b"jarvis-vault-passcode-pepper").derive(self.store.master)

    @property
    def approver(self):
        if self._approver is None:
            from plugins.toyota.approver import approver
            self._approver = approver()
        return self._approver

    # ── unlock ────────────────────────────────────────────────────────────
    def status(self) -> dict:
        out = {"ok": True, "passcode_set": self.passcode.is_set(),
               "approver_registered": self.approver.registered() is not None}
        wait = self.passcode.retry_after()
        if wait:
            out["retry_after_s"] = wait
        return out

    def unlock_face_id(self, body: dict) -> dict:
        self.approver.verify("unlock", body.get("nonce"), body.get("ts"), body.get("signature"), domain=DOMAIN)
        return self.sessions.issue()

    def set_passcode(self, body: dict) -> dict:
        self.approver.verify("passcode", body.get("nonce"), body.get("ts"), body.get("signature"), domain=DOMAIN)
        self.passcode.set(body.get("passcode"))
        self.sessions.revoke_all()          # a new passcode ends every open session
        return {"ok": True}

    # ── link previews ─────────────────────────────────────────────────────
    def _fetch_preview(self, url: str):
        if self._fetch is not None:
            return self._fetch(url)
        from plugins.vault import preview
        return preview.fetch(url)

    def _preview_into(self, item_id: str, url: str) -> None:
        try:
            if not self.store.mark_preview_attempt(item_id):     # counted first: a crash can't loop
                return
            try:
                got = self._fetch_preview(url)
            except Exception:
                got = None
            if got is None:
                self.store.save_preview(item_id, None)
            else:
                self.store.save_preview(item_id, got.get("preview") or {}, got.get("image"), got.get("favicon"))
        except Exception as exc:
            log.warning("vault link preview failed: %s", type(exc).__name__)

    def preview_link(self, item_id: str, url: str, wait: bool) -> None:
        future = _PREVIEW_POOL.submit(self._preview_into, item_id, url)
        if wait:
            try:
                future.result(timeout=self.preview_wait_s)
            except FutureTimeout:
                pass

    def retry_previews(self) -> None:
        """On a listing: fetch previews still pending or failed (a few tries), one worker at a time."""
        now = self.clock()
        with self._lock:
            if self._retrying or now < self._retry_at:
                return
            self._retrying, self._retry_at = True, now + 60

        def work():
            try:
                for item_id, url in self.store.links_pending():
                    self._preview_into(item_id, url)
            except Exception as exc:
                log.debug("vault preview retry failed: %s", type(exc).__name__)
            finally:
                self._retrying = False

        _PREVIEW_POOL.submit(work)

    def live_preview(self, url: str) -> dict:
        """POST /link-preview: nothing stored."""
        import base64

        from plugins.vault.store import domain_of, make_thumbnail
        from urllib.parse import urlparse

        url = str(url or "").strip()
        if urlparse(url).scheme not in ("http", "https") or not urlparse(url).hostname:
            raise ValueError("That isn't a web link.")
        got = self._fetch_preview(url)
        if got is None:
            return {"ok": True, "preview": {"title": "", "site_name": domain_of(url), "domain": domain_of(url),
                                            "kind": "page", "duration_s": None, "author": None},
                    "thumb_jpeg_b64": None, "preview_status": "failed"}
        p = got.get("preview") or {}
        thumb = make_thumbnail(got["image"]) if got.get("image") else None
        return {"ok": True,
                "preview": {k: p.get(k) for k in ("title", "site_name", "domain", "kind", "duration_s", "author")},
                "thumb_jpeg_b64": base64.b64encode(thumb[0]).decode() if thumb else None,
                "preview_status": "ok"}

    def refresh_preview(self, item_id: str) -> dict:
        """POST /items/<id>/preview: fetch a link's preview again now."""
        url = self.store.reset_preview(item_id)
        self.preview_link(item_id, url, wait=True)
        return self.store.get_item(item_id, body=False)

    def create_link(self, parent_id, url, note=None, title=None, fallback_root=False, wait=True) -> dict:
        item = self.store.create_link(parent_id, url, note=note, title=title, fallback_root=fallback_root)
        self.preview_link(item["id"], item["link"]["url"], wait=wait)
        return self.store.get_item(item["id"], body=False) if wait else item

    # ── files from the server's disk (Jarvis's vault_save with an attachment) ──
    def import_file(self, parent_id, path: str, title: str = "", kind: str | None = None) -> dict:
        src = Path(str(path or "")).expanduser()
        try:
            src = src.resolve(strict=True)
        except (OSError, RuntimeError):
            raise ValueError("That file doesn't exist.")
        guarded = (self.store.dir.resolve(), self.store.master_key_path.parent.resolve())
        if any(src == g or g in src.parents for g in guarded):
            raise ValueError("That file can't be saved to the vault.")
        if not src.is_file():
            raise ValueError("That isn't a file.")
        size = src.stat().st_size
        if size > TOOL_FILE_MAX:
            raise ValueError("That file is over 2 GB.")
        mime = mimetypes.guess_type(src.name)[0] or "application/octet-stream"
        if kind not in ("image", "video", "pdf", "file"):
            kind = ("image" if mime.startswith("image/") else "video" if mime.startswith("video/")
                    else "pdf" if mime == "application/pdf" else "file")
        up = self.store.start_upload({"parent_id": parent_id, "kind": kind, "filename": src.name, "mime": mime,
                                      "size": size, "title": title})
        done = False
        try:
            with open(src, "rb") as handle:
                for index in range(self.store.chunk_count(size)):
                    chunk = handle.read(CHUNK_SIZE)
                    if len(chunk) != min(CHUNK_SIZE, size - index * CHUNK_SIZE):
                        raise ValueError("That file changed while it was being saved.")
                    self.store.put_chunk(up["upload_id"], index, chunk)
            item = self.store.finish_upload(up["upload_id"])
            done = True
            return item
        finally:
            if not done:
                self.store.abort_upload(up["upload_id"])     # no half-written blob left behind

    # ── Jarvis's approvals ────────────────────────────────────────────────
    def resolve_folder(self, ref, create: bool = False) -> str:
        """A folder id from an id, "root", a name or a path like "Travel/Japan 2026" (case-insensitive)."""
        ref = str(ref or "").strip()
        if ref.lower() in ("", "root", "/", "vault"):
            return ROOT
        tree = self.store.tree()
        if valid_id(ref) and any(f["id"] == ref for f in tree):
            return ref
        parts = [p.strip() for p in ref.replace("›", "/").replace(">", "/").split("/") if p.strip()]
        if parts and parts[0].lower() == "vault":
            parts = parts[1:]
        if not parts:
            return ROOT
        children: dict[str, list[dict]] = {}
        for f in tree:
            children.setdefault(f["parent_id"], []).append(f)

        def walk(parent: str, rest: list[str]):
            match = [f for f in children.get(parent, []) if f["name"].lower() == rest[0].lower()]
            if not match:
                return None, rest
            return (match[0]["id"], []) if len(rest) == 1 else walk(match[0]["id"], rest[1:])

        found, rest = walk(ROOT, parts)
        if found:
            return found
        if len(parts) == 1:
            named = [f for f in tree if f["name"].lower() == parts[0].lower()]
            if len(named) == 1:
                return named[0]["id"]
            if len(named) > 1:
                raise ValueError("More than one folder has that name; give its path, like Parent/Child.")
        if not create:
            raise ValueError("There's no vault folder by that name.")
        parent = ROOT
        for name in parts:
            match = [f for f in children.get(parent, []) if f["name"].lower() == name.lower()]
            if match:
                parent = match[0]["id"]
            else:
                parent = self.store.create_folder(parent, name)["id"]
                children.setdefault(parent, [])
        return parent

    @staticmethod
    def _check_args(command: str, args: dict) -> dict:
        args = args if isinstance(args, dict) else {}
        if command == "search":
            query = str(args.get("query") or "").strip()
            if not query:
                raise ValueError("Search for something.")
            return {"query": query[:300]}
        if command == "list":
            return {"folder": str(args.get("folder") or "")[:500]}
        if command == "read":
            if not valid_id(str(args.get("id") or "")):
                raise ValueError("vault_read needs an item id from vault_search or vault_list.")
            return {"id": str(args["id"])}
        if command == "save":
            kind = str(args.get("kind") or "note")
            if kind not in ("note", "link", "file"):
                raise ValueError("kind is note, link or file.")
            out = {"kind": kind, "folder": str(args.get("folder") or "")[:500],
                   "title": str(args.get("title") or "")[:300]}
            if kind == "note":
                out["body"] = str(args.get("body") or "")
                if not out["body"].strip() and not out["title"]:
                    raise ValueError("A note needs a title or body.")
            elif kind == "link":
                out["url"] = str(args.get("url") or "")
                out["body"] = str(args.get("body") or "")
                if not out["url"].startswith(("http://", "https://")):
                    raise ValueError("A link needs an http(s) url.")
            else:
                out["path"] = str(args.get("path") or "")
                if not out["path"]:
                    raise ValueError("A file save needs the attachment's path.")
            return out
        if command in ("move", "delete"):
            ids = [str(i) for i in (args.get("ids") or []) if valid_id(str(i))]
            if not ids:
                raise ValueError("Give the item ids (from vault_search or vault_list).")
            out = {"ids": ids[:200]}
            if command == "move":
                out["folder"] = str(args.get("folder") or "")[:500]
            return out
        raise ValueError("Unknown vault action.")

    def detail(self, command: str, args: dict) -> str:
        """What the approval is about, content-free: counts and kinds, never a title, query or URL."""
        if command == "search":
            return "a search"
        if command == "list":
            return "the top of the vault" if args.get("folder", "").strip().lower() in ("", "root", "/", "vault") \
                else "one folder's list"
        if command == "read":
            return "one item"
        if command == "save":
            return f"a new {args['kind']}"
        d = self.store.describe(args["ids"])
        text = _plural(d["items"], "item")
        if d["folders"]:
            text += (f", including {_plural(d['folders'], 'folder')} with {_plural(d['inside'], 'item')} inside")
        return text + (" into another folder" if command == "move" else "")

    def request(self, command: str, args: dict) -> dict:
        if command not in COMMANDS:
            raise ValueError("Unknown vault action.")
        clean = self._check_args(command, args)
        detail = self.detail(command, clean)
        with self._lock:
            self._sweep_results()
            item = self.approvals.create(command, detail=detail)
            self._args[item["id"]] = clean          # bound before anyone can see the approval
        self.notify(item)
        return item

    def _sweep_results(self) -> None:
        now = self.clock()
        for key, r in list(self._results.items()):
            if now - r["at"] > RESULT_TTL:
                del self._results[key]
        live = {a["id"] for a in self.approvals.pending()}
        for key in list(self._args):
            if key not in live:
                del self._args[key]

    def approve(self, approval_id: str, body: dict) -> dict:
        item = self.approvals.peek(approval_id)
        self.approver.verify(item["command"], approval_id, body.get("ts"), body.get("signature"), domain=DOMAIN)
        with self._lock:
            # Popped before take(): a sweep between the two can't drop them.
            args = self._args.pop(approval_id, None)
        self.approvals.take(approval_id)        # raises "gone" if answered meanwhile: runs at most once
        if args is None:
            raise ApprovalError("That approval has expired or was already answered.", "gone")
        try:
            result, summary = self.run(item["command"], args)
            outcome = {"status": "done", "result": result}
        except (ValueError, NotFound) as exc:
            summary = "That didn't work."
            outcome = {"status": "error", "error": str(exc) or "Not found."}
        except Exception as exc:
            log.error("vault action %s failed: %s", item["command"], type(exc).__name__)
            summary = "That didn't work."
            outcome = {"status": "error", "error": "The vault action failed on the server."}
        with self._lock:
            self._results[approval_id] = {**outcome, "at": self.clock()}
        return {"ok": True, "result_summary": summary}

    def deny(self, approval_id: str) -> dict:
        self.approvals.take(approval_id)
        with self._lock:
            self._args.pop(approval_id, None)
            self._results[approval_id] = {"status": "denied", "at": self.clock()}
        return {"ok": True}

    def collect(self, approval_id: str) -> dict:
        """The tool's poll: pending, or the outcome (handed out once)."""
        with self._lock:
            self._sweep_results()
            done = self._results.pop(str(approval_id), None)
        if done is not None:
            done.pop("at", None)
            return {"ok": True, **done}
        try:
            self.approvals.peek(approval_id)
            return {"ok": True, "status": "pending"}
        except ApprovalError:
            return {"ok": True, "status": "expired"}

    # ── the actions (run only after Face ID) ──────────────────────────────
    @staticmethod
    def _brief(item: dict) -> dict:
        out = {k: item.get(k) for k in ("id", "kind", "title", "created", "size", "mime", "filename",
                                        "duration_s", "snippet")}
        if item.get("link"):
            out["url"] = item["link"]["url"]
            out["site"] = item["link"]["site_name"]
        if "path" in item:
            out["folder"] = item["path"] or "Vault"
        return {k: v for k, v in out.items() if v not in (None, "")}

    def run(self, command: str, args: dict) -> tuple[dict, str]:
        s = self.store
        if command == "search":
            found = s.search(args["query"], limit=50)
            n = len(found["items"]) + len(found["folders"])
            return ({"items": [self._brief(i) for i in found["items"]],
                     "folders": [{"id": f["id"], "name": f["name"], "count": f["count"]} for f in found["folders"]]},
                    f"Found {n} match{'es' if n != 1 else ''}")
        if command == "list":
            view = s.folder_view(self.resolve_folder(args["folder"]))
            return ({"folder": " › ".join(p["name"] for p in view["folder"]["path"]),
                     "folders": [{"id": f["id"], "name": f["name"], "count": f["count"]} for f in view["folders"]],
                     "items": [self._brief(i) for i in view["items"]]},
                    f"Listed {len(view['folders']) + len(view['items'])}")
        if command == "read":
            return self._read(args["id"]), "Opened 1 item"
        if command == "save":
            parent = self.resolve_folder(args["folder"], create=True)
            if args["kind"] == "note":
                item = s.create_note(parent, args["title"], args["body"])
            elif args["kind"] == "link":
                item = self.create_link(parent, args["url"], note=args.get("body") or None,
                                        title=args["title"] or None)
            else:
                item = self.import_file(parent, args["path"], args["title"])
            return {"saved": self._brief(item)}, "Saved 1 item"
        if command == "move":
            moved = s.move(args["ids"], self.resolve_folder(args["folder"]))
            return {"moved": moved}, f"Moved {moved}"
        if command == "delete":
            deleted = s.delete(args["ids"])
            return {"deleted": deleted}, f"Deleted {deleted}"
        raise ValueError("Unknown vault action.")

    def _read(self, item_id: str) -> dict:
        item, meta = self.store.item_meta(item_id)
        if item["kind"] == "folder":
            raise NotFound("That's a folder; use vault_list.")
        out = self._brief(item)
        if item["kind"] == "note":
            out["body"] = (item.get("body") or "")[:NOTE_TEXT_MAX]
        elif item["kind"] == "link":
            out["link"] = item["link"]
            out["note"] = item.get("note") or ""
        elif item["kind"] == "pdf":
            out["pages"] = item.get("pages")
            text = self._pdf_text(item_id, item["size"])
            if text is not None:
                out["text"] = text
        else:
            out.update({k: item.get(k) for k in ("width", "height", "pages") if item.get(k) is not None})
        return out

    def _pdf_text(self, item_id: str, size: int) -> str | None:
        try:
            import io

            import pypdf
        except ImportError:
            return None
        if size > 200 * 1024 * 1024:
            return None
        try:
            raw = b"".join(self.store.read_blob(item_id, "content"))
            reader = pypdf.PdfReader(io.BytesIO(raw))
            parts, total = [], 0
            for page in reader.pages:
                t = page.extract_text() or ""
                parts.append(t)
                total += len(t)
                if total > PDF_TEXT_MAX:
                    break
            return "\n".join(parts)[:PDF_TEXT_MAX]
        except Exception:
            return None
