"""Reading harness designs + the per-surface defaults.

    <state>/harnesses/<profile>/designs/<id>.json
    <state>/harnesses/<profile>/assignments.json   {"voice": id, "chat": id}

``<state>`` is the web UI state dir (``HERMES_WEBUI_STATE_DIR``, else
``<JarvisCopilot root>/webui``); ``<profile>`` is the profile whose home
``get_hermes_home()`` points at. The web UI owns the writes (its
``api.harness_store.HarnessStore`` adds them on top of this class); the
scheduler only reads. Built-ins live in code and are merged in on read. A
missing or corrupt file reads as empty.
"""
from __future__ import annotations

import copy
import json
import os
from pathlib import Path

from agent.harness.builtins import CLAUDE_REF, builtin_harnesses, fast_model_ref
from agent.harness.schema import validate_harness

DEFAULT_ASSIGNMENTS = {"voice": "fast-claude", "chat": "single"}
SURFACES = ("voice", "chat")


def read_json(path: Path, default):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return default


def safe_id(s) -> str:
    # Designs are validated to a slug, but defend the path anyway.
    return "".join(c for c in str(s) if c.isalnum() or c in "-_")[:64] or "_"


def is_safe(hid) -> bool:
    return bool(hid) and safe_id(hid) == hid


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

    def _fast_ref(self) -> str:
        return fast_model_ref()

    def _builtins(self):
        return builtin_harnesses(self._fast_ref(), CLAUDE_REF)

    def _builtin_ids(self):
        return {b["id"] for b in self._builtins()}

    def list_designs(self):
        out = []
        if self._designs_dir.is_dir():
            for p in sorted(self._designs_dir.glob("*.json")):
                doc = read_json(p, None)
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
        if not is_safe(hid):
            return None
        doc = read_json(self._designs_dir / f"{hid}.json", None)
        return doc if isinstance(doc, dict) and doc.get("id") else None

    def find(self, ref):
        """A harness by id, else by name (case-insensitive); None when unknown."""
        doc = self.get(ref)
        if doc is not None:
            return doc
        want = str(ref or "").strip().lower()
        if not want:
            return None
        return next((d for d in self._builtins() + self.list_designs()
                     if str(d.get("name") or "").strip().lower() == want), None)

    def names(self):
        """``{id: name}`` of every harness (built-ins and designs)."""
        return {str(d["id"]): str(d.get("name") or d["id"]) for d in self._builtins() + self.list_designs()}

    def all_harnesses(self):
        out = []
        for doc in self._builtins() + self.list_designs():
            item = copy.deepcopy(doc)
            item["problems"] = validate_harness(doc)[1]
            out.append(item)
        return out

    def get_assignments(self):
        raw = read_json(self._assign_path, None) or {}
        out = dict(DEFAULT_ASSIGNMENTS)
        for s in SURFACES:
            if isinstance(raw.get(s), str) and raw[s]:
                out[s] = raw[s]
        return out

    def snapshot(self):
        return {"harnesses": self.all_harnesses(), "assignments": self.get_assignments()}


def webui_state_dir() -> Path:
    """Where the web UI keeps its state (harness designs among it)."""
    env = os.environ.get("HERMES_WEBUI_STATE_DIR")
    if env:
        return Path(env).expanduser()
    from jarviscopilot_constants import get_default_hermes_root
    return get_default_hermes_root() / "webui"


def home_profile_name() -> str:
    """The profile ``get_hermes_home()`` points at (``default`` for the root home)."""
    from jarviscopilot_constants import get_hermes_home
    home = get_hermes_home()
    return home.name if home.parent.name == "profiles" and home.name else "default"


def store_for_home() -> HarnessStore:
    """The harness store of the profile this process runs as (the scheduler's)."""
    return HarnessStore(webui_state_dir(), home_profile_name())
