"""Apply a machine's roster of live agent sessions to the conversation store.

A roster is what one machine reports as running right now: ``claude agents
--json`` (interactive and background Claude sessions) plus the Codex processes
its hooks named. It is the liveness signal: a session its owner stops listing
has ended. A machine never takes over a conversation another machine owns (a
Mac's stale copy of a session that moved to the server keeps running there
until it's closed), and never touches one mid-hand-off.
"""
from __future__ import annotations

from agent.agent_conversations import Conversations, ckey_for
from agent.transcript_mirror import safe_id

_RUN_KEYS = ("kind", "pid", "shell_pid", "bg_id", "terminal")


def _run(entry: dict) -> dict:
    return {k: entry[k] for k in _RUN_KEYS if entry.get(k) not in (None, "")}


def apply_roster(conv: Conversations, owner: str, entries: list, now: float,
                 agents=None, keep_kinds=()) -> list:
    """``agents``: the agents this roster reports (others it can't see are left
    alone); ``keep_kinds``: run kinds a roster can't list (headless Codex threads)."""
    changed: list = []
    seen: set = set()
    for e in entries or []:
        agent, sid = str(e.get("agent") or "claude"), str(e.get("session_id") or "")
        if not sid or not safe_id(sid):
            continue
        ckey = ckey_for(agent, sid)
        seen.add(ckey)
        row = conv.get(ckey)
        if row is not None and row.get("status") == "moving":
            continue
        if row is not None and row.get("owner") == "server" and row.get("moved_from") == owner:
            continue  # this Mac's stale copy of a moved session: never the conversation again
        if row is not None and row.get("owner") not in (None, owner) \
                and row.get("status") != "ended":
            continue
        fields = {"agent": agent, "session_id": sid, "owner": owner, "status": "live",
                  "run": _run(e), "ended_at": None, "last_seen_at": now}
        if e.get("cwd"):
            fields["cwd"] = e["cwd"]
        if e.get("name"):
            fields["title"] = e["name"]
        before = (row or {}).get("status"), (row or {}).get("owner"), (row or {}).get("run")
        conv.upsert(ckey, **fields)
        if before != ("live", owner, fields["run"]):
            changed.append(ckey)
    for row in conv.by_owner(owner):
        if row.get("status") != "live" or row["ckey"] in seen:
            continue
        if agents is not None and row.get("agent") not in agents:
            continue
        if (row.get("run") or {}).get("kind") in keep_kinds:
            continue
        conv.mark(row["ckey"], "ended", ended_at=now)
        changed.append(row["ckey"])
    return changed
