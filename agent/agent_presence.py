"""Is a paired Mac awake, asleep or offline, and what did it leave paused?

The Mac says when it is about to sleep (``device_sleeping``); its sessions then
read *asleep* and the iPhone gets one push. A Mac that drops without warning
is given a grace period before its sessions read *offline* (a webui restart or
a network blip must not look like the Mac went away). Either way the paused
sessions form the card at the top of the Agents tab until each is continued,
dismissed, or the Mac comes back. All of it is stored, so a webui restart
keeps the card.
"""
from __future__ import annotations

import threading
import time
from typing import Callable, Optional

from agent.agent_conversations import Conversations

OFFLINE_GRACE = 60.0
_PAUSED = ("asleep", "offline")


class Presence:
    def __init__(self, store, conv: Conversations, clock=time.time,
                 push: Optional[Callable[[dict], None]] = None,
                 grace: float = OFFLINE_GRACE) -> None:
        self.store = store
        self.conv = conv
        self._clock = clock
        self._push = push or (lambda _p: None)
        self._grace = grace
        self._lock = threading.RLock()

    # ── events ───────────────────────────────────────────────────────────
    def on_sleep(self, device_id: str, device_name: str = "") -> None:
        self._pause(device_id, device_name, "sleep", "asleep")

    def on_disconnect(self, device_id: str, device_name: str = "") -> None:
        with self._lock:
            p = self.store.get_presence(device_id) or {}
            if p.get("state") in ("asleep", "offline"):
                return
            self.store.put_presence(device_id, **dict(
                _strip(p), state="disconnected", since=self._clock(),
                device_name=device_name or p.get("device_name") or ""))

    def on_connect(self, device_id: str, device_name: str = "") -> list:
        with self._lock:
            p = self.store.get_presence(device_id) or {}
            revived = []
            for row in self.conv.by_owner(device_id):
                # Only rows still paused: one a hand-off took meanwhile stays moving.
                if row.get("status") in _PAUSED and \
                        self.conv.transition(row["ckey"], _PAUSED, "live") is not None:
                    revived.append(row["ckey"])
            self.store.put_presence(device_id, state="online", since=self._clock(),
                                    device_name=device_name or p.get("device_name") or "",
                                    sessions=[], dismissed=[], pushed_at=None)
            return revived

    def on_boot(self, connected=()) -> None:
        """At webui start no bridge is up, and none closed with a disconnect
        event: a Mac stored as online that isn't connected now starts its grace
        period, so it reads offline (with its card) if it never comes back."""
        now = self._clock()
        live = set(connected or ())
        with self._lock:
            for p in self.store.list_presence():
                if p.get("state") == "online" and p["device_id"] not in live:
                    self.store.put_presence(p["device_id"], **dict(
                        _strip(p), state="disconnected", since=now))

    def tick(self) -> None:
        now = self._clock()
        for p in self.store.list_presence():
            if p.get("state") == "disconnected" and now - float(p.get("since") or now) >= self._grace:
                self._pause(p["device_id"], p.get("device_name") or "", "offline", "offline",
                            since=float(p.get("since") or now))

    def dismiss(self, device_id: str, ckeys: Optional[list] = None) -> None:
        with self._lock:
            p = self.store.get_presence(device_id)
            if not p:
                return
            gone = set(p.get("dismissed") or [])
            gone |= set(p.get("sessions") or []) if ckeys is None else set(ckeys)
            self.store.put_presence(device_id, **dict(_strip(p), dismissed=sorted(gone)))

    # ── reading ──────────────────────────────────────────────────────────
    def state(self, device_id: str) -> str:
        """online | disconnected | asleep | offline | unknown (never seen since boot)."""
        return (self.store.get_presence(device_id) or {}).get("state") or "unknown"

    def card(self) -> Optional[dict]:
        for p in sorted(self.store.list_presence(), key=lambda x: -(x.get("since") or 0)):
            if p.get("state") not in ("asleep", "offline"):
                continue
            dismissed = set(p.get("dismissed") or [])
            sessions = []
            for ckey in p.get("sessions") or []:
                row = self.conv.get(ckey)
                if ckey in dismissed or row is None:
                    continue
                if row.get("owner") == p["device_id"] and row.get("status") in _PAUSED:
                    sessions.append(ckey)
            if sessions:
                return {"device_id": p["device_id"], "device_name": p.get("device_name") or "",
                        "kind": "sleep" if p["state"] == "asleep" else "offline",
                        "since": p.get("since"), "sessions": sessions}
        return None

    # ── internals ────────────────────────────────────────────────────────
    def _pause(self, device_id, device_name, kind, status, since=None) -> None:
        with self._lock:
            now = self._clock()
            p = self.store.get_presence(device_id) or {}
            live = [r["ckey"] for r in self.conv.by_owner(device_id) if r.get("status") == "live"
                    and self.conv.transition(r["ckey"], ("live",), status) is not None]
            name = device_name or p.get("device_name") or ""
            already = p.get("state") in ("asleep", "offline") and p.get("pushed_at")
            sessions = sorted(set(p.get("sessions") or []) | set(live)) if already else live
            pushed_at = p.get("pushed_at") if already else None
            if live and not already:
                pushed_at = now
                try:
                    self._push({"device_id": device_id, "device_name": name,
                                "kind": kind, "count": len(live)})
                except Exception:  # noqa: BLE001
                    pass
            self.store.put_presence(device_id, state=status, since=since or now,
                                    device_name=name, sessions=sessions,
                                    dismissed=p.get("dismissed") or [] if already else [],
                                    pushed_at=pushed_at)


def _strip(p: dict) -> dict:
    return {k: v for k, v in p.items() if k != "device_id"}
