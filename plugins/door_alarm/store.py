"""Door Alarm files under the root Jarvis home (not a profile — the webui swaps HERMES_HOME):

- ``config.json``  hub (dev id, product, DPs, roles), proxy board, alarm + contact settings
- ``secret.json``  the hub's local key (0600; never logged, never returned by an API)
- ``state.json``   the alarm state machine (survives restarts, deadlines included)
- ``events.jsonl`` history, newest last, pruned to 30 days
"""
from __future__ import annotations

import json
import os
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Optional

KEEP_DAYS = 30


def default_root() -> Path:
    from jarviscopilot_constants import get_default_hermes_root

    return get_default_hermes_root() / "door_alarm"


class DoorStore:
    def __init__(self, root: Path | None = None) -> None:
        self.root = Path(root) if root else default_root()
        self._lock = threading.RLock()
        self._appends = 0

    def _path(self, name: str) -> Path:
        return self.root / name

    def _read(self, name: str) -> dict:
        try:
            data = json.loads(self._path(name).read_text())
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    def _write(self, name: str, data: dict, mode: int = 0o600) -> None:
        with self._lock:
            self.root.mkdir(parents=True, exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=self.root, prefix=f".{name}.")
            try:
                os.fchmod(fd, mode)
                with os.fdopen(fd, "w") as fh:
                    json.dump(data, fh, indent=1, sort_keys=True)
                os.replace(tmp, self._path(name))
            except BaseException:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
                raise

    # ── documents ──

    def config(self) -> dict:
        return self._read("config.json")

    def save_config(self, cfg: dict) -> None:
        self._write("config.json", cfg)

    def update_config(self, **changes: Any) -> dict:
        with self._lock:
            cfg = self.config()
            cfg.update(changes)
            self.save_config(cfg)
            return cfg

    def secret(self) -> dict:
        return self._read("secret.json")

    def save_secret(self, data: dict) -> None:
        self._write("secret.json", data, mode=0o600)

    def state(self) -> dict:
        return self._read("state.json")

    def save_state(self, data: dict) -> None:
        self._write("state.json", data)

    # ── history ──

    def append_event(self, event: dict) -> None:
        line = json.dumps(event, separators=(",", ":"), default=str)
        with self._lock:
            self.root.mkdir(parents=True, exist_ok=True)
            path = self._path("events.jsonl")
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            with os.fdopen(fd, "a") as fh:
                fh.write(line + "\n")
            self._appends += 1
            if self._appends % 500 == 0:
                self.prune()

    def _lines(self) -> list[dict]:
        try:
            raw = self._path("events.jsonl").read_text().splitlines()
        except OSError:
            return []
        out = []
        for line in raw:
            try:
                item = json.loads(line)
            except ValueError:
                continue
            if isinstance(item, dict):
                out.append(item)
        return out

    def events(self, limit: int = 100, contact: Optional[str] = None, since: Optional[float] = None) -> list[dict]:
        """Newest first."""
        with self._lock:
            items = self._lines()
        out = []
        for item in reversed(items):
            if contact and item.get("contact") != contact:
                continue
            if since is not None and (item.get("t") or 0) < since:
                break
            out.append(item)
            if len(out) >= max(1, int(limit)):
                break
        return out

    def prune(self, now: Optional[float] = None) -> None:
        cutoff = (now or time.time()) - KEEP_DAYS * 86400
        with self._lock:
            keep = [i for i in self._lines() if (i.get("t") or 0) >= cutoff]
            self.root.mkdir(parents=True, exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=self.root, prefix=".events.")
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w") as fh:
                for item in keep:
                    fh.write(json.dumps(item, separators=(",", ":"), default=str) + "\n")
            os.replace(tmp, self._path("events.jsonl"))
