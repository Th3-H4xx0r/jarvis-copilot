"""Every message sent to an agent session is sent, queued, delivered or failed.

"Delivered" is proven, not assumed: it is set only when that session's
``UserPromptSubmit`` hook reports the same text. Nothing is ever shown as sent
when it went nowhere.
"""
from __future__ import annotations

import time
import uuid
from typing import Optional

_SCHEMA = """
CREATE TABLE IF NOT EXISTS agent_deliveries (
  id TEXT PRIMARY KEY, ckey TEXT NOT NULL, text TEXT NOT NULL, norm TEXT NOT NULL,
  state TEXT NOT NULL, reason TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_agent_deliveries_ckey ON agent_deliveries(ckey, created_at);
"""
STATES = ("sending", "sent", "queued", "delivered", "failed")
_OPEN = ("sending", "sent", "queued")


def _norm(text: str) -> str:
    return " ".join(str(text or "").split()).lower()


class Deliveries:
    def __init__(self, store, clock=time.time) -> None:
        self.store = store
        self._clock = clock
        with store._conn() as c:
            c.executescript(_SCHEMA)

    def create(self, ckey: str, text: str) -> str:
        did, now = uuid.uuid4().hex[:12], self._clock()
        with self.store._conn() as c:
            c.execute("INSERT INTO agent_deliveries(id,ckey,text,norm,state,reason,created_at,"
                      "updated_at) VALUES(?,?,?,?,?,?,?,?)",
                      (did, ckey, text, _norm(text), "sending", None, now, now))
        return did

    def mark(self, did: str, state: str, reason: Optional[str] = None) -> None:
        if state not in STATES:
            raise ValueError(state)
        with self.store._conn() as c:
            c.execute("UPDATE agent_deliveries SET state=?, reason=?, updated_at=? "
                      "WHERE id=? AND state != 'delivered'", (state, reason, self._clock(), did))

    def on_prompt(self, ckey: str, prompt: str) -> Optional[str]:
        norm = _norm(prompt)
        with self.store._conn() as c:
            row = c.execute("SELECT id FROM agent_deliveries WHERE ckey=? AND norm=? AND state "
                            "IN ('sending','sent','queued') ORDER BY created_at DESC LIMIT 1",
                            (ckey, norm)).fetchone()
            if row is None:
                return None
            c.execute("UPDATE agent_deliveries SET state='delivered', reason=NULL, updated_at=? "
                      "WHERE id=?", (self._clock(), row["id"]))
            return row["id"]

    def get(self, did: str) -> Optional[dict]:
        with self.store._conn() as c:
            r = c.execute("SELECT * FROM agent_deliveries WHERE id=?", (did,)).fetchone()
        return dict(r) if r else None

    def recent(self, ckey: str, limit: int = 20) -> list:
        with self.store._conn() as c:
            rows = c.execute("SELECT * FROM agent_deliveries WHERE ckey=? ORDER BY created_at "
                             "DESC LIMIT ?", (ckey, int(limit))).fetchall()
        return [dict(r) for r in rows]
