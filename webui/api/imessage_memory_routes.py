"""HTTP surface of iMessage memory.

His side (the Integrations page, web + iPhone): the card, settings, chat picks,
forget, and manual backfill. The Mac's side: its config (which chats, skip
list, a pending backfill), the chat list, and uploaded messages. A change he
makes is pushed to the Mac as a ``{"type": "imessage_memory"}`` frame, which
only tells it to fetch its config again.
"""
from __future__ import annotations

import logging
import re
import threading
import time
import uuid

from api.imessage_memory import IMStore, normalize_handle, store

logger = logging.getLogger(__name__)

PREFIX = "/api/imessage-memory"
_MAX_MESSAGES_PER_POST = 1000


def _j(handler, payload, status=200):
    from api.helpers import j
    j(handler, payload, status=status)
    return True


def _bad(handler, message, status=400):
    return _j(handler, {"error": message}, status=status)


def _writer():
    import api.imessage_memory_writer as writer
    return writer


def _memory_count() -> int:
    """How many memories came from iMessage (0 when jarvis_memory is off)."""
    try:
        from plugins.memory.jarvis_memory import external
        if not external.is_active():
            return 0
        mem_store, _embedder, namespace, _threshold = external._open()
        return len(mem_store.filtered_ids(namespace, source_prefix="imessage:", limit=10 ** 9))
    except Exception:
        logger.debug("imessage memory: could not count memories", exc_info=True)
        return 0


def card(st: IMStore) -> dict:
    settings = st.settings()
    skip = st.skip_keys(settings)
    chats = [{"guid": c["guid"], "name": c.get("name") or "", "is_group": c["is_group"],
              "participants": c["participants"], "last_message_at": c.get("last_message_at"),
              "pick": c["pick"], "effective": st.effective_pick(c, skip),
              "remembered": int(c.get("remembered") or 0)}
             for c in st.chats()]
    writer = _writer()
    try:
        runs_on = writer.resolve_extraction_model(settings.get("agent"))[1]
    except Exception:
        runs_on = ""
    return {"enabled": bool(settings.get("enabled")),
            "memory_active": writer.memory_writer() is not None,
            "agent": settings.get("agent"), "runs_on": runs_on,
            "mac_seen_at": settings.get("mac_seen_at"),
            "mac_connected": _mac_connected(st),
            "ask_facts": bool(settings.get("ask_facts", True)),
            "push_facts": bool(settings.get("push_facts", True)),
            "pending_facts": st.pending_count(),
            "chats": chats, "skip": settings.get("skip") or [],
            "jobs": st.jobs(10), "active_job": st.active_job(),
            "totals": {"memories": _memory_count(), **st.totals()}}


def mac_config(st: IMStore) -> dict:
    """What the Mac filters by. Chats it hasn't told us about follow the
    default rule there too (1:1 on, group off)."""
    settings = st.settings()
    skip = st.skip_keys(settings)
    chats = st.chats()
    return {"enabled": bool(settings.get("enabled")),
            "enabled_at": settings.get("enabled_at"),
            "chats": {c["guid"]: st.effective_pick(c, skip) for c in chats},
            "skip": sorted(skip),
            "backfill": st.active_job()}


def _mac_connected(st: IMStore) -> bool:
    """Whether the Mac that uploads iMessages holds a live bridge right now."""
    known = st.settings().get("mac_device_id") or ""
    try:
        from api.device_bridge import connected_device_ids
        return bool(known) and known in connected_device_ids()
    except Exception:
        return False


def push_refresh(st: IMStore) -> bool:
    """Tell the Mac to fetch its config now. False when it isn't connected —
    it fetches on its own every couple of minutes."""
    return _send_to_mac(st, {"type": "imessage_memory"})


def _send_to_mac(st: IMStore, frame: dict) -> bool:
    """Send a frame to the Mac's bridge (the id ``_seen`` recorded from its own
    requests). False when it isn't connected. Never guesses another device:
    the Pod and ESP32 boards hold bridges too."""
    known = st.settings().get("mac_device_id") or ""
    if not known:
        return False
    try:
        from api.device_bridge import send_frame
        return bool(send_frame(known, frame))
    except Exception:
        return False


def _request_device_id(handler) -> str:
    """The paired device behind a request's session — for the Mac's calls,
    the same id its bridge connection is registered under (both use the one
    session). Its credentials' own ``device_id`` is a different id."""
    try:
        from api.device_bridge import _resolve_device_for_handler
        device = _resolve_device_for_handler(handler) if handler is not None else None
        return str((device or {}).get("id") or "")
    except Exception:
        logger.debug("imessage memory: no device for request", exc_info=True)
        return ""


def _seen(st: IMStore, handler) -> None:
    """The Mac called: note when, and which bridge reaches it."""
    fields = {"mac_seen_at": time.time()}
    device_id = _request_device_id(handler)
    if device_id:
        fields["mac_device_id"] = device_id
    st.update_settings(**fields)


def _valid_agent(agent):
    if agent is None:
        return True, None
    if not isinstance(agent, dict):
        return False, None
    if str(agent.get("harness_id") or "").strip():
        return True, {"harness_id": str(agent["harness_id"]).strip()}
    if str(agent.get("model") or "").strip():
        provider = str(agent.get("provider") or "").strip() or None
        return True, {"model": str(agent["model"]).strip(), "provider": provider}
    return False, None


def _valid_skip(skip):
    if not isinstance(skip, list):
        return None
    out, seen = [], set()
    for item in skip:
        handle = str((item.get("handle") if isinstance(item, dict) else item) or "").strip()
        key = normalize_handle(handle)
        if key and key not in seen:
            seen.add(key)
            label = str(item.get("label") or "") if isinstance(item, dict) else ""
            out.append({"handle": handle, "label": label[:120]})
    return out


def handle_get(handler, parsed) -> bool:
    if parsed.path == PREFIX:
        return _j(handler, card(store()))
    if parsed.path == PREFIX + "/config":
        st = store()
        # The Mac names itself here too, so a refresh can reach it before it
        # has ever uploaded anything (e.g. the moment he first switches it on).
        _seen(st, handler)
        return _j(handler, mac_config(st))
    if parsed.path == PREFIX + "/facts":
        return _j(handler, {"facts": store().pending_facts()})
    if parsed.path == PREFIX + "/memories":
        from urllib.parse import parse_qs
        guid = (parse_qs(parsed.query).get("guid") or [""])[0].strip()
        if not guid:
            return _bad(handler, "guid is required")
        return _j(handler, chat_memories(store(), guid))
    if parsed.path == PREFIX + "/preview":
        from urllib.parse import parse_qs
        guid = (parse_qs(parsed.query).get("guid") or [""])[0].strip()
        if not guid:
            return _bad(handler, "guid is required")
        result = request_preview(store(), guid)
        if "error" in result:
            return _bad(handler, result["error"], 504)
        return _j(handler, result)
    return False


# ── one chat's memories ───────────────────────────────────────────────────
_STAMP = re.compile(r"\s*\(from an iMessage chat with .*\)\s*$")


def chat_memories(st: IMStore, guid: str) -> dict:
    """What Jarvis holds from one chat, newest first: its saved facts (shown
    without the who/when stamp, which ``at`` carries), its conversation
    transcripts, and facts still waiting for his Store/Skip."""
    memory = _writer().memory_writer()
    rows = memory.memories(f"imessage:{guid}:", limit=500) if memory is not None else []
    facts, conversations = [], []
    for row in rows:
        if f"imessage:{guid}:fact:" in (row.get("source") or ""):
            facts.append({"id": row["id"], "text": _STAMP.sub("", row["body"]), "at": row["created_at"]})
        else:
            conversations.append({"id": row["id"], "text": row["body"], "at": row["created_at"]})
    waiting = [c for c in st.pending_facts(limit=200) if c["guid"] == guid]
    return {"facts": facts, "conversations": conversations, "waiting": waiting}


# ── previews: asked of the Mac live, never stored ────────────────────────
PREVIEW_TIMEOUT = 8.0
_previews: dict = {}
_previews_lock = threading.Lock()


def request_preview(st: IMStore, guid: str, timeout: float = None) -> dict:
    """The chat's last messages, straight from the Mac: ``{"messages": [...]}``
    or ``{"error": "..."}``. The request waits here (the webui is thread-per-
    request) until the Mac posts the answer or the timeout passes."""
    request_id = uuid.uuid4().hex
    waiter = {"event": threading.Event(), "result": None}
    with _previews_lock:
        _previews[request_id] = waiter
    try:
        if not _send_to_mac(st, {"type": "imessage_memory", "op": "preview",
                                 "request_id": request_id, "guid": guid}):
            return {"error": "Your Mac isn't connected — open it to see previews."}
        if not waiter["event"].wait(PREVIEW_TIMEOUT if timeout is None else timeout):
            return {"error": "Your Mac didn't answer — is it awake?"}
        result = waiter["result"] or {}
        if result.get("error"):
            return {"error": str(result["error"])[:200]}
        return {"messages": [m for m in result.get("messages") or [] if isinstance(m, dict)][:50]}
    finally:
        with _previews_lock:
            _previews.pop(request_id, None)


def deliver_preview(request_id: str, result: dict) -> bool:
    with _previews_lock:
        waiter = _previews.get(request_id)
    if waiter is None:
        return False  # timed out already
    waiter["result"] = result
    waiter["event"].set()
    return True


def handle_post(handler, parsed, body) -> bool:
    path = parsed.path
    if path != PREFIX and not path.startswith(PREFIX + "/"):
        return False
    body = body if isinstance(body, dict) else {}
    try:
        return _post(handler, path[len(PREFIX):], body, store())
    except Exception as exc:
        logger.exception("imessage memory: %s failed", path)
        return _bad(handler, f"iMessage memory: {exc}", 500)


def _post(handler, tail: str, body: dict, st: IMStore) -> bool:
    if tail == "/settings":
        fields = {}
        if "enabled" in body:
            fields["enabled"] = bool(body["enabled"])
        for toggle in ("ask_facts", "push_facts"):
            if toggle in body:
                fields[toggle] = bool(body[toggle])
        if "agent" in body:
            ok, agent = _valid_agent(body["agent"])
            if not ok:
                return _bad(handler, "agent must be null, {harness_id} or {model, provider}")
            fields["agent"] = agent
        if "skip" in body:
            skip = _valid_skip(body["skip"])
            if skip is None:
                return _bad(handler, "skip must be a list of {handle, label}")
            fields["skip"] = skip
        st.update_settings(**fields)
        if fields.get("enabled") is False:
            st.stop_active_jobs()  # the Mac stops reading, so it would never finish
        push_refresh(st)
        return _j(handler, card(st))

    if tail == "/chat":
        guid = str(body.get("guid") or "").strip()
        pick = body.get("pick")
        if not guid or pick not in (True, False, None):
            return _bad(handler, "guid and pick (true, false or null) are required")
        st.set_pick(guid, pick)
        push_refresh(st)
        return _j(handler, card(st))

    if tail == "/forget":
        guid = str(body.get("guid") or "").strip()
        if not guid:
            return _bad(handler, "guid is required")
        return _j(handler, {"ok": True, "forgotten": _writer().forget_chat_memories(guid, st=st)})

    if tail == "/backfill":
        try:
            start, end = float(body.get("from")), float(body.get("to"))
        except (TypeError, ValueError):
            return _bad(handler, "from and to (epoch seconds) are required")
        if not st.settings().get("enabled"):
            return _bad(handler, "turn iMessage memory on first")
        end = min(end, time.time())
        if start >= end:
            return _bad(handler, "from must be before to (and before now)")
        chats = body.get("chats")
        if chats is not None and (not isinstance(chats, list) or not all(isinstance(c, str) for c in chats)):
            return _bad(handler, "chats must be a list of chat ids")
        try:
            job = st.create_job(start, end, chats or None)
        except ValueError:
            return _bad(handler, "a backfill is already running — stop it first", 409)
        push_refresh(st)
        return _j(handler, {"ok": True, "job": job})

    if tail == "/backfill/stop":
        job = st.job(str(body.get("id") or ""))
        if not job:
            return _bad(handler, "no such backfill", 404)
        if job["status"] in ("pending", "running"):
            st.update_job(job["id"], status="stopped")
            push_refresh(st)
        return _j(handler, {"ok": True})

    if tail == "/memories/delete":
        chunk_id = str(body.get("id") or "").strip()
        if not chunk_id:
            return _bad(handler, "id is required")
        memory = _writer().memory_writer()
        if memory is None:
            return _bad(handler, "long-term memory isn't active", 409)
        # Only iMessage memories can be deleted from here.
        return _j(handler, {"ok": True, "deleted": memory.delete(chunk_id, source_prefix="imessage:")})

    if tail == "/facts/decide":
        ids = body.get("ids")
        burst = str(body.get("burst") or "").strip() or None
        if ids is not None and (not isinstance(ids, list) or not all(isinstance(i, str) for i in ids)):
            return _bad(handler, "ids must be a list of card ids")
        if not ids and not burst:
            return _bad(handler, "ids or burst is required")
        if not isinstance(body.get("store"), bool):
            return _bad(handler, "store (true or false) is required")
        try:
            n = _writer().decide_facts(st, ids=ids or None, burst=burst, store=body["store"])
        except RuntimeError as exc:
            return _bad(handler, str(exc), 409)
        return _j(handler, {"ok": True, "decided": n})

    # ── the Mac ──────────────────────────────────────────────────────────
    if tail == "/preview":
        deliver_preview(str(body.get("request_id") or ""),
                        {"messages": body.get("messages"), "error": body.get("error")})
        return _j(handler, {"ok": True})

    if tail == "/chats":
        _seen(st, handler)
        chats = body.get("chats")
        if not isinstance(chats, list):
            return _bad(handler, "chats must be a list")
        st.upsert_chats(c for c in chats if isinstance(c, dict))
        return _j(handler, {"ok": True})

    if tail == "/messages":
        _seen(st, handler)
        messages = body.get("messages")
        if not isinstance(messages, list) or len(messages) > _MAX_MESSAGES_PER_POST:
            return _bad(handler, f"messages must be a list of at most {_MAX_MESSAGES_PER_POST}")
        job_id = str(body.get("job_id") or "").strip() or None
        if job_id:
            job = st.job(job_id)
            if not job or job["status"] not in ("pending", "running"):
                # He stopped it (or it is gone): the Mac drops this run.
                return _j(handler, {"ok": True, "stopped": True, "accepted": 0, "duplicate": 0})
        counts = st.ingest([m for m in messages if isinstance(m, dict)], job_id=job_id)
        return _j(handler, {"ok": True, **counts})

    if tail == "/backfill/progress":
        _seen(st, handler)
        job = st.job(str(body.get("id") or ""))
        if not job:
            return _bad(handler, "no such backfill", 404)
        if job["status"] in ("pending", "running"):
            if body.get("error"):
                st.update_job(job["id"], status="error", error=str(body["error"])[:300])
            elif body.get("done"):
                st.update_job(job["id"], status="done")
        return _j(handler, {"ok": True})

    return False
