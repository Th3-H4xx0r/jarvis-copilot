"""IP deny list with expiry, shared by every process through one 0600 JSON file.

Each process keeps an in-memory copy and reloads it when the file changes, so a
``jarviscopilot security unblock`` from an SSH shell takes effect in the running
webui on its next request.
"""
from __future__ import annotations

import ipaddress
import json
import os
import tempfile
import threading
import time
from pathlib import Path


def _norm(ip: str) -> str:
    ip = (ip or "").strip()
    try:
        return str(ipaddress.ip_address(ip))
    except ValueError:
        return ip


class Blocklist:
    def __init__(self, path: Path, clock=time.time):
        self.path = Path(path)
        self.clock = clock
        self._lock = threading.Lock()
        self._entries: dict[str, dict] = {}
        self._stamp = None

    def _file_stamp(self):
        try:
            st = self.path.stat()
            return (st.st_mtime_ns, st.st_size, st.st_ino)
        except OSError:
            return None

    def _reload(self) -> None:
        stamp = self._file_stamp()
        if stamp == self._stamp:
            return
        entries: dict[str, dict] = {}
        if stamp is not None:
            try:
                data = json.loads(self.path.read_text(encoding="utf-8"))
                if isinstance(data, dict):
                    entries = {k: v for k, v in data.items() if isinstance(v, dict)}
            except Exception:
                entries = {}
        self._entries, self._stamp = entries, stamp

    def _save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=self.path.parent, suffix=".blocks.tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(self._entries, f, indent=1, sort_keys=True)
            os.chmod(tmp, 0o600)
            os.replace(tmp, self.path)
        except Exception:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        self._stamp = self._file_stamp()

    def _live(self, entry: dict) -> bool:
        return float(entry.get("expires", 0)) > self.clock()

    def block(self, ip: str, reason: str, ttl_s: int, event_id: int | None = None) -> dict:
        ip = _norm(ip)
        now = self.clock()
        entry = {"ip": ip, "reason": reason, "created": now, "expires": now + int(ttl_s),
                 "event_id": event_id}
        with self._lock:
            self._reload()
            self._entries[ip] = entry
            self._save()
        return dict(entry)

    def unblock(self, ip: str) -> bool:
        ip = _norm(ip)
        with self._lock:
            self._reload()
            entry = self._entries.pop(ip, None)
            if entry is None:
                return False
            self._save()
        return True

    def unblock_all(self) -> int:
        with self._lock:
            self._reload()
            count = sum(1 for e in self._entries.values() if self._live(e))
            if self._entries:
                self._entries = {}
                self._save()
        return count

    def is_blocked(self, ip: str) -> bool:
        if not ip:
            return False
        with self._lock:
            self._reload()
            entry = self._entries.get(_norm(ip))
        return bool(entry) and self._live(entry)

    def active(self) -> list[dict]:
        with self._lock:
            self._reload()
            live = [dict(e) for e in self._entries.values() if self._live(e)]
        return sorted(live, key=lambda e: e.get("created", 0), reverse=True)


_lists: dict[str, Blocklist] = {}
_lists_lock = threading.Lock()


def default_blocklist() -> Blocklist:
    """The profile's deny list at ``get_hermes_home()/security/blocks.json``."""
    from jarviscopilot_constants import get_hermes_home
    path = get_hermes_home() / "security" / "blocks.json"
    with _lists_lock:
        bl = _lists.get(str(path))
        if bl is None:
            bl = _lists[str(path)] = Blocklist(path)
        return bl
