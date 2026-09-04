"""Fast-lane escalation: hand a turn the small model can't finish to the big one.

Plan 2.5 of the sub-second latency rehaul.

The fast lane (``claude-haiku-4-5`` on the native Anthropic adapter) answers in
~300 ms and covers the overwhelming majority of voice/chat turns. When a turn is
genuinely beyond it — deep research, a long agentic chain, anything needing the
full toolset — the model calls one extra tool::

    escalate(reason: str, summary: str)

That call does NOT block. The fast turn ends with the ack text the model already
produced ("On it — let me dig into that"), and a background job re-runs the same
turn on the escalation model (``claude-sonnet-5`` by default,
``claude-opus-5`` for coding) with the full toolset. Its answer is pushed back
onto the session's existing stream as::

    {"type": "escalation_result", "job_id": "...", "text": "..."}

Delivery is best-effort-with-a-buffer: if a stream sink is live for that session
the event goes straight out; otherwise it is buffered and flushed to the next
sink that registers (the next turn's stream), so a result is never simply lost.
Older clients ignore an unknown event type, so this is backward compatible.

Structure mirrors ``webui/api/background.py``'s job pattern: a module-level
registry under one lock, a daemon thread per job, and a status record callers can
poll.
"""
from __future__ import annotations

import json
import logging
import threading
import time
import uuid
from typing import Any, Callable, Dict, List, Optional, Tuple

logger = logging.getLogger(__name__)

# ── constants (plan 2.5) ─────────────────────────────────────────────────────

#: Default Lane 2 model. Approved decision: Sonnet 5 for general escalation.
DEFAULT_ESCALATION_MODEL = "claude-sonnet-5"
#: Coding turns escalate to Opus instead — long agentic chains, not chat.
DEFAULT_CODING_ESCALATION_MODEL = "claude-opus-5"
#: Lanes that can carry a fast lane. Same YAML shape under each.
LANES = ("voice", "chat")
#: How long a background escalation may run before it is declared failed.
#: Generous — this is the *slow* lane by construction. plan 2.5
ESCALATION_TIMEOUT_SECONDS = 600.0
#: Cap on buffered undelivered events per session, so a client that never comes
#: back can't grow the buffer without bound. plan 2.5
MAX_PENDING_EVENTS = 20
#: Completed jobs older than this are dropped from the registry. plan 2.5
JOB_RETENTION_SECONDS = 900.0

ESCALATION_EVENT = "escalation_result"
ESCALATION_TOOL_NAME = "escalate"

_lock = threading.RLock()
# job_id -> job record
_jobs: Dict[str, Dict[str, Any]] = {}
# session_id -> [sink(event_name, data_dict), ...]
_sinks: Dict[str, List[Callable[[str, dict], None]]] = {}
# session_id -> [(event_name, data_dict), ...] awaiting a live sink
_pending: Dict[str, List[Tuple[str, dict]]] = {}
# task_id -> context bound by the agent loop for the duration of one turn
_turn_context: Dict[str, Dict[str, Any]] = {}


# ── config ───────────────────────────────────────────────────────────────────

def _load_config() -> dict:
    """Load the CLI config. Split out so tests can monkeypatch it."""
    try:
        from jarviscopilot_cli.config import load_config
        return load_config() or {}
    except Exception:
        return {}


def _split_qualified(value: Optional[str]) -> Tuple[Optional[str], Optional[str]]:
    """``"@anthropic:claude-haiku-4-5"`` -> ``("anthropic", "claude-haiku-4-5")``.

    A bare model name yields ``(None, model)``. This mirrors the ``@provider:model``
    form the rest of JarvisCopilot already accepts in config and on the CLI.
    """
    if not value or not isinstance(value, str):
        return None, None
    text = value.strip()
    if text.startswith("@") and ":" in text:
        provider, _, model = text[1:].partition(":")
        return (provider.strip() or None), (model.strip() or None)
    return None, text or None


def _normalize_lane_block(raw: Any, *, default_model: Optional[str] = None) -> dict:
    """Normalize one ``fast_lane`` / ``escalation`` value to a common shape.

    Accepts, in order of how WS-A might write it:
      * ``True`` / ``False``
      * ``"@anthropic:claude-haiku-4-5"`` (or a bare model name)
      * ``{"enabled": bool, "provider": str, "model": str}``, where ``model`` may
        itself be ``@provider:model``.
    """
    out = {"enabled": False, "provider": None, "model": None}
    if raw is None:
        pass
    elif isinstance(raw, bool):
        out["enabled"] = raw
    elif isinstance(raw, str):
        provider, model = _split_qualified(raw)
        out.update({"enabled": bool(model), "provider": provider, "model": model})
    elif isinstance(raw, dict):
        provider, model = _split_qualified(raw.get("model"))
        out["provider"] = raw.get("provider") or provider
        out["model"] = model
        enabled = raw.get("enabled")
        # A model with no explicit `enabled` means "on" — writing the model down
        # is the opt-in. An explicit False always wins.
        out["enabled"] = bool(model) if enabled is None else bool(enabled)
    if out["model"] is None and default_model and out["enabled"]:
        out["model"] = default_model
    return out


def fast_lane_config(config: Optional[dict], lane: str = "voice") -> dict:
    """``<lane>.fast_lane`` from an ALREADY-LOADED config dict.

    WS-A owns the YAML keys (``voice.fast_lane`` / ``voice.escalation``); this
    only reads them, and accepts every shape they might take.
    """
    block = ((config or {}).get(lane) or {})
    if not isinstance(block, dict):
        return {"enabled": False, "provider": None, "model": None}
    return _normalize_lane_block(block.get("fast_lane"))


def escalation_config(config: Optional[dict], lane: str = "voice") -> dict:
    """``<lane>.escalation``. Enabled by default whenever the lane's fast lane is."""
    block = ((config or {}).get(lane) or {})
    if not isinstance(block, dict):
        return {"enabled": False, "provider": None, "model": None}
    raw = block.get("escalation")
    if raw is None:
        # No explicit escalation config: escalation follows the fast lane.
        fast = _normalize_lane_block(block.get("fast_lane"))
        return {"enabled": fast["enabled"], "provider": fast["provider"],
                "model": DEFAULT_ESCALATION_MODEL if fast["enabled"] else None}
    return _normalize_lane_block(raw, default_model=DEFAULT_ESCALATION_MODEL)


def fast_lane_active(config: Optional[dict] = None, lane: Optional[str] = None) -> bool:
    """True when a fast lane is configured — for ``lane``, or for ANY lane."""
    cfg = _load_config() if config is None else config
    lanes = (lane,) if lane else LANES
    return any(fast_lane_config(cfg, ln)["enabled"] for ln in lanes)


def escalation_active(config: Optional[dict] = None, lane: Optional[str] = None) -> bool:
    cfg = _load_config() if config is None else config
    lanes = (lane,) if lane else LANES
    return any(escalation_config(cfg, ln)["enabled"] for ln in lanes)


def resolve_escalation_model(config: Optional[dict] = None, *,
                             lane: Optional[str] = None,
                             coding: bool = False) -> str:
    """The model a turn escalates to. Coding turns get Opus, everything else Sonnet."""
    cfg = _load_config() if config is None else config
    for ln in ((lane,) if lane else LANES):
        block = escalation_config(cfg, ln)
        if block["enabled"] and block["model"]:
            return block["model"]
    return DEFAULT_CODING_ESCALATION_MODEL if coding else DEFAULT_ESCALATION_MODEL


# ── the tool ─────────────────────────────────────────────────────────────────

ESCALATE_TOOL_SCHEMA = {
    "name": ESCALATION_TOOL_NAME,
    "description": (
        "Hand this turn to a larger model with the full toolset. Call this when "
        "the request needs deep research, many tool calls, long-horizon work, or "
        "capabilities you do not have. Say a short acknowledgement to the user in "
        "the SAME turn (e.g. \"On it — give me a moment\"): your reply ends there "
        "and the bigger model's answer is delivered to the user automatically "
        "when it is ready. Do NOT call this for anything you can answer or do "
        "yourself — it costs the user several seconds."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "reason": {
                "type": "string",
                "description": "Why the bigger model is needed, in one short phrase.",
            },
            "summary": {
                "type": "string",
                "description": (
                    "A self-contained restatement of what the user wants, including "
                    "anything you already learned this turn. The escalation model "
                    "starts from this."
                ),
            },
        },
        "required": ["reason", "summary"],
    },
}


def escalate_tool_schema() -> dict:
    """The ``escalate`` tool schema (a copy — callers may mutate)."""
    return json.loads(json.dumps(ESCALATE_TOOL_SCHEMA))


def _escalate_available() -> bool:
    """check_fn: the tool only exists when a fast lane is actually configured."""
    try:
        return fast_lane_active() and escalation_active()
    except Exception:
        return False


# ── per-turn context binding ─────────────────────────────────────────────────
# The registry hands tool handlers ``(args, task_id=...)`` — no agent. The agent
# loop binds what an escalation needs (session id, the turn's messages, the
# runner) against the task id before dispatching tools, and clears it after.

def bind_turn_context(task_id: str, **context: Any) -> None:
    if not task_id:
        return
    with _lock:
        _turn_context[task_id] = dict(context)


def get_turn_context(task_id: Optional[str]) -> Optional[Dict[str, Any]]:
    if not task_id:
        return None
    with _lock:
        ctx = _turn_context.get(task_id)
        return dict(ctx) if ctx else None


def clear_turn_context(task_id: Optional[str]) -> None:
    if not task_id:
        return
    with _lock:
        _turn_context.pop(task_id, None)


def handle_escalate(args: dict, task_id: Optional[str] = None, **_kw: Any) -> str:
    """Tool handler: start the background escalation, return immediately.

    The return value is what the FAST model sees as the tool result. It is
    deliberately terse and final — the model must not keep working on the turn.
    """
    args = args or {}
    reason = str(args.get("reason") or "").strip()
    summary = str(args.get("summary") or "").strip()
    ctx = get_turn_context(task_id) or {}
    session_id = ctx.get("session_id")
    if not session_id:
        # No bound turn (CLI one-shot, subagent, a test): nothing can carry the
        # result back, so decline rather than silently dropping the request.
        return json.dumps({
            "escalated": False,
            "error": "No live session to deliver an escalated answer to — "
                     "answer with the tools you have.",
        })
    try:
        job_id = start_escalation(
            session_id=session_id,
            reason=reason,
            summary=summary,
            model=ctx.get("escalation_model"),
            provider=ctx.get("escalation_provider"),
            runner=ctx.get("runner"),
            parent=ctx,
        )
    except Exception as exc:
        logger.warning("escalation could not be started: %s", exc, exc_info=True)
        return json.dumps({"escalated": False, "error": str(exc)})
    return json.dumps({
        "escalated": True,
        "job_id": job_id,
        "note": "Handed off. Give the user a one-line acknowledgement and stop; "
                "the full answer is delivered separately.",
    })


# ── job registry ─────────────────────────────────────────────────────────────

def start_escalation(*, session_id: str, reason: str, summary: str,
                     model: Optional[str] = None,
                     provider: Optional[str] = None,
                     runner: Optional[Callable[[dict], str]] = None,
                     parent: Optional[dict] = None) -> str:
    """Register and start a background escalation job. Returns its job id.

    ``runner(job) -> str`` does the actual model call; it is injectable so the
    webui can supply the real ``_run_agent_streaming`` hand-off and tests can
    supply a fake. When omitted, :func:`default_runner` is used.
    """
    job_id = uuid.uuid4().hex[:12]
    job = {
        "job_id": job_id,
        "session_id": session_id,
        "reason": reason,
        "summary": summary,
        "model": model or resolve_escalation_model(),
        "provider": provider,
        "status": "running",
        "started_at": time.time(),
        "completed_at": None,
        "text": None,
        "parent": dict(parent or {}),
    }
    with _lock:
        _prune_jobs_locked()
        _jobs[job_id] = job

    fn = runner or default_runner
    thread = threading.Thread(
        target=_run_job, args=(job_id, fn), name=f"jc-escalate-{job_id}", daemon=True,
    )
    thread.start()
    logger.info(json.dumps({"turn_id": session_id, "span": "escalation_started",
                            "ms": 0.0}))
    return job_id


def _run_job(job_id: str, runner: Callable[[dict], str]) -> None:
    started = time.time()
    with _lock:
        job = dict(_jobs.get(job_id) or {})
    if not job:
        return
    try:
        text = runner(job)
        text = "" if text is None else str(text)
        status = "done"
    except Exception as exc:
        logger.warning("escalation job %s failed: %s", job_id, exc, exc_info=True)
        text = ("I could not finish that on the bigger model — "
                "ask me again and I'll retry.")
        status = "failed"

    completed = time.time()
    with _lock:
        record = _jobs.get(job_id)
        if record is not None:
            record["status"] = status
            record["text"] = text
            record["completed_at"] = completed
        session_id = (record or job).get("session_id")

    logger.info(json.dumps({
        "turn_id": session_id, "span": "escalation_job",
        "ms": round((completed - started) * 1000.0, 1),
    }))
    deliver(session_id, {"type": ESCALATION_EVENT, "job_id": job_id, "text": text})


def default_runner(job: dict) -> str:
    """Re-run the turn on the escalation model with the FULL toolset.

    Mirrors ``webui/api/routes._handle_background``: a hidden session pinned to
    the escalation model, run through the normal streaming worker, then the last
    assistant reply is lifted out. Imported lazily so this module stays usable
    (and testable) outside the webui process.
    """
    from api.models import Session as _Session, new_session as _new_session
    from api.streaming import _run_agent_streaming
    from api.config import STREAMS, STREAMS_LOCK, create_stream_channel

    parent_sid = job["session_id"]
    parent = _Session.load(parent_sid)
    if parent is None:
        raise RuntimeError(f"parent session {parent_sid} is gone")

    hidden = _new_session(
        workspace=parent.workspace,
        model=job["model"],
        model_provider=job.get("provider") or "anthropic",
        profile=getattr(parent, "profile", None),
    )
    hidden.title = f"escalation: {job['reason'][:50]}"
    stream_id = uuid.uuid4().hex
    hidden.active_stream_id = stream_id
    hidden.save()
    with STREAMS_LOCK:
        STREAMS[stream_id] = create_stream_channel()

    prompt = job["summary"] or job["reason"]
    try:
        _run_agent_streaming(
            hidden.session_id, prompt, job["model"], parent.workspace, stream_id,
            None, model_provider=job.get("provider") or "anthropic",
        )
        reloaded = _Session.load(hidden.session_id)
        for message in reversed((reloaded.messages if reloaded else None) or []):
            if not isinstance(message, dict) or message.get("role") != "assistant":
                continue
            if message.get("_error"):
                continue
            content = str(message.get("content") or "").strip()
            if content:
                return content
        return ""
    finally:
        try:
            from api.config import SESSION_DIR
            (SESSION_DIR / f"{hidden.session_id}.json").unlink(missing_ok=True)
        except Exception:
            logger.debug("escalation scratch session cleanup failed", exc_info=True)


def get_job(job_id: str) -> Optional[dict]:
    with _lock:
        job = _jobs.get(job_id)
        return dict(job) if job else None


def get_jobs(session_id: str) -> List[dict]:
    with _lock:
        return [dict(j) for j in _jobs.values() if j["session_id"] == session_id]


def _prune_jobs_locked() -> None:
    cutoff = time.time() - JOB_RETENTION_SECONDS
    stale = [
        jid for jid, job in _jobs.items()
        if job.get("completed_at") and job["completed_at"] < cutoff
    ]
    for jid in stale:
        _jobs.pop(jid, None)


# ── delivery to the session's stream ─────────────────────────────────────────

def register_stream_sink(session_id: str, sink: Callable[[str, dict], None]) -> None:
    """Attach a live stream's event fan-out (``put(event, data)``) to a session.

    Any escalation results buffered while no sink was live are flushed
    immediately — that is how a result from the previous turn reaches the client.
    """
    if not session_id or sink is None:
        return
    with _lock:
        _sinks.setdefault(session_id, []).append(sink)
        buffered = _pending.pop(session_id, [])
    for event, data in buffered:
        _emit(sink, event, data, session_id)


def unregister_stream_sink(session_id: str, sink: Callable[[str, dict], None]) -> None:
    with _lock:
        sinks = _sinks.get(session_id)
        if not sinks:
            return
        try:
            sinks.remove(sink)
        except ValueError:
            pass
        if not sinks:
            _sinks.pop(session_id, None)


def _emit(sink, event: str, data: dict, session_id: str) -> bool:
    try:
        sink(event, data)
        return True
    except Exception:
        logger.debug("escalation sink for %s raised", session_id, exc_info=True)
        return False


def deliver(session_id: Optional[str], data: dict,
            event: str = ESCALATION_EVENT) -> bool:
    """Push an event to the session's live stream, or buffer it for the next one.

    Returns True when at least one live sink accepted it.
    """
    if not session_id:
        return False
    with _lock:
        sinks = list(_sinks.get(session_id) or [])
    delivered = False
    for sink in sinks:
        delivered = _emit(sink, event, data, session_id) or delivered
    if delivered:
        return True
    with _lock:
        queue = _pending.setdefault(session_id, [])
        queue.append((event, data))
        if len(queue) > MAX_PENDING_EVENTS:
            del queue[:-MAX_PENDING_EVENTS]
    return False


def drain_pending(session_id: str) -> List[Tuple[str, dict]]:
    """Pop every buffered event for a session (one-shot)."""
    with _lock:
        return _pending.pop(session_id, [])


def pending_count(session_id: str) -> int:
    with _lock:
        return len(_pending.get(session_id) or [])


def reset_for_tests() -> None:
    with _lock:
        _jobs.clear()
        _sinks.clear()
        _pending.clear()
        _turn_context.clear()


# ── registry wiring ──────────────────────────────────────────────────────────
# ``tools.registry.discover_builtin_tools()`` only walks ``tools/*.py``; this tool
# lives here because it is agent-loop state, not a plain tool. ``tools/lazy_tools``
# imports this module so registration still happens during discovery.
#
# Toolset note: ``lazy_tools`` is used deliberately. It is a plain (non-
# configurable) toolset that the platform-recovery loop always enables — the same
# reason ``tool_search`` lives there — so ``escalate`` reaches every platform
# without needing a new key in ``toolsets.TOOLSETS`` (owned elsewhere). ``check_fn``
# keeps it out of the tool list whenever no fast lane is configured.
def _register() -> None:
    try:
        from tools.registry import registry
        registry.register(
            name=ESCALATION_TOOL_NAME,
            toolset="lazy_tools",
            schema=ESCALATE_TOOL_SCHEMA,
            handler=lambda args, **kw: handle_escalate(args, **kw),
            check_fn=_escalate_available,
            emoji="🚀",
        )
    except Exception:
        logger.debug("escalate tool registration failed", exc_info=True)


_register()
