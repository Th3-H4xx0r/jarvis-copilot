"""PC Stats: the games the PC has seen — each exe's friendly name ("Call of Duty") and its Windows icon
(a PNG the PC extracts from the exe once), shown beside "Playing …" on the phone, web and PC.
Stored as one small JSON file under the pc_stats folder.
"""
from __future__ import annotations

import base64
import binascii
import json
import re
import threading
import time
from pathlib import Path
from typing import Optional

MAX_ICON_BYTES = 300_000
MAX_GAMES = 200
_EXE = re.compile(r"^[\w .()+\-]{1,80}\.exe$", re.IGNORECASE)
_PNG = b"\x89PNG\r\n\x1a\n"
_lock = threading.Lock()


def _path() -> Path:
    from api.pc_stats_store import store
    return Path(store().root) / "games.json"


def _read() -> dict:
    try:
        return json.loads(_path().read_text())
    except (OSError, ValueError):
        return {}


def put(exe: str, name: str, icon_b64: Optional[str]) -> list[str]:
    """Saves a game (errors list; empty = saved). The icon is optional; an existing one is kept."""
    errors = []
    if not isinstance(exe, str) or not _EXE.match(exe):
        errors.append("exe must be a file name ending in .exe")
    name = (name or "").strip() if isinstance(name, str) else ""
    if len(name) > 80:
        errors.append("name is too long")
    icon = None
    if icon_b64:
        try:
            raw = base64.b64decode(icon_b64, validate=True)
        except (binascii.Error, ValueError, TypeError):
            raw = b""
        if not raw.startswith(_PNG):
            errors.append("icon must be a PNG")
        elif len(raw) > MAX_ICON_BYTES:
            errors.append("icon is too big")
        else:
            icon = base64.b64encode(raw).decode()
    if errors:
        return errors
    with _lock:
        games = _read()
        key = exe.lower()
        g = games.get(key, {})
        g["name"] = name or g.get("name") or ""
        if icon:
            g["icon"] = icon
        g["at"] = time.time()
        games[key] = g
        if len(games) > MAX_GAMES:   # forget the longest-unseen
            for k in sorted(games, key=lambda k: games[k].get("at", 0))[: len(games) - MAX_GAMES]:
                games.pop(k, None)
        p = _path()
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_suffix(".tmp")
        tmp.write_text(json.dumps(games))
        tmp.replace(p)
    return []


def name_of(exe: Optional[str]) -> str:
    """"cod.exe" → its saved name, else the exe without ".exe"."""
    if not exe:
        return ""
    g = _read().get(exe.lower()) or {}
    return g.get("name") or re.sub(r"\.exe$", "", exe, flags=re.IGNORECASE)


def all_games() -> dict:
    """{exe: {"name", "icon": "data:image/png;base64,…" or None}}."""
    return {k: {"name": v.get("name") or re.sub(r"\.exe$", "", k), "icon": f"data:image/png;base64,{v['icon']}" if v.get("icon") else None}
            for k, v in _read().items()}


def has_icon(exe: str) -> bool:
    return bool((_read().get((exe or "").lower()) or {}).get("icon"))
