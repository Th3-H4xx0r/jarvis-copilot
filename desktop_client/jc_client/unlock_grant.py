"""His unlock permission (2026-11-20): one Face ID-signed permission to unlock this computer without asking each
time, until it ends (30 days at most). jc-client keeps it here (and on disk, for restarts) and hands it to the
Jarvis app with an unlock; the app checks the signature against the key it pins before typing anything, so this
file is only a convenience — a forged or edited one gets refused there. A stopped permission never comes back,
even if replayed."""
from __future__ import annotations

import json
import logging
import re
import threading
import time
from pathlib import Path
from typing import Callable, Optional

log = logging.getLogger(__name__)

MAX_S = 30 * 86400
_ID = re.compile(r"^[0-9a-f]{32}$")


class GrantStore:
    def __init__(self, path: Path, clock: Callable[[], float] = time.time) -> None:
        self._path = Path(path)
        self._clock = clock
        self._lock = threading.Lock()
        self._grant: Optional[dict] = None
        self._revoked: list = []
        try:
            data = json.loads(self._path.read_text())
            self._grant = data.get("grant") if isinstance(data.get("grant"), dict) else None
            self._revoked = [str(x) for x in (data.get("revoked") or [])][-50:]
        except Exception:  # noqa: BLE001 — none yet
            pass

    def _ok(self, g) -> bool:
        if not isinstance(g, dict) or not _ID.match(str(g.get("id") or "")) or not g.get("signature"):
            return False
        try:
            ts, until = int(g.get("ts")), int(g.get("until"))
        except (TypeError, ValueError):
            return False
        now = self._clock()
        return until > now and until - ts <= MAX_S + 60 and str(g.get("id")) not in self._revoked

    def _save(self) -> None:
        try:
            self._path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self._path.with_suffix(".tmp")
            tmp.write_text(json.dumps({"grant": self._grant, "revoked": self._revoked[-50:]}))
            tmp.replace(self._path)
        except Exception:  # noqa: BLE001
            log.warning("unlock permission not saved", exc_info=True)

    def set(self, grant) -> None:
        with self._lock:
            if not self._ok(grant):
                return
            self._grant = {k: grant[k] for k in ("id", "ts", "until", "device", "signature") if k in grant}
            self._save()

    def revoke(self, gid) -> None:
        with self._lock:
            gid = str(gid or "")
            if gid and gid not in self._revoked:
                self._revoked.append(gid)
            if self._grant and str(self._grant.get("id")) == gid:
                self._grant = None
            self._save()

    def current(self) -> Optional[dict]:
        with self._lock:
            return dict(self._grant) if self._ok(self._grant) else None

    def handle_frame(self, frame: dict) -> None:
        """``mac_unlock_grant`` from the server: {"grant": {...}} or {"revoke": "<id>"}."""
        if frame.get("revoke"):
            self.revoke(frame["revoke"])
        elif isinstance(frame.get("grant"), dict):
            self.set(frame["grant"])
