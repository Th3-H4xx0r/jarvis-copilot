"""The vault's items on disk: SQLite metadata + encrypted blob files under ``<root>/vault/``.

Plaintext columns are only what the server needs to arrange rows: id, parent_id, kind, created,
updated, size and segment counts. Everything a person could read (names, titles, note text, link
URLs and previews, filenames, MIME types, durations, dimensions) is in one encrypted JSON blob per
row (crypto.seal_meta). Folders are rows of kind "folder"; the root is the virtual id "root".

Never log titles, contents or URLs from here.
"""
from __future__ import annotations

import io
import json
import re
import secrets
import sqlite3
import threading
import time
import warnings
from contextlib import contextmanager
from pathlib import Path
from typing import Callable, Iterable
from urllib.parse import urlparse

from plugins.vault import crypto

ROOT = "root"
ITEM_KINDS = ("note", "link", "image", "video", "pdf", "file")
FILE_KINDS = ("image", "video", "pdf", "file")
BLOB_KINDS = ("content", "thumb", "favicon")
# Bumped when plugins/vault/preview.py gets better at finding previews: links saved by an older
# engine without a thumbnail get one more try with the new one.
PREVIEW_ENGINE = 2
CHUNK_SIZE = 8 * 1024 * 1024        # upload chunk = 8 segments exactly, so a chunk never straddles one
MAX_SIZE = 2 * 1024 * 1024 * 1024   # 2 GiB per item
MAX_THUMB = 2 * 1024 * 1024
MAX_NOTE = 1024 * 1024
STALE_UPLOAD_S = 24 * 3600
THUMB_FROM_CONTENT_MAX = 64 * 1024 * 1024   # images bigger than this get no server-made thumbnail
MAX_PIXELS = 40_000_000                     # refuse to decode bigger images (decompression bombs)
MAX_OPEN_INBOX_UPLOADS = 20
_ID = re.compile(r"^[0-9a-f]{24}$")
# type/subtype only: a stored MIME type becomes a Content-Type header, so nothing else gets through.
_MIME = re.compile(r"^[a-z0-9][a-z0-9!#$&^_.+-]{0,63}/[a-z0-9][a-z0-9!#$&^_.+-]{0,126}$")

_SCHEMA = """
CREATE TABLE IF NOT EXISTS items (
    id TEXT PRIMARY KEY,
    parent_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    created INTEGER NOT NULL,
    updated INTEGER NOT NULL,
    size INTEGER NOT NULL DEFAULT 0,
    segments INTEGER NOT NULL DEFAULT 0,
    thumb_segments INTEGER NOT NULL DEFAULT 0,
    favicon_segments INTEGER NOT NULL DEFAULT 0,
    wrapped_key BLOB NOT NULL,
    meta BLOB NOT NULL
);
CREATE INDEX IF NOT EXISTS items_parent ON items(parent_id);
CREATE TABLE IF NOT EXISTS uploads (
    id TEXT PRIMARY KEY,
    item_id TEXT NOT NULL,
    inbox INTEGER NOT NULL DEFAULT 0,
    created INTEGER NOT NULL,
    size INTEGER NOT NULL,
    chunk_size INTEGER NOT NULL,
    received TEXT NOT NULL DEFAULT '[]',
    wrapped_key BLOB NOT NULL,
    meta BLOB NOT NULL,
    finished INTEGER NOT NULL DEFAULT 0
);
"""


class NotFound(Exception):
    pass


class Busy(Exception):
    """Too much at once (open inbox uploads, the same chunk twice in flight). Try again."""


def safe_mime(value, default: str = "application/octet-stream") -> str:
    text = str(value or "").strip().lower()
    return text if _MIME.match(text) else default


def valid_id(value) -> bool:
    return isinstance(value, str) and bool(_ID.match(value))


def new_id() -> str:
    return secrets.token_hex(12)


def domain_of(url: str) -> str:
    host = (urlparse(url).hostname or "").lower()
    return host[4:] if host.startswith("www.") else host


def _clean_text(value, limit: int) -> str:
    return str(value if value is not None else "").strip()[:limit]


def _num(value, kind=float):
    try:
        if value is None or value == "":
            return None
        out = kind(value)
        return out if out >= 0 else None
    except (TypeError, ValueError):
        return None


def image_size(raw: bytes):
    try:
        from PIL import Image

        with Image.open(io.BytesIO(raw)) as img:
            return img.size
    except Exception:
        return None


def make_thumbnail(raw: bytes, width: int = 640):
    """A JPEG thumbnail (≤ ``width`` px wide) of an image, made in memory. None if it isn't one, or
    if it claims more than MAX_PIXELS (checked from the header, before anything is decoded)."""
    try:
        from PIL import Image, ImageOps

        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(io.BytesIO(raw)) as img:
                full = img.size
                if full[0] <= 0 or full[1] <= 0 or full[0] * full[1] > MAX_PIXELS:
                    return None
                img.draft("RGB", (width, width * 4))       # JPEG: decode at a reduced scale
                img.thumbnail((width, width * 4))
                img = ImageOps.exif_transpose(img).convert("RGB")
                out = io.BytesIO()
                img.save(out, "JPEG", quality=82)
                return out.getvalue(), img.size, full
    except Exception:
        return None


class VaultStore:
    def __init__(self, root: Path | None = None, master_key_path: Path | None = None,
                 clock: Callable[[], float] = time.time) -> None:
        if root is None:
            from jarviscopilot_constants import get_default_hermes_root

            root = get_default_hermes_root()
        self.dir = Path(root) / "vault"
        self.blob_dir = self.dir / "blobs"
        self.db_path = self.dir / "vault.db"
        self.master_key_path = master_key_path or (Path(root) / "secrets" / "vault_master.key")
        self.clock = clock
        self._master: bytes | None = None
        self._lock = threading.RLock()
        self._ready = False
        self._inflight: set = set()

    # ── plumbing ──────────────────────────────────────────────────────────
    @property
    def master(self) -> bytes:
        if self._master is None:
            self._master = crypto.load_master_key(self.master_key_path)
        return self._master

    @contextmanager
    def _db(self):
        """A connection for one operation: committed on success, rolled back on error, always closed."""
        conn = self._connect()
        try:
            with conn:
                yield conn
        finally:
            conn.close()

    def _connect(self) -> sqlite3.Connection:
        if not self._ready:
            self.dir.mkdir(parents=True, exist_ok=True)
            self.blob_dir.mkdir(parents=True, exist_ok=True)
            for d in (self.dir, self.blob_dir):
                try:
                    d.chmod(0o700)
                except OSError:
                    pass
        conn = sqlite3.connect(str(self.db_path), timeout=15)
        conn.row_factory = sqlite3.Row
        if not self._ready:
            conn.executescript(_SCHEMA)
            cols = {r[1] for r in conn.execute("PRAGMA table_info(uploads)")}
            if "finished" not in cols:
                conn.execute("ALTER TABLE uploads ADD COLUMN finished INTEGER NOT NULL DEFAULT 0")
            try:
                self.db_path.chmod(0o600)
            except OSError:
                pass
            self._ready = True
        return conn

    def blob_path(self, item_id: str, kind: str) -> Path:
        if not valid_id(item_id) or kind not in BLOB_KINDS:
            raise NotFound("no such item")
        return self.blob_dir / f"{item_id}.{kind}"

    def _now(self) -> int:
        return int(self.clock())

    def _row(self, conn, item_id: str):
        if not valid_id(item_id):
            raise NotFound("no such item")
        row = conn.execute("SELECT * FROM items WHERE id=?", (item_id,)).fetchone()
        if row is None:
            raise NotFound("no such item")
        return row

    def _open(self, row) -> tuple[bytes, dict]:
        dk = crypto.unwrap_key(self.master, row["id"], row["wrapped_key"])
        return dk, crypto.open_meta(dk, row["id"], row["meta"])

    def _insert(self, conn, item_id: str, parent_id: str, kind: str, meta: dict, dk: bytes | None = None,
                size: int = 0, created: int | None = None) -> None:
        dk = dk or crypto.new_data_key()
        now = self._now()
        blobs = meta.get("blobs") or {}
        conn.execute(
            "INSERT INTO items (id,parent_id,kind,created,updated,size,segments,thumb_segments,favicon_segments,"
            "wrapped_key,meta) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            (item_id, parent_id, kind, created or now, now, int(size),
             crypto.segment_count(int(blobs.get("content") or 0)),
             crypto.segment_count(int(blobs.get("thumb") or 0)),
             crypto.segment_count(int(blobs.get("favicon") or 0)),
             crypto.wrap_key(self.master, item_id, dk), crypto.seal_meta(dk, item_id, meta)))

    def _update_meta(self, conn, row, dk: bytes, meta: dict, size: int | None = None,
                     parent_id: str | None = None, touch: bool = True) -> None:
        blobs = meta.get("blobs") or {}
        conn.execute(
            "UPDATE items SET meta=?, updated=?, size=?, parent_id=?, segments=?, thumb_segments=?, "
            "favicon_segments=? WHERE id=?",
            (crypto.seal_meta(dk, row["id"], meta), self._now() if touch else row["updated"],
             row["size"] if size is None else int(size), parent_id or row["parent_id"],
             crypto.segment_count(int(blobs.get("content") or 0)),
             crypto.segment_count(int(blobs.get("thumb") or 0)),
             crypto.segment_count(int(blobs.get("favicon") or 0)), row["id"]))

    def _structure(self, conn) -> dict[str, tuple[str, str]]:
        """id -> (parent_id, kind) for every row: plaintext only, nothing decrypted."""
        return {r["id"]: (r["parent_id"], r["kind"]) for r in conn.execute("SELECT id,parent_id,kind FROM items")}

    def _folder_parent(self, conn, parent_id, fallback_root: bool = False) -> str:
        parent_id = str(parent_id or ROOT)
        if parent_id == ROOT:
            return ROOT
        row = conn.execute("SELECT kind FROM items WHERE id=?", (parent_id,)).fetchone() if valid_id(parent_id) else None
        if row is None or row["kind"] != "folder":
            if fallback_root:
                return ROOT
            raise ValueError("That folder doesn't exist.")
        return parent_id

    # ── JSON shapes ───────────────────────────────────────────────────────
    def _folder_json(self, row, meta: dict, counts: dict[str, int]) -> dict:
        return {"id": row["id"], "parent_id": row["parent_id"], "name": meta.get("name") or "Folder",
                "count": counts.get(row["id"], 0)}

    def _item_json(self, row, meta: dict, body: bool = False) -> dict:
        kind = row["kind"]
        blobs = meta.get("blobs") or {}
        title = meta.get("title") or ""
        link = None
        note = None
        snippet = None
        if kind == "note":
            text = meta.get("body") or ""
            if not title:
                title = (text.strip().splitlines() or ["Note"])[0][:120] or "Note"
            snippet = " ".join(text.split())[:200]
        elif kind == "link":
            preview = meta.get("preview") or {}
            url = meta.get("url") or ""
            title = title or preview.get("title") or domain_of(url) or url
            note = meta.get("note") or ""
            link = {"url": url, "site_name": preview.get("site_name") or domain_of(url),
                    "domain": domain_of(url), "kind": preview.get("kind") or "page",
                    "author": preview.get("author"), "description": preview.get("description"),
                    "has_favicon": bool(blobs.get("favicon"))}
        else:
            title = title or meta.get("filename") or kind.capitalize()
        out = {
            "id": row["id"], "parent_id": row["parent_id"], "kind": kind, "title": title,
            "raw_title": meta.get("title") or "",
            "created": row["created"], "updated": row["updated"], "size": row["size"],
            "mime": meta.get("mime") or ("text/plain" if kind == "note" else None),
            "filename": meta.get("filename"), "has_thumb": bool(blobs.get("thumb")),
            "thumb_w": meta.get("thumb_w"), "thumb_h": meta.get("thumb_h"),
            "duration_s": (meta.get("preview") or {}).get("duration_s") if kind == "link" else meta.get("duration_s"),
            "width": meta.get("width"), "height": meta.get("height"), "pages": meta.get("pages"),
            "snippet": snippet, "link": link,
            "preview_status": meta.get("preview_status") if kind == "link" else None,
            "note": note,
        }
        if body and kind == "note":
            out["body"] = meta.get("body") or ""
        return out

    def _counts(self, structure: dict) -> dict[str, int]:
        counts: dict[str, int] = {}
        for item_id, (parent, kind) in structure.items():
            if kind == "folder":
                continue
            seen = set()
            while parent and parent != ROOT and parent not in seen:
                seen.add(parent)
                counts[parent] = counts.get(parent, 0) + 1
                parent = structure.get(parent, (None, None))[0]
        return counts

    def _folder_names(self, conn) -> dict[str, tuple[str, str]]:
        """folder id -> (parent_id, name), decrypted."""
        out = {}
        for row in conn.execute("SELECT * FROM items WHERE kind='folder'"):
            try:
                out[row["id"]] = (row["parent_id"], self._open(row)[1].get("name") or "Folder")
            except crypto.VaultCryptoError:
                out[row["id"]] = (row["parent_id"], "Folder")
        return out

    @staticmethod
    def _path_of(folder_id: str, names: dict) -> list[dict]:
        path, seen = [], set()
        while folder_id and folder_id != ROOT and folder_id in names and folder_id not in seen:
            seen.add(folder_id)
            parent, name = names[folder_id]
            path.append({"id": folder_id, "name": name})
            folder_id = parent
        return list(reversed(path))

    # ── folders ───────────────────────────────────────────────────────────
    def tree(self) -> list[dict]:
        with self._lock, self._db() as conn:
            counts = self._counts(self._structure(conn))
            return [self._folder_json(r, self._open(r)[1], counts)
                    for r in conn.execute("SELECT * FROM items WHERE kind='folder' ORDER BY created")]

    def folder_view(self, folder_id: str) -> dict:
        folder_id = str(folder_id or ROOT)
        with self._lock, self._db() as conn:
            structure = self._structure(conn)
            counts = self._counts(structure)
            names = self._folder_names(conn)
            if folder_id == ROOT:
                folder = {"id": ROOT, "name": "Vault", "parent_id": None, "path": [{"id": ROOT, "name": "Vault"}]}
            else:
                if structure.get(folder_id, (None, None))[1] != "folder":
                    raise NotFound("no such folder")
                folder = {"id": folder_id, "name": names[folder_id][1], "parent_id": names[folder_id][0],
                          "path": [{"id": ROOT, "name": "Vault"}] + self._path_of(folder_id, names)}
            folders, items = [], []
            for row in conn.execute("SELECT * FROM items WHERE parent_id=? ORDER BY created DESC, rowid DESC",
                                    (folder_id,)):
                meta = self._open(row)[1]
                if row["kind"] == "folder":
                    folders.append(self._folder_json(row, meta, counts))
                else:
                    items.append(self._item_json(row, meta))
            folders.sort(key=lambda f: f["name"].lower())
            return {"folder": folder, "folders": folders, "items": items}

    def create_folder(self, parent_id, name) -> dict:
        name = _clean_text(name, 200)
        if not name:
            raise ValueError("A folder needs a name.")
        with self._lock, self._db() as conn:
            parent = self._folder_parent(conn, parent_id)
            item_id = new_id()
            self._insert(conn, item_id, parent, "folder", {"name": name})
            row = self._row(conn, item_id)
            return self._folder_json(row, {"name": name}, {})

    def update_folder(self, folder_id: str, name=None, parent_id=None) -> dict:
        with self._lock, self._db() as conn:
            row = self._row(conn, folder_id)
            if row["kind"] != "folder":
                raise NotFound("no such folder")
            dk, meta = self._open(row)
            new_parent = None
            if parent_id is not None:
                new_parent = self._folder_parent(conn, parent_id)
                structure = self._structure(conn)
                walk, seen = new_parent, set()
                while walk and walk != ROOT and walk not in seen:
                    if walk == folder_id:
                        raise ValueError("A folder can't move into itself or a folder inside it.")
                    seen.add(walk)
                    walk = structure.get(walk, (None, None))[0]
            if name is not None:
                name = _clean_text(name, 200)
                if not name:
                    raise ValueError("A folder needs a name.")
                meta["name"] = name
            self._update_meta(conn, row, dk, meta, parent_id=new_parent)
            counts = self._counts(self._structure(conn))
            return self._folder_json(self._row(conn, folder_id), meta, counts)

    def descendants(self, conn, folder_id: str) -> list[str]:
        structure = self._structure(conn)
        children: dict[str, list[str]] = {}
        for item_id, (parent, _) in structure.items():
            children.setdefault(parent, []).append(item_id)
        out, stack = [], [folder_id]
        while stack:
            current = stack.pop()
            for child in children.get(current, []):
                out.append(child)
                stack.append(child)
        return out

    def delete_folder(self, folder_id: str) -> int:
        with self._lock:
            with self._db() as conn:
                row = self._row(conn, folder_id)
                if row["kind"] != "folder":
                    raise NotFound("no such folder")
                doomed = [folder_id] + self.descendants(conn, folder_id)
                self._delete_rows(conn, doomed)
            self._unlink_blobs(doomed)          # only after the rows are gone for good
            return len(doomed)

    @staticmethod
    def _delete_rows(conn, ids: Iterable[str]) -> None:
        for item_id in ids:
            conn.execute("DELETE FROM items WHERE id=?", (item_id,))

    def _unlink_blobs(self, ids: Iterable[str]) -> None:
        for item_id in ids:
            for kind in BLOB_KINDS:
                try:
                    self.blob_path(item_id, kind).unlink()
                    tmp = self.blob_path(item_id, kind).with_name(f"{item_id}.{kind}.tmp")
                    if tmp.exists():
                        tmp.unlink()
                except (FileNotFoundError, NotFound):
                    pass

    def describe(self, ids) -> dict:
        """Counts only (for an approval's detail): how many of ``ids`` exist, how many are folders,
        and how many items those folders hold. Nothing decrypted."""
        ids = [str(i) for i in (ids or []) if valid_id(str(i))]
        with self._lock, self._db() as conn:
            structure = self._structure(conn)
            found = [i for i in ids if i in structure]
            folders = [i for i in found if structure[i][1] == "folder"]
            inside = set()
            for f in folders:
                inside.update(d for d in self.descendants(conn, f) if structure.get(d, (None, ""))[1] != "folder")
            return {"items": len(found), "folders": len(folders), "inside": len(inside - set(found))}

    # ── items ─────────────────────────────────────────────────────────────
    def get_item(self, item_id: str, body: bool = True) -> dict:
        with self._lock, self._db() as conn:
            row = self._row(conn, item_id)
            if row["kind"] == "folder":
                raise NotFound("no such item")
            return self._item_json(row, self._open(row)[1], body=body)

    def item_meta(self, item_id: str) -> tuple[dict, dict]:
        """(item json, raw meta) — for the server's own use (tools, previews)."""
        with self._lock, self._db() as conn:
            row = self._row(conn, item_id)
            meta = self._open(row)[1]
            return self._item_json(row, meta, body=True), meta

    def recent(self, limit: int = 30) -> list[dict]:
        limit = max(1, min(int(limit or 30), 200))
        with self._lock, self._db() as conn:
            rows = conn.execute("SELECT * FROM items WHERE kind!='folder' ORDER BY created DESC, rowid DESC LIMIT ?",
                                (limit,)).fetchall()
            return [self._item_json(r, self._open(r)[1]) for r in rows]

    def search(self, query: str, limit: int = 100) -> dict:
        """Decrypt-on-search: N is small, and nothing decrypted outlives the request."""
        terms = [t for t in str(query or "").lower().split() if t]
        if not terms:
            return {"items": [], "folders": []}
        with self._lock, self._db() as conn:
            names = self._folder_names(conn)
            counts = self._counts(self._structure(conn))
            items, folders = [], []
            for row in conn.execute("SELECT * FROM items ORDER BY created DESC, rowid DESC"):
                meta = self._open(row)[1]
                if row["kind"] == "folder":
                    hay = (meta.get("name") or "").lower()
                    if all(t in hay for t in terms):
                        folders.append(self._folder_json(row, meta, counts))
                    continue
                item = self._item_json(row, meta)
                preview = meta.get("preview") or {}
                hay = " ".join(str(x or "") for x in (
                    item["title"], meta.get("body"), meta.get("note"), meta.get("url"), meta.get("filename"),
                    preview.get("title"), preview.get("site_name"), preview.get("author"),
                    preview.get("description"))).lower()
                if all(t in hay for t in terms):
                    item["path"] = " › ".join(p["name"] for p in self._path_of(row["parent_id"], names)) or None
                    items.append(item)
                    if len(items) >= limit:
                        break
            return {"items": items, "folders": folders}

    def create_note(self, parent_id, title, body, fallback_root: bool = False) -> dict:
        body = str(body or "")
        if len(body.encode()) > MAX_NOTE:
            raise ValueError("That note is too long.")
        with self._lock, self._db() as conn:
            parent = self._folder_parent(conn, parent_id, fallback_root)
            item_id = new_id()
            meta = {"title": _clean_text(title, 300), "body": body}
            self._insert(conn, item_id, parent, "note", meta, size=len(body.encode()))
            return self._item_json(self._row(conn, item_id), meta, body=True)

    def create_link(self, parent_id, url, note=None, title=None, fallback_root: bool = False) -> dict:
        url = _clean_text(url, 4000)
        if urlparse(url).scheme not in ("http", "https") or not urlparse(url).hostname:
            raise ValueError("That isn't a web link.")
        with self._lock, self._db() as conn:
            parent = self._folder_parent(conn, parent_id, fallback_root)
            item_id = new_id()
            meta = {"title": _clean_text(title, 300), "url": url, "note": str(note or "")[:MAX_NOTE],
                    "preview": {}, "preview_status": "pending", "preview_tries": 0}
            self._insert(conn, item_id, parent, "link", meta)
            return self._item_json(self._row(conn, item_id), meta)

    def update_item(self, item_id: str, title=None, body=None, note=None, parent_id=None) -> dict:
        with self._lock, self._db() as conn:
            row = self._row(conn, item_id)
            if row["kind"] == "folder":
                raise NotFound("no such item")
            dk, meta = self._open(row)
            size = None
            if title is not None:
                meta["title"] = _clean_text(title, 300)
            if body is not None and row["kind"] == "note":
                body = str(body)
                if len(body.encode()) > MAX_NOTE:
                    raise ValueError("That note is too long.")
                meta["body"] = body
                size = len(body.encode())
            if note is not None and row["kind"] == "link":
                meta["note"] = str(note)[:MAX_NOTE]
            parent = self._folder_parent(conn, parent_id) if parent_id is not None else None
            self._update_meta(conn, row, dk, meta, size=size, parent_id=parent)
            return self._item_json(self._row(conn, item_id), meta, body=True)

    def move(self, ids, parent_id) -> int:
        ids = [str(i) for i in (ids or [])]
        with self._lock, self._db() as conn:
            parent = self._folder_parent(conn, parent_id)
            structure = self._structure(conn)
            moved = 0
            for item_id in ids:
                if item_id not in structure:
                    continue
                if structure[item_id][1] == "folder":
                    walk, seen = parent, set()
                    while walk and walk != ROOT and walk not in seen:
                        if walk == item_id:
                            raise ValueError("A folder can't move into itself or a folder inside it.")
                        seen.add(walk)
                        walk = structure.get(walk, (None, None))[0]
                conn.execute("UPDATE items SET parent_id=?, updated=? WHERE id=?", (parent, self._now(), item_id))
                moved += 1
            return moved

    def delete(self, ids) -> int:
        ids = [str(i) for i in (ids or []) if valid_id(str(i))]
        with self._lock:
            with self._db() as conn:
                doomed: list[str] = []
                structure = self._structure(conn)
                for item_id in ids:
                    if item_id not in structure or item_id in doomed:
                        continue
                    doomed.append(item_id)
                    if structure[item_id][1] == "folder":
                        doomed.extend(d for d in self.descendants(conn, item_id) if d not in doomed)
                self._delete_rows(conn, doomed)
            self._unlink_blobs(doomed)
            return len([i for i in ids if i in doomed])

    # ── blobs ─────────────────────────────────────────────────────────────
    def blob(self, item_id: str, kind: str) -> tuple[bytes, int, Path, dict]:
        """(data key, plaintext size, file, meta) of an item's blob. NotFound when it has none."""
        with self._lock, self._db() as conn:
            row = self._row(conn, item_id)
            dk, meta = self._open(row)
        size = int((meta.get("blobs") or {}).get(kind) or 0)
        if not size and not (kind == "content" and "content" in (meta.get("blobs") or {})):
            raise NotFound("no such blob")
        return dk, size, self.blob_path(item_id, kind), meta

    def read_blob(self, item_id: str, kind: str, start: int = 0, end: int | None = None):
        dk, size, path, _ = self.blob(item_id, kind)
        return crypto.read_range(dk, item_id, kind, path, size, start, end)

    def set_blob(self, item_id: str, kind: str, raw: bytes, extra: dict | None = None) -> None:
        with self._lock, self._db() as conn:
            row = self._row(conn, item_id)
            dk, meta = self._open(row)
            crypto.write_blob(dk, item_id, kind, self.blob_path(item_id, kind), raw)
            meta.setdefault("blobs", {})[kind] = len(raw)
            meta.update(extra or {})
            self._update_meta(conn, row, dk, meta, touch=False)

    # ── link previews ─────────────────────────────────────────────────────
    def links_pending(self, max_tries: int = 3) -> list[tuple[str, str]]:
        """(id, url) of links whose preview hasn't been fetched (or failed, under ``max_tries``), and
        links an older preview engine left without a thumbnail."""
        with self._lock, self._db() as conn:
            out = []
            for row in conn.execute("SELECT * FROM items WHERE kind='link'"):
                meta = self._open(row)[1]
                tries = int(meta.get("preview_tries") or 0)
                if meta.get("preview_status") in ("pending", "failed") and tries < max_tries:
                    out.append((row["id"], meta.get("url") or ""))
                elif (int(meta.get("preview_engine") or 1) < PREVIEW_ENGINE
                      and not (meta.get("blobs") or {}).get("thumb") and tries < max_tries + 3):
                    out.append((row["id"], meta.get("url") or ""))
            return out

    def reset_preview(self, item_id: str) -> str:
        """Clear a link's preview tries so it is fetched afresh; returns its URL."""
        with self._lock, self._db() as conn:
            row = self._row(conn, item_id)
            if row["kind"] != "link":
                raise ValueError("Only links have previews.")
            dk, meta = self._open(row)
            meta["preview_tries"] = 0
            self._update_meta(conn, row, dk, meta, touch=False)
            return meta.get("url") or ""

    def mark_preview_attempt(self, item_id: str) -> bool:
        """Count a preview attempt BEFORE fetching, so a fetch that crashes the worker can't be
        retried forever. False when the item is gone."""
        with self._lock, self._db() as conn:
            try:
                row = self._row(conn, item_id)
            except NotFound:
                return False
            dk, meta = self._open(row)
            meta["preview_tries"] = int(meta.get("preview_tries") or 0) + 1
            self._update_meta(conn, row, dk, meta, touch=False)
            return True

    def save_preview(self, item_id: str, preview: dict | None, thumb: bytes | None = None,
                     favicon: tuple[bytes, str] | None = None) -> None:
        made = make_thumbnail(thumb) if thumb else None       # decoded outside the store lock
        with self._lock, self._db() as conn:
            try:
                row = self._row(conn, item_id)
            except NotFound:
                return          # deleted while the preview was being fetched
            dk, meta = self._open(row)
            if preview is None:
                # A refetch that fails keeps the preview it already had.
                if meta.get("preview_status") != "ok":
                    meta["preview_status"] = "failed"
            else:
                meta["preview"] = preview
                meta["preview_status"] = "ok"
                meta["preview_engine"] = PREVIEW_ENGINE
                blobs = meta.setdefault("blobs", {})
                if made:
                    data, (w, h), _ = made
                    crypto.write_blob(dk, item_id, "thumb", self.blob_path(item_id, "thumb"), data)
                    blobs["thumb"], meta["thumb_w"], meta["thumb_h"] = len(data), w, h
                if favicon and favicon[0]:
                    mime = safe_mime(favicon[1], "")
                    if mime.startswith("image/"):
                        crypto.write_blob(dk, item_id, "favicon", self.blob_path(item_id, "favicon"), favicon[0])
                        blobs["favicon"], meta["favicon_mime"] = len(favicon[0]), mime
            self._update_meta(conn, row, dk, meta, touch=False)

    # ── uploads ───────────────────────────────────────────────────────────
    def _upload_row(self, conn, upload_id: str, inbox: bool | None = None):
        if not valid_id(upload_id):
            raise NotFound("no such upload")
        row = conn.execute("SELECT * FROM uploads WHERE id=?", (upload_id,)).fetchone()
        if row is None or (inbox is not None and bool(row["inbox"]) != inbox):
            raise NotFound("no such upload")
        return row

    @staticmethod
    def _upload_json(row) -> dict:
        out = {"ok": True, "upload_id": row["id"], "chunk_size": row["chunk_size"],
               "received": sorted(json.loads(row["received"]))}
        if row["finished"]:
            out["finished"] = True
            out["item_id"] = row["item_id"]
        return out

    @staticmethod
    def chunk_count(size: int, chunk: int = CHUNK_SIZE) -> int:
        """Chunks an upload of ``size`` bytes has. An empty file is one empty chunk (the phone
        always PUTs chunk 0)."""
        return max(1, (size + chunk - 1) // chunk)

    @contextmanager
    def _claim(self, key):
        """One request at a time per ``key`` (a chunk, a finish), without holding the store lock."""
        with self._lock:
            if key in self._inflight:
                raise Busy("That part of the upload is already being received. Try again.")
            self._inflight.add(key)
        try:
            yield
        finally:
            with self._lock:
                self._inflight.discard(key)

    def start_upload(self, fields: dict, inbox: bool = False) -> dict:
        size = _num(fields.get("size"), int)
        if size is None or size > MAX_SIZE:
            raise ValueError("An upload needs a size of up to 2 GB.")
        kind = str(fields.get("kind") or "file")
        kind = kind if kind in FILE_KINDS else "file"
        self.purge_stale()
        with self._lock, self._db() as conn:
            if inbox:
                open_count = conn.execute("SELECT COUNT(*) FROM uploads WHERE inbox=1 AND finished=0").fetchone()[0]
                if open_count >= MAX_OPEN_INBOX_UPLOADS:
                    raise Busy("Too many shares are still uploading. Try again later.")
            parent = self._folder_parent(conn, fields.get("parent_id"), fallback_root=inbox)
            upload_id, item_id = new_id(), new_id()
            dk = crypto.new_data_key()
            meta = {"kind": kind, "parent_id": parent, "filename": _clean_text(fields.get("filename"), 300),
                    "mime": safe_mime(fields.get("mime")),
                    "title": _clean_text(fields.get("title"), 300),
                    "duration_s": _num(fields.get("duration_s")), "width": _num(fields.get("width"), int),
                    "height": _num(fields.get("height"), int), "pages": _num(fields.get("pages"), int)}
            conn.execute("INSERT INTO uploads (id,item_id,inbox,created,size,chunk_size,received,wrapped_key,meta)"
                         " VALUES (?,?,?,?,?,?,?,?,?)",
                         (upload_id, item_id, int(inbox), self._now(), size, CHUNK_SIZE, "[]",
                          crypto.wrap_key(self.master, item_id, dk), crypto.seal_meta(dk, item_id, meta)))
            # The content file exists from the start (prefix only), so chunks can land in any order.
            crypto.BlobWriter(dk, item_id, "content", self.blob_path(item_id, "content"))
            return self._upload_json(self._upload_row(conn, upload_id))

    def upload_status(self, upload_id: str, inbox: bool = False) -> dict:
        with self._lock, self._db() as conn:
            return self._upload_json(self._upload_row(conn, upload_id, inbox))

    def expected_chunk_len(self, upload_id: str, index: int, inbox: bool = False) -> int:
        """How many bytes chunk ``index`` must have; ValueError when there's no such chunk."""
        with self._lock, self._db() as conn:
            row = self._upload_row(conn, upload_id, inbox)
        total = self.chunk_count(row["size"], row["chunk_size"])
        if not 0 <= index < total:
            raise ValueError("No such chunk for this upload.")
        return min(row["chunk_size"], row["size"] - index * row["chunk_size"])

    def put_chunk(self, upload_id: str, index: int, data: bytes, inbox: bool = False) -> int:
        """Encrypt one chunk into place. Re-sending a chunk already received is a no-op. The store
        lock is not held while encrypting and syncing; the same chunk can't be in flight twice."""
        with self._claim(("chunk", upload_id, index)):
            with self._lock, self._db() as conn:
                row = self._upload_row(conn, upload_id, inbox)
                received = set(json.loads(row["received"]))
                if index in received:
                    return len(received)
                if row["finished"]:
                    raise ValueError("That upload is already finished.")
                total = self.chunk_count(row["size"], row["chunk_size"])
                want = min(row["chunk_size"], row["size"] - index * row["chunk_size"]) if 0 <= index < total else -1
                if want < 0 or len(data) != want:
                    raise ValueError("That chunk is the wrong size or out of range.")
                item_id = row["item_id"]
                dk = crypto.unwrap_key(self.master, item_id, row["wrapped_key"])
            writer = crypto.BlobWriter(dk, item_id, "content", self.blob_path(item_id, "content"))
            writer.write_span(index * (row["chunk_size"] // crypto.SEGMENT), data)
            with self._lock, self._db() as conn:
                row = self._upload_row(conn, upload_id, inbox)
                received = set(json.loads(row["received"]))
                received.add(index)
                conn.execute("UPDATE uploads SET received=? WHERE id=?", (json.dumps(sorted(received)), upload_id))
                return len(received)

    def put_upload_thumb(self, upload_id: str, raw: bytes, inbox: bool = False) -> None:
        if not raw or len(raw) > MAX_THUMB:
            raise ValueError("A thumbnail must be a JPEG of up to 2 MB.")
        dims = image_size(raw)
        with self._lock, self._db() as conn:
            row = self._upload_row(conn, upload_id, inbox)
            if row["finished"]:
                raise ValueError("That upload is already finished.")
            item_id = row["item_id"]
            dk = crypto.unwrap_key(self.master, item_id, row["wrapped_key"])
            meta = crypto.open_meta(dk, item_id, row["meta"])
            crypto.write_blob(dk, item_id, "thumb", self.blob_path(item_id, "thumb"), raw)
            meta["thumb"] = len(raw)
            meta["thumb_w"], meta["thumb_h"] = dims if dims else (None, None)
            conn.execute("UPDATE uploads SET meta=? WHERE id=?", (crypto.seal_meta(dk, item_id, meta), upload_id))

    def finish_upload(self, upload_id: str, inbox: bool = False) -> dict:
        """Make the upload an item. Finishing again (a retry after a lost reply) returns the same item
        for as long as the upload is remembered (STALE_UPLOAD_S)."""
        with self._claim(("finish", upload_id)):
            with self._lock, self._db() as conn:
                row = self._upload_row(conn, upload_id, inbox)
                item_id = row["item_id"]
                if row["finished"]:
                    return self._item_json(self._row(conn, item_id), self._open(self._row(conn, item_id))[1])
                received = set(json.loads(row["received"]))
                total = self.chunk_count(row["size"], row["chunk_size"])
                missing = [i for i in range(total) if i not in received]
                if missing:
                    raise ValueError(f"The upload is missing {len(missing)} chunk(s).")
                dk = crypto.unwrap_key(self.master, item_id, row["wrapped_key"])
                up = crypto.open_meta(dk, item_id, row["meta"])
                size = row["size"]
            kind = up.pop("kind", "file")
            meta = {k: v for k, v in up.items() if k not in ("thumb", "parent_id")}
            blobs = {"content": size}
            if up.get("thumb"):
                blobs["thumb"] = up["thumb"]
            meta["blobs"] = blobs
            if kind == "image" and "thumb" not in blobs and 0 < size <= THUMB_FROM_CONTENT_MAX:
                # Decrypted into memory only, outside the store lock.
                plain = crypto.read_blob(dk, item_id, "content", self.blob_path(item_id, "content"), size)
                made = make_thumbnail(plain)
                del plain
                if made:
                    data, (w, h), (fw, fh) = made
                    crypto.write_blob(dk, item_id, "thumb", self.blob_path(item_id, "thumb"), data)
                    blobs["thumb"], meta["thumb_w"], meta["thumb_h"] = len(data), w, h
                    meta["width"] = meta.get("width") or fw
                    meta["height"] = meta.get("height") or fh
            with self._lock, self._db() as conn:
                parent = self._folder_parent(conn, up.get("parent_id", ROOT), fallback_root=True)
                self._insert(conn, item_id, parent, kind, meta, dk=dk, size=size)
                conn.execute("UPDATE uploads SET finished=1 WHERE id=?", (upload_id,))
                return self._item_json(self._row(conn, item_id), meta)

    def abort_upload(self, upload_id: str) -> None:
        """Drop an unfinished upload and its partial blobs."""
        with self._lock:
            with self._db() as conn:
                row = conn.execute("SELECT item_id, finished FROM uploads WHERE id=?", (upload_id,)).fetchone()
                if row is None:
                    return
                conn.execute("DELETE FROM uploads WHERE id=?", (upload_id,))
            if not row["finished"]:
                self._unlink_blobs([row["item_id"]])

    def purge_stale(self) -> int:
        """Forget uploads older than STALE_UPLOAD_S; an unfinished one's partial blobs go too."""
        cutoff = self._now() - STALE_UPLOAD_S
        with self._lock:
            with self._db() as conn:
                rows = conn.execute("SELECT id,item_id,finished FROM uploads WHERE created < ?", (cutoff,)).fetchall()
                for row in rows:
                    conn.execute("DELETE FROM uploads WHERE id=?", (row["id"],))
            self._unlink_blobs([r["item_id"] for r in rows if not r["finished"]])
            return len(rows)
