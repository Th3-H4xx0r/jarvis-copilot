"""Reading harness designs + the one default and its per-surface overrides.

    <state>/harnesses/<profile>/designs/<id>.json
    <state>/harnesses/<profile>/assignments.json   {"default": id, "voice": id|"", "chat": id|""}

``default`` is what every surface runs (chat, voice, the Pod, messaging,
schedules); Voice and Chat may override it ("" = same as default). Single is the
default model (config.yaml ``model.default``).

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

DEFAULT_ASSIGNMENTS = {"default": "single", "voice": "fast-claude", "chat": ""}
OVERRIDE_SURFACES = ("voice", "chat")
SURFACES = ("default",) + OVERRIDE_SURFACES  # the keys POST /api/harnesses/assign takes


def read_json(path: Path, default):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return default


def normalize_assignments(raw) -> dict:
    """The stored form, ``{"default": id, "voice": id|"", "chat": id|""}``. A file
    written before the one default (no ``default`` key) migrates without changing
    behaviour: its Chat harness becomes the default and Chat stops overriding."""
    raw = raw if isinstance(raw, dict) else {}

    def text(v):
        return v.strip() if isinstance(v, str) else ""

    if "default" in raw:
        return {"default": text(raw.get("default")) or DEFAULT_ASSIGNMENTS["default"],
                "voice": text(raw.get("voice")), "chat": text(raw.get("chat"))}
    return {"default": text(raw.get("chat")) or DEFAULT_ASSIGNMENTS["default"],
            "voice": text(raw.get("voice")) if "voice" in raw else DEFAULT_ASSIGNMENTS["voice"],
            "chat": ""}


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

    def stored_assignments(self) -> dict:
        return normalize_assignments(read_json(self._assign_path, None))

    def overrides(self) -> dict:
        """Voice/Chat's own harness, "" when it follows the default."""
        stored = self.stored_assignments()
        return {s: stored[s] for s in OVERRIDE_SURFACES}

    def effective(self, surface) -> str:
        """The harness a surface runs: its override (when that harness exists),
        else the default (when it exists), else Single. Surfaces without an
        override (messaging, schedules, …) run the default."""
        stored = self.stored_assignments()
        override = stored[surface] if surface in OVERRIDE_SURFACES else ""
        if override and self.get(override) is not None:
            return override
        return stored["default"] if self.get(stored["default"]) is not None else "single"

    def get_assignments(self):
        """The effective harness per surface plus ``default`` (clients that predate
        the one default read ``voice``/``chat`` as the harness to show)."""
        return {s: self.effective(s) for s in SURFACES}

    def snapshot(self):
        return {"harnesses": self.all_harnesses(), "assignments": self.get_assignments(),
                "overrides": self.overrides()}


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
