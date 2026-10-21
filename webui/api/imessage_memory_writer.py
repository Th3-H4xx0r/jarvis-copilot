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
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from typing import Callable, List, Optional, Tuple

from api.imessage_memory import Burst, IMStore, store as default_store

logger = logging.getLogger(__name__)

EXTRACT_SLICE_CHARS = 12000
MAX_FACTS = 8
BURSTS_PER_TICK = 64
PARALLEL_CHATS = 8  # chats read at once — a 3-month backfill is thousands of model calls
TICK_SECONDS = 60

_PROMPT = """You are filing one of Pranav's iMessage conversations into his long-term memory.
"Me" is Pranav. Reply with ONLY a JSON object, no prose:
{{"keep": true or false,
  "summary": "<one to three sentences: who talked about what, any plan, decision or outcome>",
  "facts": ["<standalone durable fact>", ...]}}
"keep": true ONLY if this conversation is worth remembering weeks from now — plans, decisions,
news about someone's life, information someone shared, anything he may ask about later.
false for greetings, good mornings/nights, affection, reactions, small talk, photos or links
with no context, and automated or bot messages (including ones from "Jarvis"). When in doubt, false.
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


# ── extraction ───────────────────────────────────────────────────────────
_CODEISH = re.compile(r"\b(code|otp|passcode|password|verification)\b", re.I)


def parse_extraction(text: str) -> Tuple[str, List[str], bool]:
    """(summary, facts, keep) from a model reply that should be one JSON object
    but may carry prose or a code fence around it. ``keep`` — whether the
    conversation itself is worth a memory — defaults to "it had facts" when
    the model left it out. Raises ValueError when there is no object."""
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
    keep = data.get("keep")
    keep = bool(facts) if not isinstance(keep, bool) else keep
    return summary, facts[:MAX_FACTS], keep


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
    return ref, f"Default → model {ref}" if ref else "Default → no model set"


def _one_shot(model_ref: str, prompt: str) -> str:
    # Its own platform, so the Agents tab files these runs under the
    # integration (collapsed) instead of a session each among his chats.
    from api.harness_llm import one_shot_completion
    return one_shot_completion(model_ref, prompt, max_tokens=1200, platform="imessage_memory")


def extract(transcript: str, model_ref: str,
            complete: Callable[[str, str], str]) -> Tuple[str, List[str], bool]:
    """Summary, facts and keep for a transcript, in slices of EXTRACT_SLICE_CHARS
    (summaries joined, facts merged and capped, kept if any slice is worth it).
    Raises when the model gives nothing usable."""
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
    summaries, facts, keep = [], [], False
    for part in slices:
        summary, found, worth = parse_extraction(complete(model_ref, _PROMPT.format(
            max_facts=MAX_FACTS, transcript=part)))
        if summary:
            summaries.append(summary)
        facts += [f for f in found if f not in facts]
        keep = keep or worth
    return " ".join(summaries)[:600], facts[:MAX_FACTS], keep


# Under this many letters/digits of real text (tapbacks, emoji, a lone photo),
# a burst isn't worth a model call at all.
TRIVIAL_CHARS = 10
_ATTACHMENT = re.compile(r"\[(?:photo|video|voice memo|file[^\]]*)\]")


def is_trivial(burst: Burst) -> bool:
    text = " ".join(_ATTACHMENT.sub(" ", str(r.get("text") or "")) for r in burst.rows)
    return sum(ch.isalnum() for ch in text) < TRIVIAL_CHARS


# ── storing ──────────────────────────────────────────────────────────────
def memory_writer():
    """jarvis_memory's external writer, or None when it isn't the active provider."""
    try:
        from plugins.memory.jarvis_memory import external
    except Exception:
        logger.debug("imessage memory: jarvis_memory unavailable", exc_info=True)
        return None
    return external if external.is_active() else None


def _prefixes(guid: str, first_rowid: int, last_rowid: int) -> Tuple[str, str]:
    """(transcript prefix, facts prefix) of a burst. Each ends in ':' and every
    source adds a suffix after it (``p1``, ``f``), so forgetting one burst by
    prefix can't reach another whose span merely starts the same (10-12 vs 10-120)."""
    span = f"{first_rowid}-{last_rowid}"
    return f"imessage:{guid}:{span}:", f"imessage:{guid}:fact:{span}:"


def _sources(burst: Burst) -> Tuple[str, str]:
    return _prefixes(burst.guid, burst.first_rowid, burst.last_rowid)


def _take_back(memory, burst: Burst) -> None:
    for prefix in _sources(burst):
        memory.forget(source_prefix=prefix)


def store_burst(st: IMStore, burst: Burst, *, memory, complete=None, zone=None) -> str:
    """Remember one burst. Returns ``stored``, ``stored_no_facts``,
    ``discarded`` (its chat is no longer allowed, or he pressed Forget while
    it was being written) or ``failed`` (memory refused the write; the rows
    stay buffered and the next tick tries again)."""
    settings = st.settings()
    if not st.still_pending(burst):
        return "discarded"  # forgotten since the tick listed it
    if not st.chat_allowed(burst.guid, settings):
        st.drop_burst(burst)
        return "discarded"
    chat = st.chat(burst.guid) or {}
    zone = zone or _zone()
    complete = complete or _one_shot
    # Nothing is stored unless the model judges it worth remembering: a short
    # summary for a conversation that matters, facts on their own. Small talk,
    # goodnights and bot notices leave no memory at all.
    if is_trivial(burst):
        st.mark_burst(burst, "skipped", remembered=False)
        return "skipped"
    try:
        model_ref, _label = resolve_extraction_model(settings.get("agent"))
        transcript = _header(burst, chat, zone, "") + "\n" + "\n".join(_lines(burst, zone))
        summary, facts, keep = extract(transcript, model_ref, complete)
    except Exception as exc:
        logger.warning("imessage memory: couldn't judge %s (%s); nothing stored", burst.guid, exc)
        st.mark_burst(burst, "no_extract", remembered=False)
        return "no_extract"
    status = "stored" if keep or facts else "skipped"
    # Forgotten, unticked or skip-listed during the model call: nothing is written.
    if not st.still_pending(burst):
        return "discarded"
    if not st.chat_allowed(burst.guid):
        st.drop_burst(burst)
        return "discarded"
    base, fact_source = _sources(burst)
    st.begin_burst(burst)
    if keep and summary:
        if not memory.remember(_header(burst, chat, zone, summary), source=f"{base}p1",
                               tags="imessage,conversation", created_at=burst.start, dedup=False):
            _take_back(memory, burst)
            st.drop_burst_record(burst.guid, burst.first_rowid)
            logger.warning("imessage memory: memory refused %s; will retry", base)
            return "failed"
    carded = []
    if facts:
        begin = datetime.fromtimestamp(burst.start, zone)
        stamp = (f"(from an iMessage chat with {_with_whom(burst, chat)} on {begin:%a} {begin.day} "
                 f"{begin:%b %Y} {begin:%H:%M} {begin:%Z})")
        # A new conversation's facts wait for his Store/Skip (cards on the phone);
        # a backfill's are saved directly — hundreds of cards would bury him.
        if settings.get("ask_facts", True) and not burst.job_ids:
            carded = st.add_fact_cards(burst, _with_whom(burst, chat),
                                       [(fact, f"{fact} {stamp}") for fact in facts], f"{fact_source}f")
        else:
            for fact in facts:
                memory.remember(f"{fact} {stamp}", source=f"{fact_source}f",
                                tags="imessage,fact", created_at=burst.start)
    if not st.mark_burst(burst, status, remembered=status == "stored"):
        _take_back(memory, burst)  # Forget landed while this was written
        st.delete_cards(burst.guid, burst.first_rowid)
        return "discarded"
    if carded and settings.get("push_facts", True):
        push_facts(burst, chat, [c["fact"] for c in carded])
    return status


# ── fact cards ───────────────────────────────────────────────────────────
FACTS_CATEGORY = "IMESSAGE_FACTS"


def push_facts(burst: Burst, chat: dict, facts: List[str]) -> int:
    """One lock-screen push per conversation — "3 new facts from Sam Lee" —
    with Store all / Skip all (category IMESSAGE_FACTS) to every paired phone.
    Returns how many phones it reached; never raises."""
    if not facts:
        return 0
    try:
        from api import push as push_mod
        from api.pairing import list_devices
        devices = list_devices()
    except Exception:
        logger.debug("imessage memory: push unavailable", exc_info=True)
        return 0
    who = _with_whom(burst, chat)
    n = len(facts)
    title = f"{n} new fact{'s' if n != 1 else ''} from {who}"
    body = facts[0] if n == 1 else f"{facts[0]} — and {n - 1} more"
    data = {"type": "imessage_facts", "burst": f"{burst.guid}|{burst.first_rowid}"}
    sent = 0
    for d in devices:
        try:
            token = (d.get("push_token") or "").strip()
            if not token or (d.get("push_kind") or "").strip().lower() != "apns":
                continue
            if not (d.get("kind") or "").strip().lower().startswith("mobile"):
                continue
            res = push_mod.send("apns", token, data,
                                alert={"title": title[:120], "body": body[:240], "category": FACTS_CATEGORY})
            if res.get("ok"):
                sent += 1
        except Exception:
            logger.debug("imessage memory: fact push failed", exc_info=True)
    return sent


def _store_cards(st: IMStore, cards: list, memory, status: str) -> int:
    """Remember claimed cards. Written without dedup so ``None`` only ever
    means the write failed — those go back to waiting. A card deleted while
    this ran (he pressed Forget) has its memory taken back."""
    written, failed = [], []
    try:
        for card in cards:
            ok = memory.remember(card["body"], source=card["source"], tags="imessage,fact",
                                 created_at=card["at"], dedup=False)
            (written if ok else failed).append(card)
    finally:
        untouched = [c["id"] for c in cards if c not in written and c not in failed]
        st.release_cards([c["id"] for c in failed] + untouched)
    done = st.finish_cards([c["id"] for c in written], status)
    for card in written:
        if card["id"] not in done:
            memory.forget(source_prefix=card["source"])
    return len(done)


def decide_facts(st: Optional[IMStore] = None, *, ids=None, burst: Optional[str] = None,
                 store: bool, memory=None) -> int:
    """His Store / Skip on cards (by id, or every card of one conversation —
    the push's Store all). Each card is decided once even if the app and the
    lock screen answer together. Returns how many were decided."""
    st = st or default_store()
    if store:
        memory = memory if memory is not None else memory_writer()
        if memory is None:
            raise RuntimeError("long-term memory isn't active")
    cards = st.take_cards(ids=ids, burst=burst)
    if not cards:
        return 0
    if not store:
        st.finish_cards([c["id"] for c in cards], "skipped")
        return len(cards)
    return _store_cards(st, cards, memory, "stored")


def auto_store(st: IMStore, now: float, memory) -> int:
    """Cards nobody answered in a day are stored, as he chose."""
    cards = st.expired_cards(now)
    return _store_cards(st, cards, memory, "auto") if cards else 0


def close_once(st: Optional[IMStore] = None, now: Optional[float] = None, *, memory=None,
               complete=None) -> int:
    """Remember up to BURSTS_PER_TICK closed bursts. Nothing happens while
    jarvis_memory isn't the active provider: the messages wait."""
    st = st or default_store()
    memory = memory if memory is not None else memory_writer()
    if memory is None:
        return 0
    now = now if now is not None else time.time()
    st.expire_jobs(now)
    try:
        auto_store(st, now, memory)
    except Exception:
        logger.exception("imessage memory: auto-storing fact cards failed")
    # Different chats are read in parallel (one model call each at a time);
    # one chat's conversations stay in order.
    by_chat: dict = {}
    for burst in st.open_bursts(now)[:BURSTS_PER_TICK]:
        by_chat.setdefault(burst.guid, []).append(burst)
    refusing = threading.Event()

    def _chat(bursts: list) -> int:
        done = 0
        for burst in bursts:
            if refusing.is_set():
                break
            try:
                if store_burst(st, burst, memory=memory, complete=complete) == "failed":
                    refusing.set()  # memory is refusing writes: stop until the next tick
                    break
            except Exception:
                logger.exception("imessage memory: burst %s:%s failed", burst.guid, burst.first_rowid)
                continue
            done += 1
        return done

    handled = 0
    if by_chat:
        workers = max(1, min(PARALLEL_CHATS, len(by_chat)))
        with ThreadPoolExecutor(max_workers=workers, thread_name_prefix="imessage-memory") as pool:
            handled = sum(pool.map(_chat, by_chat.values()))
    st.finish_analyzed_jobs()
    return handled


def recover(st: Optional[IMStore] = None, memory=None) -> int:
    """Undo bursts a restart cut off mid-write: take back whatever memories
    they got and drop the record; their rows are still buffered, so the next
    tick writes them whole."""
    st = st or default_store()
    memory = memory if memory is not None else memory_writer()
    if memory is None:
        return 0
    st.release_stuck_cards()
    rows = st.storing_bursts()
    for row in rows:
        for prefix in _prefixes(row["guid"], row["first_rowid"], row["last_rowid"]):
            memory.forget(source_prefix=prefix)
        st.drop_burst_record(row["guid"], row["first_rowid"])
    return len(rows)


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
        try:
            recover()
        except Exception:
            logger.exception("imessage memory: recovery failed")
        while True:
            try:
                while close_once() >= BURSTS_PER_TICK:
                    pass  # a backfill's backlog drains without waiting a tick per 20
            except Exception:
                logger.exception("imessage memory: closer tick failed")
            time.sleep(TICK_SECONDS)

    threading.Thread(target=_loop, name="imessage-memory-closer", daemon=True).start()
