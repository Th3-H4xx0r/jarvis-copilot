"""Per-chat images: where a chat's pictures live and how they get there.

Every image a reply shows is kept in ``<HERMES_HOME>/webui/media/<chat>/`` so it
never breaks later (a site changes, a cache is pruned). Three writers share this
module: the ``chat_image`` tool (a checked web image), the device-image path
(a Mac screenshot, an iPhone photo) and the finished-reply backstop
(``localize_text``), which pulls in any web image or stray file a reply names
without having gone through the tool.

A saved file is named ``<slug>-<6 hex>_<W>x<H>.<ext>``: the clients read the
size off the name to reserve the right space before the bytes arrive.
"""
from __future__ import annotations

import hashlib
import io
import json
import logging
import re
import shutil
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from jarviscopilot_constants import get_hermes_home

logger = logging.getLogger(__name__)

MAX_BYTES = 15 * 1024 * 1024
MIN_SIDE = 200
MAX_SIDE = 2560
_KEEP_FORMATS = {"PNG": ("png", "image/png"), "JPEG": ("jpg", "image/jpeg"),
                 "WEBP": ("webp", "image/webp"), "GIF": ("gif", "image/gif")}
_UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
       "(KHTML, like Gecko) Chrome/130.0 Safari/537.36")

# `MEDIA:<ref>` and `![alt](<ref>)` — the two ways a reply shows an image.
_MEDIA_RE = re.compile(r"MEDIA:([^\s)\]]+)")
_MD_IMG_RE = re.compile(r"!\[([^\]]*)\]\(([^)\s]+)\)")
_FENCE_RE = re.compile(r"^\s*(```|~~~)")

_index_lock = threading.Lock()


class ImageRejected(ValueError):
    """Not an image this chat will show. The message says why, in plain words."""


@dataclass
class SavedImage:
    path: Path
    width: int
    height: int
    mime: str


def root_session(session_id: str) -> str:
    """A background worker ``<chat>~<node>`` saves into its chat's folder."""
    return str(session_id or "").split("~", 1)[0]


def media_root() -> Path:
    return get_hermes_home() / "webui" / "media"


def media_dir(session_id: str) -> Path:
    sid = root_session(session_id)
    if not sid or "/" in sid or sid in (".", ".."):
        raise ValueError(f"bad session id: {session_id!r}")
    return media_root() / sid


def _slug(text: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", str(text or "").lower()).strip("-")
    return s[:40].strip("-") or "image"


def _decode(data: bytes):
    """Open and verify ``data`` as a raster image, or raise ImageRejected."""
    from PIL import Image, ImageOps, UnidentifiedImageError

    if not data:
        raise ImageRejected("empty file")
    if len(data) > MAX_BYTES:
        raise ImageRejected("image is larger than 15 MB")
    head = data[:512].lstrip().lower()
    if head.startswith(b"<svg") or b"<svg" in head[:256] or head.startswith(b"<?xml"):
        raise ImageRejected("SVG images aren't shown in the chat")
    try:
        with Image.open(io.BytesIO(data)) as probe:
            probe.verify()
        im = Image.open(io.BytesIO(data))
        fmt = (im.format or "").upper()
        im.load()
    except UnidentifiedImageError:
        raise ImageRejected("not an image (or a format that can't be read, like HEIC)") from None
    except Exception as exc:
        raise ImageRejected(f"image could not be read: {exc}") from None
    if fmt != "GIF":
        im = ImageOps.exif_transpose(im)
    return im, fmt


def save_image_bytes(data: bytes, session_id: str, *, name_hint: str = "image",
                     caption: str = "", source: str = "", check: str = "",
                     worker_session: str = "") -> SavedImage:
    """Validate, normalise and store one image in the chat's folder."""
    from PIL import Image

    im, fmt = _decode(data)
    w, h = im.size
    if min(w, h) < MIN_SIDE:
        raise ImageRejected(f"image is too small ({w}×{h}); likely an icon or tracking pixel")

    resized = max(w, h) > MAX_SIDE
    if resized:
        scale = MAX_SIDE / max(w, h)
        w, h = max(1, round(w * scale)), max(1, round(h * scale))
        im = im.resize((w, h), Image.LANCZOS)

    if fmt in _KEEP_FORMATS and not (resized and fmt == "GIF"):
        ext, mime = _KEEP_FORMATS[fmt]
    else:
        ext, mime = "jpg", "image/jpeg"     # BMP/TIFF/AVIF, or a resized GIF

    if not resized and fmt in _KEEP_FORMATS:
        out = data
    else:
        buf = io.BytesIO()
        if ext == "jpg":
            im.convert("RGB").save(buf, format="JPEG", quality=88, optimize=True)
        else:
            im.save(buf, format={"png": "PNG", "webp": "WEBP"}[ext])
        out = buf.getvalue()

    folder = media_dir(session_id)
    folder.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256(out).hexdigest()[:6]
    path = folder / f"{_slug(name_hint)}-{digest}_{w}x{h}.{ext}"
    if not path.exists():
        tmp = path.with_suffix(path.suffix + ".part")
        tmp.write_bytes(out)
        tmp.replace(path)
    row = {"file": path.name, "caption": str(caption or ""), "source": str(source or ""),
           "check": str(check or ""), "w": w, "h": h,
           "session": str(worker_session or session_id or ""), "ts": time.time()}
    with _index_lock:
        with (folder / "index.jsonl").open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(row) + "\n")
    return SavedImage(path=path, width=w, height=h, mime=mime)


def fetch_image(url: str, timeout: float = 8.0) -> bytes:
    """Download one web image (public addresses only), at most 15 MB."""
    import httpx
    from tools.vision_tools import _validate_image_url

    if not _validate_image_url(url):
        raise ImageRejected("not a public http(s) image address")
    try:
        with httpx.stream("GET", url, follow_redirects=True, timeout=timeout,
                          headers={"User-Agent": _UA, "Accept": "image/*,*/*;q=0.5"}) as resp:
            if resp.status_code >= 400:
                raise ImageRejected(f"the site answered {resp.status_code}")
            chunks, total = [], 0
            for chunk in resp.iter_bytes():
                total += len(chunk)
                if total > MAX_BYTES:
                    raise ImageRejected("image is larger than 15 MB")
                chunks.append(chunk)
    except ImageRejected:
        raise
    except Exception as exc:
        raise ImageRejected(f"download failed: {exc.__class__.__name__}") from None
    return b"".join(chunks)


def images_since(session_id: str, worker_session: str, since: float) -> list[dict]:
    """Index rows a background worker saved since ``since``, oldest first,
    each with its absolute ``path``."""
    try:
        folder = media_dir(session_id)
        lines = (folder / "index.jsonl").read_text(encoding="utf-8").splitlines()
    except (OSError, ValueError):
        return []
    rows = []
    for line in lines:
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if row.get("session") == worker_session and float(row.get("ts") or 0) >= since:
            row["path"] = str(folder / row.get("file", ""))
            rows.append(row)
    return rows


def delete_media(session_id: str) -> None:
    try:
        shutil.rmtree(media_dir(session_id), ignore_errors=True)
    except ValueError:
        pass


# ── the finished-reply backstop ─────────────────────────────────────────────

def _refs_outside_code(text: str) -> list[str]:
    refs, in_code = [], False
    for line in text.split("\n"):
        if _FENCE_RE.match(line):
            in_code = not in_code
            continue
        if in_code:
            continue
        refs += [m.group(1) for m in _MEDIA_RE.finditer(line)]
        refs += [m.group(2) for m in _MD_IMG_RE.finditer(line)]
    return refs


def _wants_localizing(ref: str, folder: Path) -> bool:
    low = ref.lower()
    if low.startswith(("http://", "https://")):
        return True
    if not ref.startswith("/") or ref.startswith("/api/"):
        return False
    try:
        p = Path(ref).resolve()
        inside = p.is_relative_to(folder.resolve())
    except OSError:
        return False
    return not inside and p.is_file()


def localize_text(text: str, session_id: str, *, fetch: Callable[..., bytes] | None = None,
                  max_images: int = 8) -> str:
    """Save every web image / stray file a reply shows into the chat's folder
    and point the reply at the saved copy. Refs inside code fences, refs already
    in the folder, and refs that fail stay as written."""
    if not text or ("MEDIA:" not in text and "](" not in text):
        return text
    try:
        folder = media_dir(session_id)
    except ValueError:
        return text
    wanted = []
    for ref in _refs_outside_code(text):
        if ref not in wanted and _wants_localizing(ref, folder):
            wanted.append(ref)
    wanted = wanted[:max_images]
    if not wanted:
        return text
    fetch = fetch or fetch_image

    def _one(ref: str) -> tuple[str, str | None]:
        try:
            if ref.lower().startswith(("http://", "https://")):
                data = fetch(ref)
                hint = ref.split("?", 1)[0].rstrip("/").rsplit("/", 1)[-1].rsplit(".", 1)[0]
            else:
                data = Path(ref).read_bytes()
                hint = Path(ref).stem
            saved = save_image_bytes(data, session_id, name_hint=hint, source=ref)
            return ref, str(saved.path)
        except Exception as exc:
            logger.info("chat image backstop skipped %s: %s", ref[:120], exc)
            return ref, None

    with ThreadPoolExecutor(max_workers=4) as pool:
        mapping = {ref: new for ref, new in pool.map(_one, wanted) if new}
    if not mapping:
        return text

    out, in_code = [], False
    for line in text.split("\n"):
        if _FENCE_RE.match(line):
            in_code = not in_code
            out.append(line)
            continue
        if not in_code:
            line = _MEDIA_RE.sub(lambda m: "MEDIA:" + mapping.get(m.group(1), m.group(1)), line)
            line = _MD_IMG_RE.sub(
                lambda m: f"![{m.group(1)}]({mapping.get(m.group(2), m.group(2))})", line)
        out.append(line)
    return "\n".join(out)
