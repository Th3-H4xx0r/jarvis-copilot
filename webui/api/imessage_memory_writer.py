"""iMessage bursts → long-term memory.

A closed burst (``imessage_memory.IMStore.open_bursts``) becomes, in
jarvis_memory, the conversation itself — a header naming who and when, then
``[HH:MM] Name: text`` lines, split like Live's windows — plus a few standalone
facts pulled out of it ("Sam Lee's address is 12 Oak St") on the model or
harness he picked. Facts fail soft: with no model the transcript is still
remembered.
"""
from __future__ import annotations

import json
import logging
import re
import threading
import time
from datetime import datetime, timezone
from typing import Callable, List, Optional, Tuple

from api.imessage_memory import Burst, IMStore, store as default_store

logger = logging.getLogger(__name__)

MEMORY_CHUNK_CHARS = 1500
EXTRACT_SLICE_CHARS = 12000
MAX_FACTS = 8
BURSTS_PER_TICK = 20
TICK_SECONDS = 60

_PROMPT = """You are filing one of Pranav's iMessage conversations into his long-term memory.
"Me" is Pranav. Reply with ONLY a JSON object, no prose:
{{"summary": "<one or two sentences: who talked about what, any plan or outcome>",
  "facts": ["<standalone durable fact>", ...]}}
Facts: at most {max_facts}. Each must stand alone weeks from now, name people in full
("Sam Lee's address is 12 Oak St, Oakland"), and be worth remembering: addresses, phone
numbers or emails someone shared, birthdays, dates and plans, preferences, relationships,
jobs, recommendations, commitments. Never include codes, passwords, or one-time links.
No facts worth keeping → "facts": [].

Conversation:
{transcript}"""


# ── formatting ───────────────────────────────────────────────────────────
def _zone():
    try:
        from jarviscopilot_time import get_timezone
        zone = get_timezone()
        if zone is not None:
            return zone
    except Exception:
        pass
    return timezone.utc


def _people(burst: Burst, chat: dict) -> Tuple[List[str], List[str]]:
    """(names, handles) of the other people: the chat's participants, else the
    senders seen in the burst."""
    names, handles = [], []
    for p in chat.get("participants") or []:
        label = str(p.get("label") or p.get("handle") or "").strip()
        if label and label not in names:
            names.append(label)
        handle = str(p.get("handle") or "").strip()
        if handle and handle != label and handle not in handles:
            handles.append(handle)
    if not names:
        for r in burst.rows:
            if not r.get("is_from_me") and r.get("sender") and r["sender"] not in names:
                names.append(r["sender"])
    return names, handles


def _with_whom(burst: Burst, chat: dict) -> str:
    if chat.get("is_group") and chat.get("name"):
        return f"the group “{chat['name']}”"
    return ", ".join(_people(burst, chat)[0]) or "someone"


def _header(burst: Burst, chat: dict, zone, summary: str) -> str:
    names, handles = _people(burst, chat)
    begin = datetime.fromtimestamp(burst.start, zone)
    end = datetime.fromtimestamp(burst.end, zone)
    contact = f" ({', '.join(handles[:3])})" if handles and not chat.get("is_group") else ""
    lines = [f"iMessage with {_with_whom(burst, chat)}{contact} — {begin:%a} {begin.day} "
             f"{begin:%b %Y}, {begin:%H:%M}–{end:%H:%M} {begin:%Z}",
             "Participants: " + ", ".join(["Me"] + names)]
    if summary:
        lines.append("Summary: " + summary)
    return "\n".join(lines)


def _lines(burst: Burst, zone) -> List[str]:
    out = []
    for r in burst.rows:
        at = datetime.fromtimestamp(r["ts"], zone)
        who = "Me" if r.get("is_from_me") else (r.get("sender") or r.get("handle") or "Them")
        text = " ".join(str(r.get("text") or "").split())
        out.append(f"[{at:%H:%M}] {who}: {text}")
    return out


def transcript_memories(burst: Burst, chat: dict, zone, summary: str = "") -> List[Tuple[str, float]]:
    """``(body, created_at)`` per memory: the header (who, when, summary)
    repeated on each part, lines packed so no part passes MEMORY_CHUNK_CHARS.
    A single line longer than a part is cut rather than dropped."""
    head = _header(burst, chat, zone, summary)
    room = max(200, MEMORY_CHUNK_CHARS - len(head) - 1)
    parts, current, size = [], [], 0
    for line in _lines(burst, zone):
        line = line[:room]
        if current and size + len(line) + 1 > room:
            parts.append(current)
            current, size = [], 0
        current.append(line)
        size += len(line) + 1
    if current:
        parts.append(current)
    return [(head + "\n" + "\n".join(p), burst.start) for p in parts]


# ── extraction ───────────────────────────────────────────────────────────
_CODEISH = re.compile(r"\b(code|otp|passcode|password|verification)\b", re.I)


def parse_extraction(text: str) -> Tuple[str, List[str]]:
    """(summary, facts) from a model reply that should be one JSON object but
    may carry prose or a code fence around it. Raises ValueError when there is
    no object."""
    m = re.search(r"\{.*\}", text or "", re.S)
    if not m:
        raise ValueError("no JSON object in the reply")
    data = json.loads(m.group(0))
    summary = " ".join(str(data.get("summary") or "").split())[:400]
    facts = []
    for fact in data.get("facts") or []:
        fact = " ".join(str(fact or "").split())
        if len(fact.split()) >= 4 and not _CODEISH.search(fact) and fact not in facts:
            facts.append(fact[:300])
    return summary, facts[:MAX_FACTS]


def _model_ref(model: str, provider: Optional[str]) -> str:
    model = str(model or "").strip()
    if provider and model and not model.startswith("@"):
        return f"@{provider}:{model}"
    return model


def _default_model() -> str:
    from api.live_watchers import _default_chat_model
    return _default_chat_model()


def _no_route(node, text):
    # A model Route would spend a call per burst choosing a label; the
    # extraction always takes the route's default branch.
    from agent.harness.planner import RouteDecision
    return RouteDecision(None, "rules")


def _harness_model(harness_id: str) -> Optional[Tuple[str, str]]:
    """(model_ref, label) of a harness's answer node, or None when the harness
    is missing or invalid — the caller falls back to Default."""
    from agent.harness.planner import plan_turn
    from agent.harness.schema import validate_harness
    from api.harness_store import store_for_request

    doc = store_for_request().get(harness_id)
    if doc is None or validate_harness(doc, strict=False)[1]:
        return None
    plan = plan_turn(doc, session_model=_default_model(), session_provider=None,
                     text="Summarise this iMessage conversation and pull out facts.",
                     surface="schedule", has_attachments=False, classify=_no_route)
    ref = _model_ref(plan.model, plan.provider)
    return ref, f"harness {doc.get('name') or harness_id} → {ref}"


def resolve_extraction_model(agent) -> Tuple[str, str]:
    """(model_ref, label) for his choice: a model, a harness (its answer
    node's model), or None = his one Default (a harness, or the default model)."""
    agent = agent if isinstance(agent, dict) else {}
    if agent.get("model"):
        ref = _model_ref(agent["model"], agent.get("provider"))
        return ref, f"model {ref}"
    harness_id = str(agent.get("harness_id") or "").strip()
    prefix = ""
    if not harness_id:
        prefix = "Default → "
        try:
            from api.harness_store import store_for_request
            harness_id = store_for_request().effective("default")
        except Exception:
            harness_id = ""
        if harness_id == "single":
            harness_id = ""
    if harness_id:
        try:
            found = _harness_model(harness_id)
        except Exception:
            logger.warning("imessage memory: harness %r could not be planned", harness_id, exc_info=True)
            found = None
        if found:
            return found[0], prefix + found[1]
    ref = _default_model()
    return ref, f"Default → model {ref}"


def _one_shot(model_ref: str, prompt: str) -> str:
    from api.harness_llm import one_shot_completion
    return one_shot_completion(model_ref, prompt, max_tokens=1200)


def extract(transcript: str, model_ref: str, complete: Callable[[str, str], str]) -> Tuple[str, List[str]]:
    """Summary + facts for a transcript, in slices of EXTRACT_SLICE_CHARS
    (summaries joined, facts merged and capped). Raises when the model gives
    nothing usable."""
    if not model_ref:
        raise RuntimeError("no model to extract with")
    slices, current = [], ""
    for line in transcript.split("\n"):
        if current and len(current) + len(line) + 1 > EXTRACT_SLICE_CHARS:
            slices.append(current)
            current = ""
        current += line[:EXTRACT_SLICE_CHARS] + "\n"
    if current.strip():
        slices.append(current)
    summaries, facts = [], []
    for part in slices:
        summary, found = parse_extraction(complete(model_ref, _PROMPT.format(
            max_facts=MAX_FACTS, transcript=part)))
        if summary:
            summaries.append(summary)
        facts += [f for f in found if f not in facts]
    return " ".join(summaries)[:600], facts[:MAX_FACTS]


# ── storing ──────────────────────────────────────────────────────────────
def memory_writer():
    """jarvis_memory's external writer, or None when it isn't the active provider."""
    try:
        from plugins.memory.jarvis_memory import external
    except Exception:
        logger.debug("imessage memory: jarvis_memory unavailable", exc_info=True)
        return None
    return external if external.is_active() else None


def store_burst(st: IMStore, burst: Burst, *, memory, complete=None, zone=None) -> str:
    """Remember one burst. Returns ``stored``, ``stored_no_facts`` or
    ``discarded`` (its chat is no longer allowed)."""
    settings = st.settings()
    if not st.chat_allowed(burst.guid, settings):
        st.drop_burst(burst)
        return "discarded"
    chat = st.chat(burst.guid) or {}
    zone = zone or _zone()
    complete = complete or _one_shot
    summary, facts, status = "", [], "stored"
    try:
        model_ref, _label = resolve_extraction_model(settings.get("agent"))
        transcript = _header(burst, chat, zone, "") + "\n" + "\n".join(_lines(burst, zone))
        summary, facts = extract(transcript, model_ref, complete)
    except Exception as exc:
        logger.warning("imessage memory: no summary/facts for %s (%s); keeping the transcript",
                       burst.guid, exc)
        status = "stored_no_facts"
    base = f"imessage:{burst.guid}:{burst.first_rowid}-{burst.last_rowid}"
    for n, (body, when) in enumerate(transcript_memories(burst, chat, zone, summary), start=1):
        memory.remember(body, source=base + (f":p{n}" if n > 1 else ""),
                        tags="imessage,conversation", created_at=when, dedup=False)
    if facts:
        begin = datetime.fromtimestamp(burst.start, zone)
        stamp = (f"(from an iMessage chat with {_with_whom(burst, chat)} on {begin:%a} {begin.day} "
                 f"{begin:%b %Y} {begin:%H:%M} {begin:%Z})")
        for fact in facts:
            memory.remember(f"{fact} {stamp}",
                            source=f"imessage:{burst.guid}:fact:{burst.first_rowid}-{burst.last_rowid}",
                            tags="imessage,fact", created_at=burst.start)
    st.mark_burst(burst, status)
    return status


def close_once(st: Optional[IMStore] = None, now: Optional[float] = None, *, memory=None,
               complete=None) -> int:
    """Remember up to BURSTS_PER_TICK closed bursts. Nothing happens while
    jarvis_memory isn't the active provider: the messages wait."""
    st = st or default_store()
    memory = memory if memory is not None else memory_writer()
    if memory is None:
        return 0
    handled = 0
    for burst in st.open_bursts(now if now is not None else time.time())[:BURSTS_PER_TICK]:
        try:
            store_burst(st, burst, memory=memory, complete=complete)
        except Exception:
            logger.exception("imessage memory: burst %s:%s failed", burst.guid, burst.first_rowid)
            continue
        handled += 1
    return handled


def forget_chat_memories(guid: str, st: Optional[IMStore] = None, memory=None) -> int:
    """Delete a chat's memories and its burst records (so a backfill can redo it)."""
    memory = memory if memory is not None else memory_writer()
    gone = memory.forget(source_prefix=f"imessage:{guid}:") if memory is not None else 0
    (st or default_store()).forget_chat(guid)
    return gone


_closer_started = False
_closer_lock = threading.Lock()


def start_closer() -> None:
    """The background thread that turns quiet bursts into memories. Once per process."""
    global _closer_started
    with _closer_lock:
        if _closer_started:
            return
        _closer_started = True

    def _loop():
        while True:
            try:
                while close_once() >= BURSTS_PER_TICK:
                    pass  # a backfill's backlog drains without waiting a tick per 20
            except Exception:
                logger.exception("imessage memory: closer tick failed")
            time.sleep(TICK_SECONDS)

    threading.Thread(target=_loop, name="imessage-memory-closer", daemon=True).start()
