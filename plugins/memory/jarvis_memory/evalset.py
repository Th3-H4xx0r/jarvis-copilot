"""The personal eval: his real misses, replayed as of when he asked.

A case is a question Jarvis answered without the memory it needed and only
got right after a re-ask or a late ``memory_recall`` — "navigate to the
venue" is case #1. The gold memories are the ones that resolving recall
returned *and* the final answer actually used. ``replay`` runs a case set
through the old injection (recall on the previous message) or the new one
(brief + current-turn recall) on the store as it stands, counting only
memories that existed when he asked, and reports how often the gold memory
was in front of the model on the first try.

Cases live in $HERMES_HOME/memory/eval/ (they quote his chats) — never in the repo.
"""
from __future__ import annotations

import json
import sqlite3
import statistics
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime
from pathlib import Path
from typing import List, Optional

from .textq import content_tokens, strip_injected, strip_stamp

_REASK = 0.25       # word overlap between the miss and the re-ask
_USED = 2           # content words a gold memory must share with the final answer
_LOOKAHEAD = 3      # user turns after the miss that may hold the recovery


@dataclass
class Case:
    id: str
    as_of: float
    question: str
    prior_turns: List[dict] = field(default_factory=list)
    gold_ids: List[str] = field(default_factory=list)
    category: str = "implicit"


def save_cases(path, cases: List[Case]) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(asdict(c)) + "\n" for c in cases), encoding="utf-8")


def load_cases(path) -> List[Case]:
    out = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if line.strip():
            out.append(Case(**json.loads(line)))
    return out


def _jaccard(a: str, b: str) -> float:
    x, y = set(content_tokens(a)), set(content_tokens(b))
    return len(x & y) / len(x | y) if x and y else 0.0


def _called_recall(msgs) -> bool:
    for m in msgs:
        if m["role"] == "tool" and m["tool_name"] == "memory_recall":
            return True
        if m["role"] == "assistant" and "memory_recall" in (m["tool_calls"] or ""):
            return True
    return False


def mine_cases(state_db, *, since: Optional[float] = None, since_days: int = 60) -> List[Case]:
    since = since if since is not None else time.time() - since_days * 86400
    db = sqlite3.connect(f"file:{state_db}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    rows = db.execute(
        "SELECT session_id, role, content, tool_calls, tool_name, timestamp FROM messages "
        "WHERE timestamp >= ? ORDER BY session_id, timestamp, id", (since,)).fetchall()
    db.close()
    sessions: dict = {}
    for r in rows:
        sessions.setdefault(r["session_id"], []).append(r)
    cases = []
    for sid, msgs in sessions.items():
        turns = []  # (user message, [messages until the next user message])
        for m in msgs:
            if m["role"] == "user":
                m = dict(m)
                m["content"] = strip_injected(m["content"] or "")
                turns.append((m, []))
            elif turns:
                turns[-1][1].append(m)
        for i, (user, reply) in enumerate(turns):
            if _called_recall(reply) or not (user["content"] or "").strip():
                continue
            for later_user, later_reply in turns[i + 1:i + 1 + _LOOKAHEAD]:
                if not _called_recall(later_reply):
                    continue
                if _jaccard(user["content"], later_user["content"]) < _REASK:
                    break
                answer = " ".join(m["content"] or "" for m in later_reply if m["role"] == "assistant")
                words = set(content_tokens(answer))
                gold = []
                for m in later_reply:
                    if m["role"] != "tool" or m["tool_name"] != "memory_recall":
                        continue
                    try:
                        results = json.loads(m["content"] or "{}").get("results") or []
                    except ValueError:
                        results = []
                    for res in results:
                        if len(words & set(content_tokens(strip_stamp(res.get("body", ""))))) >= _USED:
                            gold.append(res["id"])
                if gold:
                    prior = [{"role": m["role"], "content": strip_injected(m["content"] or "")[:600]}
                             for m in msgs if m["timestamp"] < user["timestamp"]
                             and m["role"] in ("user", "assistant") and (m["content"] or "").strip()][-3:]
                    cases.append(Case(id=f"{sid}:{int(user['timestamp'])}", as_of=float(user["timestamp"]),
                                      question=user["content"], prior_turns=prior,
                                      gold_ids=list(dict.fromkeys(gold))))
                break
    return cases


def replay(store, embedder, cases: List[Case], *, mode: str, zone, namespace: str) -> dict:
    from . import brief as brief_mod
    from .entities import EntityIndex
    from .recall import RecallQuery, recall, recall_legacy

    index = EntityIndex(store, namespace)
    per_case, times, chars = [], [], []
    hits_r = hits_b = hits_any = 0
    for case in cases:
        existed = set(store.filtered_ids(namespace, until=case.as_of, limit=None))
        prev_user = next((t["content"] for t in reversed(case.prior_turns) if t["role"] == "user"), "")
        if prev_user and mode != "legacy":
            try:
                embedder.embed_cached([prev_user])  # embedded on its own turn, as live
            except Exception:
                pass
        t0 = time.perf_counter()
        brief_text = ""
        if mode == "legacy":
            hits = recall_legacy(store, embedder, prev_user, namespace, limit=5,
                                 candidate_ids=existed) if prev_user else []
            got = [h.chunk.id for h in hits]
        else:
            brief_text = brief_mod.build(store, namespace, now=datetime.fromtimestamp(case.as_of, zone))
            res = recall(store, embedder,
                         RecallQuery(text=case.question, context=prev_user, prior=prev_user,
                                     now=case.as_of, zone=zone),
                         entity_index=index, namespace=namespace, candidate_ids=existed)
            got = [h.chunk.id for h in res.hits]
        ms = (time.perf_counter() - t0) * 1000
        gold = set(case.gold_ids)
        in_retrieval = bool(gold & set(got[:5]))
        in_brief = False
        if brief_text:
            links = store.entities_for(list(gold))
            ents = store.get_entities([e for v in links.values() for e, _ in v])
            in_brief = any(e["type"] == "event" and e["canonical"] in brief_text for e in ents.values())
        hits_r += in_retrieval
        hits_b += in_brief
        hits_any += in_retrieval or in_brief
        times.append(ms)
        chars.append(len(brief_text) + sum(len(c.body) for c in store.get_chunks(got[:6])))
        per_case.append({"id": case.id, "question": case.question, "retrieval": in_retrieval,
                         "brief": in_brief, "got": got[:6], "ms": round(ms, 1)})
    n = len(cases) or 1
    times_sorted = sorted(times) or [0.0]
    return {
        "mode": mode, "n": len(cases),
        "recall5_retrieval": hits_r / n, "recall5_brief": hits_b / n, "recall5_combined": hits_any / n,
        "p50_ms": round(statistics.median(times_sorted), 1),
        "p95_ms": round(times_sorted[min(len(times_sorted) - 1, int(0.95 * len(times_sorted)))], 1),
        "avg_chars": round(sum(chars) / n), "per_case": per_case,
    }
