"""Per-profile storage for harness designs + the per-surface defaults.

    <state>/harnesses/<profile>/designs/<id>.json
    <state>/harnesses/<profile>/assignments.json   {"voice": id, "chat": id}

Reading lives in ``agent.harness.store`` (the scheduler reads designs too);
this adds the writes. Built-ins live in code and are merged in on read; they
can be duplicated but never overwritten or deleted. Every design write bumps
``version``; writes are atomic and a missing or corrupt file reads as empty.
"""
from __future__ import annotations

import os
import threading
import time
from pathlib import Path

import api.config  # noqa: F401  (puts the JarvisCopilot checkout on sys.path for agent.*)
from agent.harness.store import DEFAULT_ASSIGNMENTS, SURFACES  # noqa: F401  (re-exported)
from agent.harness.store import HarnessStore as _ReadOnlyStore
from agent.harness.store import is_safe as _is_safe
from api.harness_builtins import fast_model_ref
from api.harness_schema import validate_harness
from api.island_store import _read_json, _write_json

_LOCK = threading.RLock()


class HarnessStore(_ReadOnlyStore):
    def _fast_ref(self) -> str:
        return fast_model_ref()

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

    def set_assignment(self, surface, harness_id) -> bool:
        if surface not in SURFACES or self.get(harness_id) is None:
            return False
        with _LOCK:
            assign = self.get_assignments()
            assign[surface] = harness_id
            _write_json(self._assign_path, assign)
        return True


def store_for_request() -> HarnessStore:
    """A store rooted at the webui state dir for the active profile."""
    root = os.environ.get("HERMES_WEBUI_STATE_DIR") or str(Path.home() / ".jarviscopilot" / "webui")
    try:
        from api.profiles import get_active_profile_name
        profile = get_active_profile_name()
    except Exception:
        profile = "default"
    return HarnessStore(root, profile)
