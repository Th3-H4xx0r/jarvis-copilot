"""Per-profile storage for Home Screen / Lock Screen widget designs.

A small JSON-file store under the webui state dir, beside the island store::

    <state>/widgets/<profile>/
        designs/<id>.json     one widget design (see widget_schema)
        catalog.json          {"catalog": [{key, label, area, kind, unit?}], "updated_at"}

The catalog is the list of data keys the phone publishes to its widgets; the
phone posts it on sync, and the validator warns about keys it doesn't list.
Every design write bumps ``version`` (previous + 1, or 1) so the phone can tell
a fresh copy from its cache. Writes are atomic (temp + os.replace); a missing or
corrupt file reads as empty, never raises.
"""
from __future__ import annotations

import copy
import os
import threading
import time
from pathlib import Path

from api import widget_schema
from api.island_store import _read_json, _safe_id, _write_json

# Serializes version read-modify-write across the threaded HTTP server (skill +
# app + browser can all save at once).
_LOCK = threading.RLock()


class WidgetStore:
    def __init__(self, root, profile: str = "default"):
        self.root = Path(root)
        self.base = self.root / "widgets" / (profile or "default")

    @property
    def _designs_dir(self) -> Path:
        return self.base / "designs"

    @property
    def _catalog_path(self) -> Path:
        return self.base / "catalog.json"

    def _design_path(self, design_id: str) -> Path:
        return self._designs_dir / f"{_safe_id(design_id)}.json"

    # ── designs ──────────────────────────────────────────────────────────────
    def list_design_ids(self) -> list[str]:
        d = self._designs_dir
        if not d.is_dir():
            return []
        return sorted(p.stem for p in d.glob("*.json"))

    def get_design(self, design_id: str) -> dict | None:
        doc = _read_json(self._design_path(design_id), None)
        return doc if isinstance(doc, dict) else None

    def list_designs(self) -> list[dict]:
        return [doc for did in self.list_design_ids()
                if (doc := self.get_design(did)) is not None]

    def upsert_design(self, design) -> tuple[dict | None, list[str], list[str]]:
        """Validate then store. Returns ``(saved, errors, warnings)``; saved is
        None when there are errors. The stored version is previous + 1 (or 1),
        whatever the caller sent."""
        errors, warnings = widget_schema.validate_design(
            design, catalog_keys=self.catalog_keys())
        if errors:
            return None, errors, warnings
        saved = copy.deepcopy(design)
        saved.setdefault("schema", 1)
        with _LOCK:
            prev = self.get_design(saved["id"]) or {}
            prev_ver = prev.get("version")
            prev_ver = prev_ver if isinstance(prev_ver, int) and prev_ver >= 0 else 0
            saved["version"] = prev_ver + 1
            _write_json(self._design_path(saved["id"]), saved)
        return saved, [], warnings

    def delete_design(self, design_id: str) -> bool:
        with _LOCK:
            p = self._design_path(design_id)
            if not p.exists():
                return False
            p.unlink()
            return True

    # ── catalog ──────────────────────────────────────────────────────────────
    def get_catalog(self) -> list[dict]:
        doc = _read_json(self._catalog_path, None)
        entries = doc.get("catalog") if isinstance(doc, dict) else None
        return entries if isinstance(entries, list) else []

    def catalog_keys(self) -> set[str]:
        return {e["key"] for e in self.get_catalog()
                if isinstance(e, dict) and isinstance(e.get("key"), str)}

    def set_catalog(self, entries) -> tuple[bool, list[str]]:
        errors = widget_schema.validate_catalog(entries)
        if errors:
            return False, errors
        with _LOCK:
            _write_json(self._catalog_path,
                        {"catalog": entries, "updated_at": time.time()})
        return True, []

    # ── aggregate view for GET /designs ──────────────────────────────────────
    def snapshot(self) -> dict:
        return {"designs": self.list_designs(), "catalog": self.get_catalog()}


def store_for_request() -> WidgetStore:
    """Build a store rooted at the webui state dir for the active profile."""
    root = os.environ.get("HERMES_WEBUI_STATE_DIR")
    if not root:
        root = str(Path.home() / ".jarviscopilot" / "webui")
    try:
        from api.profiles import get_active_profile_name
        profile = get_active_profile_name()
    except Exception:
        profile = "default"
    return WidgetStore(root, profile)
