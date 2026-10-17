"""One record per coding-agent conversation, whichever machine runs it.

A conversation is the agent plus the agent's own session id (``claude|<sid>``,
``codex|<sid>``). Resuming it on another machine keeps the same id, so it
stays one row whose ``owner`` changes; ``/clear`` starts a new id and so a new
row. Terminal ids, background ids and pids are locators kept in ``run``,
never identity.

Statuses: ``live`` (its owner runs it), ``asleep`` / ``offline`` (the owner Mac
went to sleep or dropped off), ``moving`` (a hand-off is in progress),
``moved`` is not stored on the row (the owner changes instead) and ``ended``
(the process is gone; listed for 12 hours, then History).
"""
from __future__ import annotations

import threading
import time
from typing import Optional

ENDED_VISIBLE_HOURS = 12.0
_DEFAULTS = {"status": "live", "run": {}, "owner": None}


def ckey_for(agent: str, session_id: str) -> str:
    return f"{agent}|{session_id}"


class Conversations:
    def __init__(self, store, clock=time.time) -> None:
        self.store = store
        self._clock = clock
        self._lock = threading.RLock()

    def get(self, ckey: str) -> Optional[dict]:
        return self.store.get_conversation(ckey)

    def upsert(self, ckey: str, **fields) -> dict:
        with self._lock:
            now = self._clock()
            row = self.store.get_conversation(ckey)
            if row is None:
                agent, _, sid = ckey.partition("|")
                row = dict(_DEFAULTS, ckey=ckey, agent=agent, session_id=sid, created_at=now)
            row.update({k: v for k, v in fields.items()})
            row["updated_at"] = now
            self.store.put_conversation(ckey, row)
            return row

    def set_owner(self, ckey: str, owner: str, run: dict, status: str = "live") -> dict:
        return self.upsert(ckey, owner=owner, run=dict(run or {}), status=status,
                           ended_at=None)

    def mark(self, ckey: str, status: str, **fields) -> dict:
        if status == "ended" and "ended_at" not in fields:
            fields["ended_at"] = self._clock()
        return self.upsert(ckey, status=status, **fields)

    def by_owner(self, owner: str) -> list[dict]:
        return self.store.list_conversations(owner=owner)

    def all(self) -> list[dict]:
        return self.store.list_conversations()

    def list_visible(self, now: Optional[float] = None,
                     ended_hours: float = ENDED_VISIBLE_HOURS) -> list[dict]:
        now = self._clock() if now is None else now
        cutoff = now - ended_hours * 3600
        return [r for r in self.store.list_conversations()
                if r.get("status") != "ended" or (r.get("ended_at") or now) >= cutoff]

    def prune(self, now: Optional[float] = None, keep_days: float = 30.0) -> int:
        now = self._clock() if now is None else now
        return self.store.delete_conversations_ended_before(now - keep_days * 86400)
