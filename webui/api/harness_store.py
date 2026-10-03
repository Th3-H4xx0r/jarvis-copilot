"""Per-profile storage for harness designs + the per-surface defaults.

    <state>/harnesses/<profile>/designs/<id>.json
    <state>/harnesses/<profile>/assignments.json   {"voice": id, "chat": id}

Built-ins live in code (api.harness_builtins) and are merged in on read; they
can be duplicated but never overwritten or deleted. Every design write bumps
``version``; writes are atomic and a missing or corrupt file reads as empty.
"""
from __future__ import annotations

import copy
import os
import threading
import time
from pathlib import Path

from api.harness_builtins import CLAUDE_REF, builtin_harnesses, fast_model_ref
from api.harness_schema import validate_harness
from api.island_store import _read_json, _safe_id, _write_json

DEFAULT_ASSIGNMENTS = {"voice": "fast-claude", "chat": "single"}
SURFACES = ("voice", "chat")
_LOCK = threading.RLock()


def _is_safe(hid) -> bool:
    return bool(hid) and _safe_id(hid) == hid


class HarnessStore:
    def __init__(self, root, profile: str = "default"):
        self.root = Path(root)
        self.base = self.root / "harnesses" / (profile or "default")

    @property
    def _designs_dir(self) -> Path:
        return self.base / "designs"

    @property
    def _assign_path(self) -> Path:
        return self.base / "assignments.json"

    def _builtins(self):
        return builtin_harnesses(fast_model_ref(), CLAUDE_REF)

    def _builtin_ids(self):
        return {b["id"] for b in self._builtins()}

    def list_designs(self):
        out = []
        if self._designs_dir.is_dir():
            for p in sorted(self._designs_dir.glob("*.json")):
                doc = _read_json(p, None)
                if isinstance(doc, dict) and doc.get("id"):
                    out.append(doc)
        return out

    def get(self, harness_id):
        hid = str(harness_id or "").strip()
        if not hid:
            return None
        for b in self._builtins():
            if b["id"] == hid:
                return b
        if not _is_safe(hid):
            return None
        doc = _read_json(self._designs_dir / f"{hid}.json", None)
        return doc if isinstance(doc, dict) and doc.get("id") else None

    def all_harnesses(self):
        out = []
        for doc in self._builtins() + self.list_designs():
            item = copy.deepcopy(doc)
            item["problems"] = validate_harness(doc)[1]
            out.append(item)
        return out

    def upsert_design(self, doc):
        if isinstance(doc, dict) and str(doc.get("id") or "") in self._builtin_ids():
            return None, [{"node": None, "edge": None,
                           "message": "That id belongs to a built-in harness; duplicate it under a new id."}]
        clean, errors = validate_harness(doc)
        if errors:
            return None, errors
        with _LOCK:
            path = self._designs_dir / f"{clean['id']}.json"
            prev = _read_json(path, None) or {}
            clean["version"] = int(prev.get("version") or 0) + 1
            clean["updated_at"] = time.time()
            _write_json(path, clean)
        return clean, []

    def delete_design(self, harness_id) -> bool:
        hid = str(harness_id or "")
        if hid in self._builtin_ids() or not _is_safe(hid):
            return False
        with _LOCK:
            path = self._designs_dir / f"{hid}.json"
            if not path.exists():
                return False
            path.unlink()
            assign = self.get_assignments()
            changed = False
            for s in SURFACES:
                if assign.get(s) == hid:
                    assign[s] = DEFAULT_ASSIGNMENTS[s]
                    changed = True
            if changed:
                _write_json(self._assign_path, assign)
        return True

    def get_assignments(self):
        raw = _read_json(self._assign_path, None) or {}
        out = dict(DEFAULT_ASSIGNMENTS)
        for s in SURFACES:
            if isinstance(raw.get(s), str) and raw[s]:
                out[s] = raw[s]
        return out

    def set_assignment(self, surface, harness_id) -> bool:
        if surface not in SURFACES or self.get(harness_id) is None:
            return False
        with _LOCK:
            assign = self.get_assignments()
            assign[surface] = harness_id
            _write_json(self._assign_path, assign)
        return True

    def snapshot(self):
        return {"harnesses": self.all_harnesses(), "assignments": self.get_assignments()}


def store_for_request() -> HarnessStore:
    """A store rooted at the webui state dir for the active profile."""
    root = os.environ.get("HERMES_WEBUI_STATE_DIR") or str(Path.home() / ".jarviscopilot" / "webui")
    try:
        from api.profiles import get_active_profile_name
        profile = get_active_profile_name()
    except Exception:
        profile = "default"
    return HarnessStore(root, profile)
