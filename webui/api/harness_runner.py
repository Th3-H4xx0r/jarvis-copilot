"""Harness runner: which node answers this turn, and what runs after it.

Planning lives in ``agent.harness.planner`` (the scheduler plans schedule runs
with it too) and is re-exported here: ``resolve_harness`` picks the harness
(the turn's requested one, else the chat's own, else the surface default; an
old client's explicit model runs as Single). ``plan_turn`` walks the graph from
the Message node through any Route nodes to the Answer node the user waits on,
and lists the Background / Review nodes wired to run after it. A model Route
asks through ``api.harness_llm`` (the web UI's model resolution).
"""
from __future__ import annotations

import logging
import re  # noqa: F401
import threading
import time  # noqa: F401
from dataclasses import dataclass, field  # noqa: F401

import api.config  # noqa: F401  (puts the JarvisCopilot checkout on sys.path for agent.*)
from agent.harness import planner as _planner
from agent.harness.planner import (  # noqa: F401  (re-exported)
    _NONE,
    _NONE_NOTE,
    _ROUTE_QUESTION,
    SESSION_MODEL,
    RouteDecision,
    TurnPlan,
    _model_and_provider,
    _parse_label,
    _route_choices,
    _route_prompt,
    _rule_matches,
    resolve_harness,
    single_harness,
)
from api.harness_schema import parse_when, validate_harness

logger = logging.getLogger(__name__)


def classify_with_model(node, text, timeout=1.5):
    """Ask the Route's model which label fits (see the core); a chat-model
    router answers through ``api.harness_llm.one_shot_completion``."""
    from api import harness_llm
    return _planner.classify_with_model(
        node, text, timeout, one_shot=lambda *a, **k: harness_llm.one_shot_completion(*a, **k))


def plan_turn(doc, *, session_model, session_provider, text, surface, has_attachments, classify=None):
    return _planner.plan_turn(doc, session_model=session_model, session_provider=session_provider,
                              text=text, surface=surface, has_attachments=has_attachments,
                              classify=classify or classify_with_model)


# ── after the answer: hand-off, background and review jobs ───────────────────
# Jobs run on agent.escalation's machinery (one daemon thread each, results
# delivered to live stream sinks — the voice socket speaks them). Here they also
# land in the chat as their own assistant message, are announced on the session
# event bus, and push a notification when no device is watching.

import copy as _copy
import json as _json
import time as _time


def _load_session(sid):
    from api.models import get_session
    return get_session(sid)


def _listener_count(sid) -> int:
    n = 0
    try:
        from api.session_events import SESSION_EVENTS
        n += SESSION_EVENTS.subscriber_count(sid)
    except Exception:
        pass
    try:
        from agent import escalation
        n += 1 if escalation.has_live_sink(sid) else 0
    except Exception:
        pass
    return n


def _push_alert(title, body, sid) -> int:
    from api import push as push_mod
    from api.pairing import list_devices
    sent = 0
    for d in list_devices() or []:
        token = (d.get("push_token") or "").strip()
        if not token or (d.get("push_kind") or "").strip().lower() != "apns":
            continue
        if push_mod.send("apns", token, {"type": "harness_result", "session_id": sid},
                         alert={"title": title, "body": (body or "")[:180]}):
            sent += 1
    return sent


def _one_shot(model_ref, prompt, max_tokens=600):
    from api.harness_llm import one_shot_completion
    return one_shot_completion(model_ref, prompt, max_tokens=max_tokens)


def _label_for(node):
    model = str(node.get("model") or "")
    return "Claude" if "claude" in model.lower() else (model.split(":")[-1] or "Background")


def _session_lock(sid):
    try:
        from api.config import _get_session_agent_lock
        return _get_session_agent_lock(sid)
    except Exception:
        return threading.Lock()


def deliver_result(session_id, *, node, kind, text, ms, error=None, spoken=False):
    """Save a background/review result into the chat and tell the devices.

    ``spoken``: the device the user asked from reads it out (speak-back), so it
    is being heard and no push goes to the phone."""
    meta = {"kind": kind, "node": node.get("id"), "model": node.get("model"), "ms": int(ms or 0)}
    if error:
        meta["error"] = str(error)[:300]
    message = {"role": "assistant", "content": text or "", "timestamp": _time.time(), "_meta": meta}
    s = _load_session(session_id)
    with _session_lock(session_id):
        s.messages.append(message)
        ctx = getattr(s, "context_messages", None)
        if isinstance(ctx, list) and ctx:
            ctx.append(dict(message))
        s.save()
    try:
        from api.session_events import SESSION_EVENTS
        SESSION_EVENTS.publish(session_id, "harness_result", {"session_id": session_id, "message": message})
    except Exception:
        logger.debug("harness_result publish failed", exc_info=True)
    if (node.get("deliver") in ("speak_or_notify", "notify") and not spoken
            and _listener_count(session_id) == 0):
        try:
            _push_alert(f"{_label_for(node)} {'finished' if not error else 'could not finish'}",
                        text or str(error or ""), session_id)
        except Exception:
            logger.warning("harness push failed", exc_info=True)
    return message


# ── the job card ─────────────────────────────────────────────────────────────
# A Background job shows in the chat as a card under the reply that started it
# (``_meta.jobs`` on that message): its node, live step, elapsed time and a Stop
# button, collapsing to one line when it ends. Live changes go out as
# ``harness_job`` session events; GET /api/harnesses/jobs/<session> catches a
# client up. Card statuses: running · done · failed · stopped.

_TOOL_ACTIVITY = {
    "web_search": "Searching the web", "web_extract": "Reading web pages",
    "terminal": "Running a command", "process": "Checking a process",
    "read_file": "Reading files", "write_file": "Writing a file", "patch": "Editing a file",
    "search_files": "Searching files", "execute_code": "Running code",
    "delegate_task": "Working with helpers", "session_search": "Searching past chats",
    "memory": "Saving to memory", "vision_analyze": "Looking at an image",
    "image_generate": "Making an image", "text_to_speech": "Making audio",
    "send_message": "Sending a message", "cronjob": "Scheduling a job", "todo": "Updating the plan",
    "skill_view": "Using a skill", "skills_list": "Using a skill", "skill_manage": "Using a skill",
    "tool_search": "Finding a tool", "clarify": "Asking you",
}
_BROWSER_PREFIXES = ("browser_", "chrome_")


def tool_activity(name):
    """What a tool call reads as on the card: "Searching the web"."""
    n = str(name or "").strip()
    if not n:
        return "Working"
    if n in _TOOL_ACTIVITY:
        return _TOOL_ACTIVITY[n]
    if n.startswith(_BROWSER_PREFIXES):
        return "Using the browser"
    return "Using " + n.replace("_", " ")


def job_card(job):
    """The card fields of an ``agent.escalation`` job."""
    parent = job.get("parent") or {}
    return {"id": job.get("job_id") or "", "node": parent.get("node_id") or "",
            "label": parent.get("node_label") or "Background", "model": job.get("model") or "",
            "status": job.get("status") or "running", "started_at": job.get("started_at"),
            "completed_at": job.get("completed_at"), "steps": int(job.get("steps") or 0),
            "activity": job.get("activity") or "", "stopping": bool(job.get("stop_requested"))}


def _background_jobs(session_id):
    from agent import escalation
    return [j for j in escalation.get_jobs(session_id)
            if (j.get("parent") or {}).get("kind") == "background"]


def _live_job_cards(session_id):
    return [job_card(j) for j in sorted(_background_jobs(session_id),
                                        key=lambda j: j.get("started_at") or 0)]


def session_job_cards(session_id):
    """Catch-up: where every job card of a chat stands — the jobs the server is
    running or just ran, plus the cards stored on the chat's replies (an ended
    one as stored; a stored running one the server no longer has is "lost": it
    was cut short by a restart). Clients take this as the answer."""
    cards = {c["id"]: c for c in _live_job_cards(session_id)}
    try:
        messages = getattr(_load_session(session_id), "messages", None) or []
    except Exception:
        messages = []
    for m in messages:
        for j in ((m.get("_meta") or {}).get("jobs") or []) if isinstance(m, dict) else []:
            if isinstance(j, dict) and j.get("id") and j["id"] not in cards:
                c = dict(j)
                if c.get("status") == "running":
                    c["status"] = "lost"
                cards[c["id"]] = c
    return sorted(cards.values(), key=lambda c: c.get("started_at") or 0)


def turn_job_cards(session_id, since):
    """Cards for the Background jobs a turn started (hand-offs), oldest first."""
    return [c for c in _live_job_cards(session_id) if float(c["started_at"] or 0) >= since]


def _publish_job(session_id, card):
    try:
        from api.session_events import SESSION_EVENTS
        SESSION_EVENTS.publish(session_id, "harness_job", {"session_id": session_id, "job": card})
    except Exception:
        logger.debug("harness_job publish failed", exc_info=True)
    _publish_feed()


# ── the jobs feed (the Mac's Agents tab) ─────────────────────────────────────
# Every Background job of the last few minutes, across chats, pushed on the
# device bridge's ``harness_jobs`` topic whenever one changes (jc-client relays
# it to Jarvis.app, which lists them with the coding sessions). Richer than the
# chat card: what was asked, where from, the recent steps and the answer.
#
# Speak-back: a job started from a VOICE turn whose conversation has since
# closed (push to talk on the Mac ends the moment Jarvis has answered) is read
# out by the device that asked: the finished job goes to that device alone with
# ``speak``. An open voice socket speaks it itself, so then nothing is sent.

JOBS_TOPIC = "harness_jobs"
FEED_MAX = 8
TRAIL_MAX = 12
RESULT_MAX = 6000


def job_origin(session_id, surface):
    """Where the turn starting a job came from: voice or chat, and the device
    (api/turn_origin.py knows it for the turn in flight)."""
    out = {"surface": surface or "chat"}
    try:
        from api import turn_origin
        device = turn_origin.origin_for_session(session_id)
    except Exception:
        device = None
    if device:
        out.update(device)
    return out


def _task_text(job):
    parent = job.get("parent") or {}
    return str(parent.get("question") or job.get("summary") or "").strip()[:1000]


def job_feed_entry(job):
    """A job as the Agents tab shows it: the card, plus what was asked, where
    from, its recent steps and its answer."""
    entry = job_card(job)
    origin = job.get("origin") or {}
    entry.update({
        "session_id": job.get("session_id") or "",
        "task": _task_text(job),
        "note": str(job.get("summary") or "").strip()[:1000],
        "surface": origin.get("surface") or "",
        "device": origin.get("name") or "",
        "device_kind": origin.get("kind") or "",
        "mac": bool(origin.get("mac")),
        "trail": list(job.get("trail") or [])[-TRAIL_MAX:],
        "result": str(job.get("result") or "")[:RESULT_MAX],
        "error": str(job.get("error") or "")[:300],
    })
    return entry


def jobs_feed(now=None):
    """The newest Background jobs, running or ended in the last few minutes."""
    from agent import escalation
    now = _time.time() if now is None else now
    keep = [j for j in escalation.all_jobs()
            if (j.get("parent") or {}).get("kind") == "background"
            and (not j.get("completed_at")
                 or now - float(j["completed_at"]) < escalation.JOB_RETENTION_SECONDS)]
    keep.sort(key=lambda j: j.get("started_at") or 0, reverse=True)
    return [job_feed_entry(j) for j in keep[:FEED_MAX]]


def _publish_feed():
    try:
        from api import device_bridge
        if device_bridge.subscribers(JOBS_TOPIC):
            device_bridge.publish(JOBS_TOPIC, {"jobs": jobs_feed()})
    except Exception:
        logger.debug("harness jobs feed publish failed", exc_info=True)


def _speak_back_device(job_id):
    """The device that should read this job's answer out now, or "": the one a
    voice turn handed off from, when no voice conversation is open to speak it
    and that device listens to the jobs feed (Jarvis.app on the Mac)."""
    from agent import escalation
    job = escalation.get_job(job_id) if job_id else None
    origin = (job or {}).get("origin") or {}
    device = origin.get("device_id")
    if not device or origin.get("surface") != "voice":
        return ""
    if escalation.has_speaking_sink(job.get("session_id")):
        return ""
    try:
        from api import device_bridge
        return device if device in device_bridge.subscribers(JOBS_TOPIC) else ""
    except Exception:
        return ""


def _send_speak(device, job_id):
    from agent import escalation
    job = escalation.get_job(job_id)
    if not job:
        return
    try:
        from api import device_bridge
        device_bridge.publish_to(device, JOBS_TOPIC, {"jobs": jobs_feed(), "speak": job_feed_entry(job)})
    except Exception:
        logger.warning("harness job %s: speak-back not sent", job_id, exc_info=True)


def _on_subscribe(device_id, topics):
    """A device that just asked for the feed gets where the jobs stand now."""
    if JOBS_TOPIC not in (topics or {}):
        return
    feed = jobs_feed()
    if feed:
        from api import device_bridge
        device_bridge.publish_to(device_id, JOBS_TOPIC, {"jobs": feed})


def attach_job_cards(session, message, cards):
    """Put job cards on the reply that started them (once each) and save.

    Each card is re-read from the registry under the session lock: a job that
    ended before its card landed (its own save found nothing to update) is
    stored as ended, not running."""
    if not cards:
        return
    from agent import escalation
    sid = session.session_id
    with _session_lock(sid):
        fresh = []
        for c in cards:
            job = escalation.get_job(c["id"])
            if job and job.get("session_id") != sid:
                # Compression gave the chat a new id mid-turn: the job's events,
                # result and Stop follow the card to it.
                job = escalation.update_job(c["id"], session_id=sid)
            fresh.append(job_card(job) if job else dict(c))
        jobs = message.setdefault("_meta", {}).setdefault("jobs", [])
        known = {j.get("id") for j in jobs if isinstance(j, dict)}
        jobs.extend(c for c in fresh if c["id"] not in known)
        session.save()
    for c in fresh:
        _publish_job(session.session_id, c)


def _persist_card(session_id, card):
    """Update the stored card in place (a turn's writeback keeps the message
    objects, so an in-place change survives a turn running at the same time)."""
    with _session_lock(session_id):
        s = _load_session(session_id)
        for m in reversed(getattr(s, "messages", None) or []):
            for entry in ((m.get("_meta") or {}).get("jobs") or []) if isinstance(m, dict) else []:
                if isinstance(entry, dict) and entry.get("id") == card["id"]:
                    entry.clear()
                    entry.update(card)
                    s.save()
                    return True
    return False


def _record_job(session_id, job_id, **fields):
    """Change a job in the registry and tell the devices; the new card or None."""
    from agent import escalation
    job = escalation.update_job(job_id, **fields)
    if job is None:
        return None
    card = job_card(job)
    _publish_job(job.get("session_id") or session_id, card)
    return card


def _job_session(job_id, session_id):
    """The chat a job belongs to now (compression may have moved it)."""
    from agent import escalation
    job = escalation.get_job(job_id) if job_id else None
    return (job or {}).get("session_id") or session_id


def _stop_requested(job_id):
    from agent import escalation
    job = escalation.get_job(job_id) if job_id else None
    return bool(job and job.get("stop_requested"))


def _finish_job(session_id, job_id, status, *, result="", error="", speak_device=""):
    """End a job: its card, the feed (with the answer) and, for a voice job
    whose conversation has closed, the device that reads it out."""
    card = _record_job(session_id, job_id, status=status, completed_at=_time.time(),
                       result=result or "", error=str(error or ""))
    if card is not None:
        try:
            _persist_card(_job_session(job_id, session_id), card)
        except Exception:
            logger.warning("harness job card not saved", exc_info=True)
        if speak_device:
            _send_speak(speak_device, job_id)


_FINAL_EVENTS = ("stream_end", "done", "cancel", "apperror")


def _watch_progress(q, session_id, job_id, stop=None):
    """Follow a Background job's hidden stream: count tool calls and tell the
    devices what it is doing, only when that changes."""
    import queue as _queue
    steps, activity, trail = 0, "", []
    while not (stop is not None and stop.is_set()):
        try:
            event, data = q.get(timeout=0.5)
        except _queue.Empty:
            continue
        if event in _FINAL_EVENTS:
            return
        data = data if isinstance(data, dict) else {}
        new_steps, new_activity = steps, activity
        if event == "tool" and data.get("event_type") in (None, "tool.started"):
            new_steps, new_activity = steps + 1, tool_activity(data.get("name"))
            # The Agents tab lists the recent steps, each with what it was on.
            trail = (trail + [{"t": new_activity, "tool": str(data.get("name") or ""),
                               "detail": " ".join(str(data.get("preview") or "").split())[:140],
                               "at": _time.time()}])[-TRAIL_MAX:]
        elif event == "reasoning" and not activity:
            new_activity = "Thinking"
        elif event == "token" and (steps or activity == "Thinking"):
            new_activity = "Writing the reply"
        if (new_steps, new_activity) != (steps, activity):
            steps, activity = new_steps, new_activity
            _record_job(session_id, job_id, steps=steps, activity=activity, trail=list(trail))


def stop_job(session_id, job_id):
    """Stop a running Background job of this chat (cancels its hidden turn)."""
    from agent import escalation
    job = escalation.get_job(job_id) if job_id else None
    if (not job or job.get("session_id") != session_id or job.get("status") != "running"
            or (job.get("parent") or {}).get("kind") != "background"):
        return False
    # Flag first, then read the stream id: a hidden turn registering its stream
    # at the same moment either sees the flag or is seen here.
    fresh = escalation.update_job(job_id, stop_requested=True) or job
    _publish_job(session_id, job_card(fresh))
    if fresh.get("stream_id"):
        from api.streaming import cancel_stream
        try:
            cancel_stream(fresh["stream_id"])
        except Exception:
            logger.warning("harness job %s: cancel failed", job_id, exc_info=True)
    return True


def _message_text(content):
    if isinstance(content, list):
        return " ".join(str(p.get("text") or "") for p in content if isinstance(p, dict)).strip()
    return str(content or "").strip()


def hidden_turn_prompt(summary, messages):
    """The background model's turn: finish the job, with the user's own latest
    words (the Mac-browser gate reads the turn's text; it must see what he
    actually asked, not only the hand-off note)."""
    latest = next((_message_text(m.get("content")) for m in reversed(messages or [])
                   if isinstance(m, dict) and m.get("role") == "user"), "")
    parts = ["A faster model handed this over to you. Finish it fully with your tools, then reply "
             "with the final answer for the user."]
    if summary:
        parts.append(f"Hand-off note: {summary}")
    if latest:
        parts.append(f"The user's latest message: \"{latest[:2000]}\"")
    return "\n\n".join(parts)


# ── a Background node's warm worker ─────────────────────────────────────────
# Each (chat, node) runs its jobs on one hidden worker session with a stable id,
# so the streaming worker's agent cache keeps that node's agent -- and its prompt
# cache -- warm from job to job (the cache's idle TTL and LRU cap bound it). A
# job starts from the chat's COMPACTED context, what the chat's own model sees:
# never the display transcript, never an earlier job's working steps (the chat
# already holds their results). The worker lives in memory only, is never
# listed, and two jobs for one worker take turns on it.

_WORKER_LOCKS: dict = {}
_WORKER_LOCKS_LOCK = threading.Lock()


def worker_session_id(parent_sid, node_id):
    """The hidden session a chat's Background node runs its jobs on."""
    from api.config import WORKER_SESSION_SEP
    return f"{parent_sid}{WORKER_SESSION_SEP}{node_id or 'background'}"


def _worker_lock(worker_sid):
    with _WORKER_LOCKS_LOCK:
        return _WORKER_LOCKS.setdefault(worker_sid, threading.Lock())


def _acquire_worker(lock, session_id, job_id):
    """Wait for the worker's previous job to finish. False when this job is
    stopped while it waits (it then never runs)."""
    if lock.acquire(blocking=False):
        return True
    if job_id:
        _record_job(session_id, job_id, activity="Waiting for the previous job")
    while not lock.acquire(timeout=0.5):
        if _stop_requested(job_id):
            return False
    if job_id:
        _record_job(session_id, job_id, activity="")
    return True


def _rewind_worker_agents(worker_sid):
    """A job starts from the chat's context, not where the last job left off.
    The agent's state.db flush cursor (run_agent._flush_messages_to_session_db
    writes from max(len(history), cursor)) is still past the end of the last
    job's longer history, so without a rewind the start of every later job --
    its prompt and first tool calls -- never reaches state.db (session search,
    the device-tool usage ranking). The worker's lock is held: no job runs."""
    from api.config import SESSION_AGENT_CACHE, SESSION_AGENT_CACHE_LOCK
    with SESSION_AGENT_CACHE_LOCK:
        agents = [e[0] for k, e in SESSION_AGENT_CACHE.items()
                  if (k == worker_sid or str(k).startswith(f"{worker_sid}#"))
                  and isinstance(e, tuple) and e]
    for agent in agents:
        agent._last_flushed_db_idx = 0


def _run_hidden_turn(node, session_id, summary, job_id=None):
    """The node's model on the chat's compacted context, on the node's warm worker."""
    import uuid as _uuid
    from api.config import (LOCK, SESSIONS, STREAMS, STREAMS_LOCK, create_stream_channel,
                            evict_session_agents, split_provider_qualified_model)
    from api.models import Session, WorkerSession
    from api.streaming import _run_agent_streaming
    if _stop_requested(job_id):
        return ""
    wid = worker_session_id(session_id, node.get("id"))
    lock = _worker_lock(wid)
    if not _acquire_worker(lock, session_id, job_id):
        return ""
    worker, stream_id, watching = None, None, threading.Event()
    try:
        if _stop_requested(job_id):
            return ""
        parent = Session.load(session_id)
        if parent is None:
            raise RuntimeError("the chat is gone")
        q = split_provider_qualified_model(node.get("model") or "")
        model, provider = node.get("model"), (q[0] if q else None)
        context = getattr(parent, "context_messages", None) or getattr(parent, "messages", None) or []
        worker = WorkerSession(session_id=wid, title=f"harness: {node.get('id')}",
                               workspace=parent.workspace, model=model, model_provider=provider,
                               profile=getattr(parent, "profile", None),
                               messages=_copy.deepcopy(context), context_messages=_copy.deepcopy(context))
        seeded = len(worker.messages)
        stream_id = _uuid.uuid4().hex
        worker.active_stream_id = stream_id
        worker._turn_node_override = node   # its own tools + instructions, not Single's
        with LOCK:
            SESSIONS[wid] = worker
        with STREAMS_LOCK:
            STREAMS[stream_id] = channel = create_stream_channel()
        if job_id:
            # The card's live step, and the stream its Stop button cancels.
            from agent import escalation
            escalation.update_job(job_id, stream_id=stream_id)
            threading.Thread(target=_watch_progress, args=(channel.subscribe(), session_id, job_id, watching),
                             daemon=True, name=f"jc-harness-job-{job_id}").start()
        # The current turn's message isn't in parent.messages until the turn ends.
        pending = getattr(parent, "pending_user_message", None)
        history = list(getattr(parent, "messages", None) or [])
        if pending:
            history.append({"role": "user", "content": pending})
        prompt = hidden_turn_prompt(summary, history)
        # The user's Mac browser: the background job follows the parent turn's
        # decision, not the hand-off note's wording (agent/mac_browser_gate.py).
        try:
            from agent import mac_browser_gate
            mac_browser_gate.pin(wid, mac_browser_gate.allowed(session_id))
        except Exception:
            logger.debug("mac browser gate: hidden turn not pinned", exc_info=True)
        if _stop_requested(job_id):
            return ""
        _rewind_worker_agents(wid)
        _run_agent_streaming(wid, prompt, model, parent.workspace, stream_id, None,
                             model_provider=provider)
        # Only this run's messages: the seeded history ends with the chat's
        # previous answer, which must never come back as this node's reply.
        added = (worker.messages or [])[seeded:]
        for m in reversed(added):
            if isinstance(m, dict) and m.get("role") == "assistant":
                content = str(m.get("content") or "").strip()
                if m.get("_error"):
                    raise RuntimeError(content or "the hand-off model failed")
                if content:
                    return content
        return ""
    finally:
        watching.set()
        # The worker's row and stream channel go; its cached agent stays warm.
        # Compression may have given the worker a new id mid-job: that agent no
        # longer matches the worker id, so it goes too.
        try:
            from api.config import SESSION_AGENT_LOCKS, SESSION_AGENT_LOCKS_LOCK
            rotated = worker is not None and worker.session_id != wid
            with LOCK:
                SESSIONS.pop(wid, None)
                if rotated:
                    SESSIONS.pop(worker.session_id, None)
            with SESSION_AGENT_LOCKS_LOCK:
                SESSION_AGENT_LOCKS.pop(wid, None)
                if rotated:
                    SESSION_AGENT_LOCKS.pop(worker.session_id, None)
            if rotated:
                evict_session_agents(worker.session_id)
            if stream_id:
                with STREAMS_LOCK:
                    STREAMS.pop(stream_id, None)
        except Exception:
            logger.debug("harness worker cleanup failed", exc_info=True)
        lock.release()


def background_runner(node, session_id):
    def _run(job):
        started = _time.time()
        job_id = job.get("job_id")
        try:
            text = _run_hidden_turn(node, _job_session(job_id, session_id),
                                    job.get("summary") or job.get("reason") or "", job_id=job_id)
            sid = _job_session(job_id, session_id)
            if _stop_requested(job_id):
                # Stopped from the card: nothing is posted or spoken.
                _finish_job(sid, job_id, "stopped")
                return ""
            status, error = "done", None
        except Exception as exc:
            sid = _job_session(job_id, session_id)
            if _stop_requested(job_id):
                _finish_job(sid, job_id, "stopped")
                return ""
            logger.warning("harness background node %s failed", node.get("id"), exc_info=True)
            text, status, error = f"Couldn't finish: {exc}", "failed", exc
        speaks = node.get("deliver") == "speak_or_notify"
        device = _speak_back_device(job_id) if speaks else ""
        deliver_result(sid, node=node, kind="background", text=text,
                       ms=(_time.time() - started) * 1000, error=error, spoken=bool(device))
        _finish_job(sid, job_id, status, result=text, error=error or "", speak_device=device)
        # Returned text is what an open voice socket speaks — or, with none open,
        # the next one to connect. A device reading it out itself has it already.
        return text if speaks and not device else ""
    return _run


def review_runner(node, session_id, question, answer):
    def _run(job):
        started = _time.time()
        prompt = ("You are reviewing an answer a faster model just gave. Reply ONLY with JSON "
                  '{"verdict": "ok" | "fix", "text": "<corrected or fuller answer when fix>"}.\n\n'
                  f"Question: {question}\n\nAnswer given: {answer}")
        try:
            raw = _one_shot(node.get("model"), prompt)
            data = _json.loads(raw[raw.index("{"):raw.rindex("}") + 1])
        except Exception:
            logger.debug("harness review produced no verdict", exc_info=True)
            return ""
        text = str(data.get("text") or "").strip()
        if text and (data.get("verdict") == "fix" or node.get("deliver") == "post"):
            deliver_result(session_id, node=node, kind="review", text=text,
                           ms=(_time.time() - started) * 1000)
            return text
        return ""
    return _run


def job_node(node):
    """What a job records about the node it runs (its card's label)."""
    return {"node_id": node.get("id") or "", "node_label": node.get("label") or node.get("id") or "",
            "kind": node.get("type") or ""}


def _start_job(session_id, node, runner, origin=None):
    from agent import escalation
    return escalation.start_escalation(session_id=session_id, reason=f"harness:{node.get('id')}",
                                       summary="", model=node.get("model"), runner=runner,
                                       parent=job_node(node), origin=origin)


def start_turn_jobs(plan, session, message, *, session_id, question, answer, elapsed_s, tool_count,
                    since):
    """Start the jobs wired after the answer, then put every Background job
    this turn started (after-jobs and hand-offs) on its reply as a card."""
    if getattr(plan, "after", None):
        start_after_jobs(plan, session_id=session_id, question=question, answer=answer,
                         elapsed_s=elapsed_s, tool_count=tool_count)
    if message is not None:
        attach_job_cards(session, message, turn_job_cards(session_id, since))


def start_after_jobs(plan, *, session_id, question, answer, elapsed_s, tool_count):
    """Start the Review/Background nodes wired after the answer whose
    condition holds (always · slow:<s> · tools:<n>). Returns job ids."""
    ids = []
    for node, when in getattr(plan, "after", None) or []:
        kind, value = parse_when(when)
        if kind == "slow" and not elapsed_s > int(value):
            continue
        if kind == "tools" and not tool_count > int(value):
            continue
        runner = (review_runner(node, session_id, question, answer) if node["type"] == "review"
                  else background_runner(node, session_id))
        ids.append(_start_job(session_id, node, runner,
                              origin=job_origin(session_id, getattr(plan, "surface", None))))
    return ids


# ── extraction model by harness ──────────────────────────────────────────────
# Settings → Web & browser → Extraction model may name a harness
# (web.extract_model: "harness:<id>"); its Route picks the model that turns each
# page into JSON (browser_extract). Core tools ask through
# agent.extract_model, which this registers with.

def extract_model_for(harness_id, instruction, page_chars):
    """``@provider:model`` the harness picks for one extraction, or None."""
    from api.harness_store import store_for_request
    doc = store_for_request().get(harness_id)
    if not doc or validate_harness(doc, strict=False)[1]:
        return None
    plan = plan_turn(doc, session_model=None, session_provider=None,
                     text=f"{instruction}\n\n(Page: {int(page_chars or 0)} characters)",
                     surface="chat", has_attachments=False)
    return plan.model or None


try:
    from agent import extract_model as _extract_model
    from api.config import split_provider_qualified_model as _split_ref
    _extract_model.register_resolver(extract_model_for)
    _extract_model.register_splitter(_split_ref)
except Exception:
    logger.debug("extraction-model resolver not registered", exc_info=True)

# Registered on import: any job there is was started from here, so a device
# that subscribes while one runs finds this module loaded.
try:
    from api import device_bridge as _device_bridge
    _device_bridge.on_subscribe(_on_subscribe)
except Exception:
    logger.debug("harness jobs feed: subscribe hook not registered", exc_info=True)
