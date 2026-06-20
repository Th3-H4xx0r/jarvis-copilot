"""Per-profile storage for Dynamic Island designs.

A small JSON-file store under the webui state dir. Layout (per profile)::

    <state>/island/<profile>/
        designs/<id>.json     full layout-tree (custom designs only)
        catalog.json          {id: metadata+rules} for every touched entry
        selection.json        {mode, pinnedId}
        data/<id>.json        latest pushed jarvis.* values per design

The two NATIVE modes (voice, coding) appear as built-in catalog entries with no
design file — they're rendered by hand-built Swift, not the generic renderer, so
the store only tracks their selection/auto rules. Built-ins can't be deleted.

Mirrors the file-backed style of other webui sidecars (devices, location). All
writes are atomic (temp + os.replace). Never raises on a missing/corrupt file —
returns sane defaults instead.
"""
from __future__ import annotations

import json
import os
import threading
import time
from pathlib import Path

from api import island_schema

# Serializes catalog read-modify-write across the threaded HTTP server so two
# concurrent writers (skill + app + browser) can't clobber each other's rules.
_LOCK = threading.RLock()

# Native modes surfaced as non-deletable catalog entries. Priority orders the
# Auto picker (higher wins); voice outranks coding which outranks customs.
BUILTINS = [
    {"id": "voice", "name": "Voice", "icon": "waveform", "priority": 100},
    {"id": "coding", "name": "Coding",
     "icon": "chevron.left.forwardslash.chevron.right", "priority": 50},
]
_BUILTIN_IDS = {b["id"] for b in BUILTINS}
_DEFAULT_CUSTOM_PRIORITY = 10

# A built-in, non-deletable DEMO design: a rich, tall layout that fills the
# expanded island so the user can see how large a custom design can get. It's a
# real design tree (rendered by the generic widget), all-literal (no bindings),
# disabled in the Auto rotation (you pin it to view it).
DEMO_ID = "demo"
DEMO_DESIGN = {
    "schema": 1, "id": DEMO_ID, "version": 4,
    "name": "UI Example (max size)",
    "icon": "rectangle.on.rectangle.angled", "tint": "#0a84ff",
    "presentations": {
        # The expanded island is CAPPED at ~144pt by iOS — you fill that cap, you
        # can't exceed it. The trick is balance (like Spotify/Apple Music): a
        # moderate album-art-style `leading` + a `bottom` of progress + controls
        # that together reach the cap WITHOUT overstuffing (overstuffing clips the
        # lower rows). `bottom.style.minHeight` nudges it to fill the cap.
        "expanded": {"type": "regions",
            "leading": {"type": "image", "source": "orb",
                        "style": {"width": 52, "height": 52}},
            "center": {"type": "vstack", "spacing": 2, "children": [
                {"type": "text", "value": "Dynamic Island Demo",
                 "style": {"size": 16, "weight": "bold"}},
                {"type": "text", "value": "Max-size UI example",
                 "style": {"size": 13, "color": "#8e8e93"}},
            ]},
            "trailing": {"type": "symbol", "name": "waveform",
                         "style": {"size": 22, "tint": "#0a84ff"}},
            "bottom": {"type": "vstack", "spacing": 14, "style": {"minHeight": 86},
                       "children": [
                {"type": "progress", "value": 0.7, "tint": "#0a84ff"},
                {"type": "hstack", "spacing": 40, "align": "center", "children": [
                    {"type": "spacer"},
                    {"type": "symbol", "name": "backward.fill", "style": {"size": 26}},
                    {"type": "symbol", "name": "pause.fill", "style": {"size": 34}},
                    {"type": "symbol", "name": "forward.fill", "style": {"size": 26}},
                    {"type": "spacer"},
                ]},
            ]},
        },
        "compactLeading": {"type": "symbol", "name": "rectangle.on.rectangle.angled"},
        "compactTrailing": {"type": "text", "value": "DEMO"},
        "minimal": {"type": "symbol", "name": "rectangle.on.rectangle.angled"},
    },
}


def _default_meta(entry_id: str, *, builtin: bool, name: str = "",
                  icon: str = "", priority: int | None = None,
                  version: int = 1) -> dict:
    return {
        "id": entry_id,
        "name": name or entry_id,
        "icon": icon,
        "version": version,
        "builtin": builtin,
        "enabled": True,
        "priority": (priority if priority is not None
                     else (_DEFAULT_CUSTOM_PRIORITY if not builtin else 0)),
        "conditions": None,
        "schedule": None,
        "updated_at": 0.0,
    }


class IslandStore:
    def __init__(self, root, profile: str = "default"):
        self.base = Path(root) / "island" / (profile or "default")

    # ── paths ────────────────────────────────────────────────────────────────
    @property
    def _designs_dir(self) -> Path:
        return self.base / "designs"

    @property
    def _data_dir(self) -> Path:
        return self.base / "data"

    @property
    def _catalog_path(self) -> Path:
        return self.base / "catalog.json"

    @property
    def _selection_path(self) -> Path:
        return self.base / "selection.json"

    def _design_path(self, design_id: str) -> Path:
        return self._designs_dir / f"{_safe_id(design_id)}.json"

    # ── designs ────────────────────────────────────────────────────────────────
    def list_design_ids(self) -> list[str]:
        d = self._designs_dir
        if not d.is_dir():
            return []
        return sorted(p.stem for p in d.glob("*.json"))

    def get_design(self, design_id: str) -> dict | None:
        if design_id == DEMO_ID:
            return dict(DEMO_DESIGN)
        return _read_json(self._design_path(design_id), None)

    def list_designs(self) -> list[dict]:
        out = [dict(DEMO_DESIGN)]  # built-in demo first (a real, renderable tree)
        for did in self.list_design_ids():
            doc = self.get_design(did)
            if doc:
                out.append(doc)
        return out

    def upsert_design(self, design) -> tuple[bool, list[str]]:
        """Validate then store a custom design. Returns (ok, errors)."""
        errors = island_schema.validate_design(design)
        if errors:
            return False, errors
        did = design["id"]
        if did in _BUILTIN_IDS or did == DEMO_ID:
            return False, [f"'{did}' is a reserved built-in id"]
        self._designs_dir.mkdir(parents=True, exist_ok=True)
        _write_json(self._design_path(did), design)
        # Create/refresh the catalog metadata, preserving any existing rules.
        with _LOCK:
            cat = self._read_catalog()
            meta = cat.get(did) or _default_meta(
                did, builtin=False, name=design.get("name", did),
                icon=design.get("icon", ""))
            meta["name"] = design.get("name", meta.get("name", did))
            meta["icon"] = design.get("icon", meta.get("icon", ""))
            meta["version"] = int(design.get("version", meta.get("version", 1)))
            meta["builtin"] = False
            meta["updated_at"] = time.time()
            cat[did] = meta
            self._write_catalog(cat)
        return True, []

    def delete_design(self, design_id: str) -> bool:
        if design_id in _BUILTIN_IDS or design_id == DEMO_ID:
            return False
        removed = False
        p = self._design_path(design_id)
        if p.exists():
            p.unlink()
            removed = True
        dp = self._data_dir / f"{_safe_id(design_id)}.json"
        if dp.exists():
            dp.unlink()
        with _LOCK:
            cat = self._read_catalog()
            if cat.pop(design_id, None) is not None:
                self._write_catalog(cat)
                removed = True
        # If the deleted design was pinned, fall back to Auto.
        sel = self.get_selection()
        if sel.get("mode") == "pinned" and sel.get("pinnedId") == design_id:
            self.set_selection("auto", None)
        return removed

    # ── catalog (metadata + rules), incl. virtual built-ins ──────────────────
    def get_catalog(self) -> list[dict]:
        stored = self._read_catalog()
        out: list[dict] = []
        # Built-ins first, with any stored rule overrides applied.
        for b in BUILTINS:
            meta = _default_meta(b["id"], builtin=True, name=b["name"],
                                 icon=b["icon"], priority=b["priority"])
            meta.update({k: v for k, v in stored.get(b["id"], {}).items()
                         if k in ("enabled", "priority", "conditions",
                                  "schedule")})
            out.append(meta)
        # Built-in DEMO design (a real, renderable tree) — non-deletable, OFF in
        # the Auto rotation by default; the user pins it to view the max-size UI.
        demo_meta = _default_meta(DEMO_ID, builtin=True, name=DEMO_DESIGN["name"],
                                  icon=DEMO_DESIGN["icon"], priority=1)
        demo_meta["enabled"] = False
        demo_meta.update({k: v for k, v in stored.get(DEMO_ID, {}).items()
                          if k in ("enabled", "priority", "conditions", "schedule")})
        out.append(demo_meta)
        # Custom designs: ensure every design file has a catalog row.
        for did in self.list_design_ids():
            meta = stored.get(did)
            if not meta:
                doc = self.get_design(did) or {}
                meta = _default_meta(did, builtin=False,
                                     name=doc.get("name", did),
                                     icon=doc.get("icon", ""),
                                     version=int(doc.get("version", 1)))
            meta["builtin"] = False
            out.append(meta)
        return out

    def set_rules(self, entry_id: str, *, enabled=None, priority=None,
                  conditions=..., schedule=...) -> tuple[bool, list[str]]:
        if (entry_id not in _BUILTIN_IDS and entry_id != DEMO_ID
                and entry_id not in self.list_design_ids()):
            return False, [f"unknown entry {entry_id!r}"]
        if conditions not in (..., None):
            errs = island_schema.validate_condition(conditions)
            if errs:
                return False, errs
        if priority is not None:
            try:
                priority = int(priority)
            except (TypeError, ValueError):
                return False, ["priority must be an integer"]
        with _LOCK:
            cat = self._read_catalog()
            meta = cat.get(entry_id) or _default_meta(
                entry_id, builtin=entry_id in _BUILTIN_IDS)
            if enabled is not None:
                meta["enabled"] = bool(enabled)
            if priority is not None:
                meta["priority"] = priority
            if conditions is not ...:
                meta["conditions"] = conditions
            if schedule is not ...:
                meta["schedule"] = schedule
            meta["updated_at"] = time.time()
            cat[entry_id] = meta
            self._write_catalog(cat)
        return True, []

    # ── selection ────────────────────────────────────────────────────────────
    def get_selection(self) -> dict:
        sel = _read_json(self._selection_path, None)
        if not isinstance(sel, dict) or sel.get("mode") not in ("auto", "pinned"):
            return {"mode": "auto", "pinnedId": None}
        return {"mode": sel.get("mode", "auto"),
                "pinnedId": sel.get("pinnedId")}

    def set_selection(self, mode: str, pinned_id: str | None) -> tuple[bool, list[str]]:
        if mode not in ("auto", "pinned"):
            return False, ["mode must be 'auto' or 'pinned'"]
        if mode == "pinned":
            if not pinned_id:
                return False, ["pinned mode requires pinnedId"]
            if (pinned_id not in _BUILTIN_IDS
                    and pinned_id != DEMO_ID
                    and pinned_id not in self.list_design_ids()):
                return False, [f"unknown design {pinned_id!r}"]
        self.base.mkdir(parents=True, exist_ok=True)
        _write_json(self._selection_path,
                    {"mode": mode,
                     "pinnedId": pinned_id if mode == "pinned" else None,
                     "updated_at": time.time()})
        return True, []

    # ── live data (jarvis.* values per design) ───────────────────────────────
    def get_data(self, design_id: str) -> dict:
        return _read_json(self._data_dir / f"{_safe_id(design_id)}.json", {}) or {}

    def set_data(self, design_id: str, data: dict, *, merge: bool = True) -> dict:
        self._data_dir.mkdir(parents=True, exist_ok=True)
        cur = self.get_data(design_id) if merge else {}
        if isinstance(data, dict):
            cur.update(data)
        _write_json(self._data_dir / f"{_safe_id(design_id)}.json", cur)
        return cur

    # ── catalog file helpers ─────────────────────────────────────────────────
    def _read_catalog(self) -> dict:
        cat = _read_json(self._catalog_path, {})
        return cat if isinstance(cat, dict) else {}

    def _write_catalog(self, cat: dict) -> None:
        self.base.mkdir(parents=True, exist_ok=True)
        _write_json(self._catalog_path, cat)

    # ── aggregate view for the GET /designs endpoint ─────────────────────────
    def snapshot(self) -> dict:
        ids = self.list_design_ids()
        return {
            "designs": self.list_designs(),
            "catalog": self.get_catalog(),
            "selection": self.get_selection(),
            # Per-design server-resolved values (jarvis.* etc.) so the awake
            # client can push them too; only non-empty entries are included.
            "data": {did: d for did in ids if (d := self.get_data(did))},
        }


# ── module helpers ───────────────────────────────────────────────────────────

def _safe_id(s: str) -> str:
    # designs are validated to a slug, but defend the path anyway.
    return "".join(c for c in str(s) if c.isalnum() or c in "-_")[:64] or "_"


def _read_json(path: Path, default):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return default


def _write_json(path: Path, obj) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)


def store_for_request() -> IslandStore:
    """Build a store rooted at the webui state dir for the active profile."""
    root = os.environ.get("HERMES_WEBUI_STATE_DIR")
    if not root:
        root = str(Path.home() / ".jarviscopilot" / "webui")
    try:
        from api.profiles import get_active_profile_name
        profile = get_active_profile_name()
    except Exception:
        profile = "default"
    return IslandStore(root, profile)
