"""PC lighting on the server: the canonical lighting state, LED map, saved looks, setup steps, the
PC's specs and its last engine report — one JSON file per PC under get_hermes_home()/pc_lighting.

The PC renders frames from the state (jc-client pc_lighting); the iPhone runs the same maths on the
3D model. Spec: docs/superpowers/specs/2026-11-20-pc-lighting-model-specs-design.md
"""
from __future__ import annotations

import copy
import json
import os
import re
import threading
import time
from pathlib import Path
from typing import Callable, Optional

PARTS = ("top", "rear", "bottom", "cooler", "strip")
EFFECTS = ("static", "breathing", "rainbow", "spectrum", "comet")
FANS = {"top": 2, "rear": 2, "bottom": 3, "cooler": 1, "strip": 1}
DEFAULT_PART = {"effect": "static", "color": "#ffffff", "speed": 5}
_HEX = re.compile(r"^#[0-9a-fA-F]{6}$")
_SAFE = re.compile(r"[^A-Za-z0-9_.-]")


def _clamp(v, lo: int, hi: int) -> int:
    return max(lo, min(hi, int(round(float(v)))))


def validate_map(m: dict) -> list[str]:
    """Every problem with an LED map, as readable lines; [] = valid."""
    errs: list[str] = []
    if not isinstance(m, dict) or m.get("version") != 1:
        return ["map must be an object with version 1"]
    zones: dict[tuple[int, int], int] = {}
    for z in m.get("zones") or []:
        try:
            key, leds = (int(z["controller"]), int(z["zone"])), int(z["leds"])
        except (KeyError, TypeError, ValueError):
            errs.append(f"bad zone {z!r}")
            continue
        if key in zones:
            errs.append(f"zone {key} listed twice")
        if not 1 <= leds <= 1000:
            errs.append(f"zone {key} must have 1–1000 LEDs")
        zones[key] = leds
    used: dict[tuple[int, int], list[tuple[int, int, str]]] = {}
    fans: set[tuple[str, int]] = set()
    for s in m.get("segments") or []:
        try:
            part, index = s["part"], int(s.get("index", 0))
            key, start, count = (int(s["controller"]), int(s["zone"])), int(s["start"]), int(s["count"])
        except (KeyError, TypeError, ValueError):
            errs.append(f"bad segment {s!r}")
            continue
        name = f"{part} {index}"
        if part not in PARTS:
            errs.append(f"unknown part {part!r}")
            continue
        if not 0 <= index < FANS[part]:
            errs.append(f"{part} has no number {index}")
        if (part, index) in fans:
            errs.append(f"{name} is mapped twice")
        fans.add((part, index))
        if key not in zones:
            errs.append(f"{name}: zone {key} isn't in the map")
            continue
        if count <= 0 or start < 0 or start + count > zones[key]:
            errs.append(f"{name}: LEDs {start}–{start + count - 1} don't fit zone {key} ({zones[key]} LEDs)")
        for a, b, other in used.get(key, []):
            if start < b and a < start + count:
                errs.append(f"{name} overlaps {other}")
        used.setdefault(key, []).append((start, start + count, name))
        for extra in s.get("also") or []:
            if extra not in PARTS or extra == part:
                errs.append(f"{name}: can't share with {extra!r}")
        if "from" in s and s["from"] not in ("front", "back"):
            errs.append(f"{name}: from must be front or back")
    return errs


class PcLightingStore:
    def __init__(self, root: Path, clock: Callable[[], float] = time.time) -> None:
        self.root = Path(root)
        self._clock = clock
        self._lock = threading.RLock()
        self._cache: dict[str, dict] = {}

    # ── files ────────────────────────────────────────────────────────────────
    def _path(self, did: str) -> Path:
        return self.root / f"{_SAFE.sub('_', did)}.json"

    def _doc(self, did: str) -> dict:
        if did not in self._cache:
            try:
                self._cache[did] = json.loads(self._path(did).read_text(encoding="utf-8"))
            except (OSError, ValueError):
                self._cache[did] = {"device_id": did}
        return self._cache[did]

    def _save(self, did: str) -> None:
        self.root.mkdir(parents=True, exist_ok=True)
        tmp = self._path(did).with_suffix(".tmp")
        tmp.write_text(json.dumps(self._doc(did)), encoding="utf-8")
        os.replace(tmp, self._path(did))

    def devices(self) -> list[str]:
        with self._lock:
            ids = {p.stem for p in self.root.glob("*.json")} if self.root.exists() else set()
            ids |= set(self._cache)
            out = []
            for did in sorted(ids):
                out.append(self._doc(did).get("device_id", did))
            return out

    # ── state ────────────────────────────────────────────────────────────────
    def state(self, did: str) -> dict:
        with self._lock:
            d = self._doc(did)
            if "state" not in d:
                d["state"] = {"on": True, "brightness": 100, "t0": self._clock(), "frozen_at": None,
                              "still_in_games": False, "rev": 0,
                              "parts": {p: dict(DEFAULT_PART) for p in PARTS}}
            return copy.deepcopy(d["state"])

    def update_state(self, did: str, partial: dict) -> dict:
        with self._lock:
            s = self.state(did)
            part = partial.get("part", "all")
            if part != "all" and part not in PARTS:
                raise ValueError(f"unknown part {part!r}")
            targets = list(PARTS) if part == "all" else [part]
            if "effect" in partial and partial["effect"] not in EFFECTS:
                raise ValueError(f"unknown effect {partial['effect']!r}")
            if "color" in partial and not _HEX.match(str(partial["color"])):
                raise ValueError("colour must be #rrggbb")
            effect_changed = False
            for t in targets:
                p = s["parts"][t]
                if "effect" in partial and partial["effect"] != p["effect"]:
                    p["effect"] = partial["effect"]
                    effect_changed = True
                if "color" in partial:
                    p["color"] = str(partial["color"]).lower()
                if "speed" in partial:
                    p["speed"] = _clamp(partial["speed"], 1, 10)
            if "brightness" in partial:
                s["brightness"] = _clamp(partial["brightness"], 0, 100)
            if "on" in partial:
                s["on"] = bool(partial["on"])
            if "still_in_games" in partial:
                s["still_in_games"] = bool(partial["still_in_games"])
            if effect_changed:
                s["t0"] = self._clock()
            s["rev"] = int(s.get("rev", 0)) + 1
            self._doc(did)["state"] = s
            self._save(did)
            return copy.deepcopy(s)

    # ── looks ────────────────────────────────────────────────────────────────
    def looks(self, did: str) -> list[dict]:
        with self._lock:
            return copy.deepcopy(self._doc(did).get("looks", []))

    def save_look(self, did: str, name: str) -> dict:
        name = (name or "").strip()[:40]
        if not name:
            raise ValueError("a look needs a name")
        with self._lock:
            s = self.state(did)
            look = {"name": name, "parts": s["parts"], "brightness": s["brightness"]}
            looks = [l for l in self._doc(did).get("looks", []) if l["name"].lower() != name.lower()]
            self._doc(did)["looks"] = looks + [look]
            self._save(did)
            return copy.deepcopy(look)

    def apply_look(self, did: str, name: str) -> dict:
        with self._lock:
            look = next((l for l in self._doc(did).get("looks", []) if l["name"].lower() == (name or "").lower()), None)
            if look is None:
                raise KeyError(name)
            s = self.state(did)
            if any(s["parts"][p]["effect"] != look["parts"][p]["effect"] for p in PARTS):
                s["t0"] = self._clock()
            s["parts"] = copy.deepcopy(look["parts"])
            s["brightness"] = look["brightness"]
            s["on"] = True
            s["rev"] = int(s.get("rev", 0)) + 1
            self._doc(did)["state"] = s
            self._save(did)
            return copy.deepcopy(s)

    def delete_look(self, did: str, name: str) -> bool:
        with self._lock:
            looks = self._doc(did).get("looks", [])
            keep = [l for l in looks if l["name"].lower() != (name or "").lower()]
            self._doc(did)["looks"] = keep
            self._save(did)
            return len(keep) != len(looks)

    # ── map ──────────────────────────────────────────────────────────────────
    def map(self, did: str) -> dict:
        with self._lock:
            return copy.deepcopy(self._doc(did).get("map") or {"version": 1, "rev": 0, "zones": [], "segments": []})

    def set_map(self, did: str, m: dict) -> dict:
        errs = validate_map(m)
        if errs:
            raise ValueError("; ".join(errs))
        with self._lock:
            new = {"version": 1, "rev": int(self.map(did).get("rev", 0)) + 1,
                   "zones": copy.deepcopy(m.get("zones") or []), "segments": copy.deepcopy(m.get("segments") or [])}
            self._doc(did)["map"] = new
            self._save(did)
            return copy.deepcopy(new)

    def coverage(self, did: str) -> dict:
        """part → None (own LEDs), the part it shares with, or "missing"."""
        segs = self.map(did).get("segments") or []
        out: dict[str, Optional[str]] = {}
        for p in PARTS:
            if any(s["part"] == p for s in segs):
                out[p] = None
            else:
                host = next((s["part"] for s in segs if p in (s.get("also") or [])), None)
                out[p] = host or "missing"
        return out

    # ── specs, setup, the PC's report ────────────────────────────────────────
    def specs(self, did: str) -> Optional[dict]:
        with self._lock:
            return copy.deepcopy(self._doc(did).get("specs"))

    def set_specs(self, did: str, specs: dict) -> None:
        with self._lock:
            self._doc(did)["specs"] = copy.deepcopy(specs)
            self._save(did)

    def setup(self, did: str) -> dict:
        with self._lock:
            return copy.deepcopy(self._doc(did).get("setup", {}))

    def set_setup_step(self, did: str, step: dict) -> None:
        with self._lock:
            self._doc(did).setdefault("setup", {})[step["id"]] = dict(step, at=self._clock())
            self._save(did)

    def live(self, did: str) -> dict:
        with self._lock:
            return copy.deepcopy(self._doc(did).get("live", {}))

    def set_live(self, did: str, data: dict) -> None:
        with self._lock:
            self._doc(did)["live"] = dict(data, at=self._clock())
            self._save(did)


_STORE: Optional[PcLightingStore] = None
_STORE_LOCK = threading.Lock()


def store() -> PcLightingStore:
    global _STORE
    with _STORE_LOCK:
        if _STORE is None:
            from jarviscopilot_constants import get_hermes_home
            _STORE = PcLightingStore(get_hermes_home() / "pc_lighting")
        return _STORE
