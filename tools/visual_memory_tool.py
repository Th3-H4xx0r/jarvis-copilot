"""Visual memories — reference photos Jarvis can actually SEE again.

Text memory can hold "Anjali is Pranav's sister", but that never helps with
"who is in this photo": the model has no visual reference to compare against.
A visual memory stores one or more reference images per person (or pet, or
place) and hands them BACK as image content, so the model compares faces
itself rather than guessing.

Storage (profile-scoped, next to the text memories):

    <hermes home>/memories/visual/index.json      {slug: {name, description, images[], added}}
    <hermes home>/memories/visual/images/<file>   normalized reference images

`recall` returns a ``_multimodal`` envelope (the same shape the vision tool
uses), so the pixels reach the model on its next turn.
"""
from __future__ import annotations

import base64
import json
import re
import shutil
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

from tools.registry import registry, tool_error

# Enough angles to recognise someone, few enough to keep a recall affordable.
MAX_IMAGES_PER_PERSON = 5
# A recall that matched half the address book would blow the context budget.
MAX_PEOPLE_PER_RECALL = 6
_EXT = {"image/jpeg": ".jpg", "image/jpg": ".jpg", "image/png": ".png",
        "image/heic": ".heic", "image/webp": ".webp", "image/gif": ".gif"}


def _visual_dir() -> Path:
    from jarviscopilot_constants import get_hermes_home
    return get_hermes_home() / "memories" / "visual"


def _index_path() -> Path:
    return _visual_dir() / "index.json"


def _images_dir() -> Path:
    return _visual_dir() / "images"


def _load() -> Dict[str, Any]:
    try:
        return json.loads(_index_path().read_text(encoding="utf-8"))
    except Exception:
        return {}


def _save(index: Dict[str, Any]) -> None:
    _visual_dir().mkdir(parents=True, exist_ok=True)
    _index_path().write_text(json.dumps(index, indent=2, ensure_ascii=False), encoding="utf-8")


def _slug(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", str(name or "").strip().lower()).strip("-")


def _data_url(path: Path) -> Optional[str]:
    try:
        raw = path.read_bytes()
    except Exception:
        return None
    mime = next((m for m, e in _EXT.items() if path.suffix.lower() == e), "image/jpeg")
    return f"data:{mime};base64,{base64.b64encode(raw).decode()}"


# ── actions ────────────────────────────────────────────────────────────────

def _save_person(name: str, description: str, image_path: str,
                 image_base64: str, mime: str) -> str:
    name = str(name or "").strip()
    if not name:
        return tool_error("name is required — who or what is this a picture of?", success=False)

    _images_dir().mkdir(parents=True, exist_ok=True)
    slug = _slug(name)
    stamp = int(time.time() * 1000)
    if image_base64:
        ext = _EXT.get(str(mime or "").lower(), ".jpg")
        dest = _images_dir() / f"{slug}-{stamp}{ext}"
        try:
            dest.write_bytes(base64.b64decode(image_base64, validate=False))
        except Exception as exc:
            return tool_error(f"could not decode image_base64: {exc}", success=False)
    else:
        src = Path(str(image_path or "")).expanduser()
        if not src.is_file():
            return tool_error(f"no readable image at {image_path!r}", success=False)
        dest = _images_dir() / f"{slug}-{stamp}{src.suffix.lower() or '.jpg'}"
        try:
            shutil.copyfile(src, dest)
        except Exception as exc:
            return tool_error(f"could not store the image: {exc}", success=False)

    index = _load()
    entry = index.get(slug) or {"name": name, "description": "", "images": [], "added": time.time()}
    entry["name"] = name
    if description:
        entry["description"] = str(description).strip()
    entry["images"] = list(entry.get("images") or []) + [dest.name]
    # Oldest reference photos fall off, and their files go with them.
    while len(entry["images"]) > MAX_IMAGES_PER_PERSON:
        stale = entry["images"].pop(0)
        try:
            (_images_dir() / stale).unlink(missing_ok=True)
        except Exception:
            pass
    index[slug] = entry
    _save(index)
    return json.dumps({"ok": True, "name": name, "images": len(entry["images"]),
                       "note": f"Reference photo saved. Call visual_memory recall to see {name} again."})


def _recall(query: str) -> Any:
    index = _load()
    q = str(query or "").strip().lower()
    if q:
        matches = [e for e in index.values()
                   if q in str(e.get("name", "")).lower()
                   or q in str(e.get("description", "")).lower()
                   or any(w in str(e.get("name", "")).lower() for w in q.split())]
    else:
        matches = list(index.values())
    matches = matches[:MAX_PEOPLE_PER_RECALL]
    if not matches:
        return json.dumps({"ok": True, "results": [],
                           "note": "No visual memories match. Save one with visual_memory save."})

    content: List[Dict[str, Any]] = [{
        "type": "text",
        "text": ("Reference photos from your visual memory. Compare them with the image in "
                 "context to identify who is who; say so plainly if none of them match."),
    }]
    listed = []
    for entry in matches:
        label = entry.get("name", "?")
        desc = entry.get("description") or ""
        content.append({"type": "text",
                        "text": f"{label}" + (f" — {desc}" if desc else "")})
        shown = 0
        for filename in list(entry.get("images") or [])[-2:]:   # the two newest angles
            url = _data_url(_images_dir() / filename)
            if url:
                content.append({"type": "image_url", "image_url": {"url": url}})
                shown += 1
        listed.append({"name": label, "description": desc, "images": shown})

    return {
        "_multimodal": True,
        "content": content,
        "text_summary": "Visual memories: " + ", ".join(p["name"] for p in listed),
        "meta": {"results": listed},
    }


def _list() -> str:
    index = _load()
    return json.dumps({"ok": True, "people": [
        {"name": e.get("name"), "description": e.get("description") or "",
         "images": len(e.get("images") or [])}
        for e in index.values()
    ]})


def _forget(name: str) -> str:
    index = _load()
    slug = _slug(name)
    entry = index.pop(slug, None)
    if entry is None:
        return json.dumps({"ok": False, "error": f"no visual memory for {name!r}"})
    for filename in entry.get("images") or []:
        try:
            (_images_dir() / filename).unlink(missing_ok=True)
        except Exception:
            pass
    _save(index)
    return json.dumps({"ok": True, "forgotten": entry.get("name")})


def visual_memory(action: str, name: str = "", description: str = "",
                  image_path: str = "", image_base64: str = "", mime: str = "",
                  query: str = "") -> Any:
    act = str(action or "").strip().lower()
    if act == "save":
        return _save_person(name, description, image_path, image_base64, mime)
    if act == "recall":
        return _recall(query or name)
    if act == "list":
        return _list()
    if act == "forget":
        return _forget(name)
    return tool_error(f"unknown action {action!r}. Use: save, recall, list, forget", success=False)


VISUAL_MEMORY_SCHEMA = {
    "name": "visual_memory",
    "description": (
        "Remember what people (or pets, places, objects) LOOK like, and see them again. "
        "`save` stores a reference photo under a name — use it when the user says "
        "'this is my sister Anjali' or after they share a photo of someone. "
        "`recall` returns the stored reference photos as images you can actually look at, "
        "so you can name who is in a new photo; call it BEFORE saying you cannot identify "
        "someone. `list` names everyone you have a reference for; `forget` removes one."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "action": {"type": "string", "enum": ["save", "recall", "list", "forget"]},
            "name": {"type": "string", "description": "Who/what the photo is of (save, forget)."},
            "description": {"type": "string",
                            "description": "Who they are to the user, e.g. \"Pranav's sister\"."},
            "image_path": {"type": "string",
                           "description": "Local path to the photo (e.g. image_path from a device photo skill)."},
            "image_base64": {"type": "string", "description": "The photo inline, instead of a path."},
            "mime": {"type": "string", "description": "MIME type for image_base64, e.g. image/jpeg."},
            "query": {"type": "string",
                      "description": "Who to recall. Omit to get every reference you have."},
        },
        "required": ["action"],
    },
}


def check_visual_memory_requirements() -> bool:
    return True


registry.register(
    name="visual_memory",
    toolset="memory",
    schema=VISUAL_MEMORY_SCHEMA,
    handler=lambda args, **kw: visual_memory(
        action=args.get("action", ""),
        name=args.get("name", ""),
        description=args.get("description", ""),
        image_path=args.get("image_path", ""),
        image_base64=args.get("image_base64", ""),
        mime=args.get("mime", ""),
        query=args.get("query", "")),
    check_fn=check_visual_memory_requirements,
    emoji="🖼️",
)
