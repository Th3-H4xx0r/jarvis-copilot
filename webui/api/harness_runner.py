"""Harness runner: which node answers this turn, and what runs after it.

``resolve_harness`` picks the harness (the turn's requested one, else the
chat's own, else the surface default; an old client's explicit model runs
as Single). ``plan_turn`` walks the graph from the Message node through any
Route nodes to the Answer node the user waits on, and lists the Background /
Review nodes wired to run after it.
"""
from __future__ import annotations

import logging
import re
import threading
from dataclasses import dataclass, field

from api.harness_schema import parse_when, validate_harness

logger = logging.getLogger(__name__)
SESSION_MODEL = "@session"


def single_harness() -> dict:
    from api.harness_builtins import builtin_harnesses
    return next(b for b in builtin_harnesses(SESSION_MODEL) if b["id"] == "single")


@dataclass
class TurnPlan:
    harness_id: str
    harness_name: str
    node_id: str
    model: str
    provider: str | None
    tools: object = "lean"
    instructions: str = ""
    max_steps: int | None = None
    fallback_model: str | None = None
    handoff_node: dict | None = None
    after: list = field(default_factory=list)
    note: str | None = None
    surface: str = "chat"

    def cache_key(self, session_id: str) -> str:
        """Each node keeps its own warm agent (and so its own prompt cache)."""
        if self.harness_id == "single":
            return session_id
        return f"{session_id}#{self.harness_id}:{self.node_id}"

    def meta(self) -> dict:
        return {"harness": self.harness_id, "harness_name": self.harness_name, "node": self.node_id,
                "model": self.model, "provider": self.provider, "kind": "answer", "note": self.note}


def _model_and_provider(ref, session_model, session_provider):
    if not ref or ref == SESSION_MODEL:
        return session_model, session_provider
    from api.config import split_provider_qualified_model
    q = split_provider_qualified_model(ref)
    return (ref, q[0]) if q else (ref, None)


def resolve_harness(store, *, session, surface, requested_id, explicit_model):
    """Return ``(doc, note)``; ``note`` explains a fallback to Single."""
    if requested_id:
        hid = requested_id
    elif explicit_model:
        return single_harness(), None
    else:
        hid = getattr(session, "harness_id", None) or store.get_assignments().get(surface) or "single"
    doc = store.get(hid)
    if doc is None:
        return single_harness(), f"harness '{hid}' not found; ran Single model"
    errors = validate_harness(doc)[1]
    if errors:
        return single_harness(), f"harness '{hid}' is invalid ({errors[0]['message']}); ran Single model"
    return doc, None


def _rule_matches(rule, text, surface, has_attachments):
    match, value = rule.get("match"), rule.get("value")
    if match == "keywords":
        low = (text or "").lower()
        words = (w.strip().lower() for w in str(value or "").split(","))
        return any(re.search(rf"\b{re.escape(w)}\b", low) for w in words if w)
    if match == "regex":
        try:
            return re.search(str(value or ""), text or "", re.I) is not None
        except re.error:
            return False
    if match == "surface":
        return str(value or "").strip().lower() == (surface or "")
    if match == "has_attachment":
        return bool(has_attachments) == (True if value is None else bool(value))
    return False


def classify_with_model(model_ref, labels, text, timeout=1.5):
    """One tiny call that answers with one of ``labels`` (or nothing).
    Never raises; a slow or failing model just means "no label"."""
    result = {}

    def _run():
        try:
            from api.harness_llm import one_shot_completion
            prompt = ("Label the user's message with exactly one of: " + ", ".join(labels)
                      + ", none. Reply with the label only.\n\nMessage: " + (text or "")[:1500])
            out = (one_shot_completion(model_ref, prompt, max_tokens=8) or "").strip().strip(" .\"'").lower()
            result["label"] = next((l for l in labels if l.lower() == out), None)
        except Exception:
            logger.debug("harness: model route failed", exc_info=True)

    t = threading.Thread(target=_run, daemon=True, name="jc-harness-route")
    t.start()
    t.join(timeout)
    return result.get("label")


def plan_turn(doc, *, session_model, session_provider, text, surface, has_attachments, classify=None):
    nodes = {n["id"]: n for n in doc["nodes"]}
    out = {}
    for e in doc["edges"]:
        out.setdefault(e["from"], []).append(e)
    nid = next(n["id"] for n in doc["nodes"] if n["type"] == "message")
    hops = 0
    while nodes[nid]["type"] != "answer" and hops < len(nodes):
        hops += 1
        node, edges = nodes[nid], out.get(nid, [])
        if node["type"] == "route":
            if node.get("by") == "model":
                label = (classify or classify_with_model)(node.get("model"), node.get("labels") or [], text)
            else:
                label = next((r["label"] for r in node.get("rules") or []
                              if _rule_matches(r, text, surface, has_attachments)), None)
            chosen = (next((e for e in edges if label and e["when"] == f"label:{label}"), None)
                      or next(e for e in edges if e["when"] == "default"))
            nid = chosen["to"]
        else:
            nid = edges[0]["to"]
    answer = nodes[nid]
    model, provider = _model_and_provider(answer.get("model"), session_model, session_provider)
    handoff = next((nodes[e["to"]] for e in out.get(nid, []) if e["when"] == "handoff"), None)
    after = [(nodes[e["to"]], e["when"]) for e in out.get(nid, [])
             if parse_when(e["when"])[0] in ("always", "slow", "tools")
             and nodes[e["to"]]["type"] in ("background", "review")]
    return TurnPlan(harness_id=doc["id"], harness_name=doc.get("name") or doc["id"], node_id=nid,
                    model=model, provider=provider, tools=answer.get("tools", "lean"),
                    instructions=answer.get("instructions", ""), max_steps=answer.get("max_steps"),
                    fallback_model=answer.get("fallback_model"), handoff_node=handoff, after=after,
                    surface=surface)


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


def deliver_result(session_id, *, node, kind, text, ms, error=None):
    """Save a background/review result into the chat and tell the devices."""
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
    if node.get("deliver") in ("speak_or_notify", "notify") and _listener_count(session_id) == 0:
        try:
            _push_alert(f"{_label_for(node)} {'finished' if not error else 'could not finish'}",
                        text or str(error or ""), session_id)
        except Exception:
            logger.warning("harness push failed", exc_info=True)
    return message


def _run_hidden_turn(node, session_id, summary):
    """The node's model with the parent chat's full history, on a throwaway session."""
    import uuid as _uuid
    from api.config import (SESSION_DIR, STREAMS, STREAMS_LOCK, create_stream_channel,
                            split_provider_qualified_model)
    from api.models import Session, new_session
    from api.streaming import _run_agent_streaming
    parent = Session.load(session_id)
    q = split_provider_qualified_model(node.get("model") or "")
    model, provider = node.get("model"), (q[0] if q else None)
    hidden = new_session(workspace=parent.workspace, model=model, model_provider=provider,
                         profile=getattr(parent, "profile", None))
    hidden.title = f"harness: {node.get('id')}"
    hidden.messages = _copy.deepcopy(getattr(parent, "messages", None) or [])
    copied = len(hidden.messages)
    stream_id = _uuid.uuid4().hex
    hidden.active_stream_id = stream_id
    hidden._turn_node_override = node   # its own tools + instructions, not Single's
    hidden.save()
    with STREAMS_LOCK:
        STREAMS[stream_id] = create_stream_channel()
    prompt = ("A faster model handed this over to you. Finish it fully with your tools, then reply "
              f"with the final answer for the user.\n\nHand-off note: {summary}")
    try:
        _run_agent_streaming(hidden.session_id, prompt, model, parent.workspace, stream_id, None,
                             model_provider=provider)
        reloaded = Session.load(hidden.session_id)
        # Only this run's messages: the copied history ends with the parent's
        # previous answer, which must never come back as this node's reply.
        added = ((reloaded.messages if reloaded else None) or [])[copied:]
        for m in reversed(added):
            if isinstance(m, dict) and m.get("role") == "assistant":
                content = str(m.get("content") or "").strip()
                if m.get("_error"):
                    raise RuntimeError(content or "the hand-off model failed")
                if content:
                    return content
        return ""
    finally:
        try:
            (SESSION_DIR / f"{hidden.session_id}.json").unlink(missing_ok=True)
        except Exception:
            pass
        # Nothing of the throwaway session may linger: its cached agent, its
        # in-memory row (it would show in the sidebar), its stream channel.
        try:
            from api.config import LOCK as _LOCK, SESSIONS as _SESSIONS, evict_session_agents
            evict_session_agents(hidden.session_id)
            with _LOCK:
                _SESSIONS.pop(hidden.session_id, None)
            with STREAMS_LOCK:
                STREAMS.pop(stream_id, None)
        except Exception:
            logger.debug("hidden harness session cleanup failed", exc_info=True)


def background_runner(node, session_id):
    def _run(job):
        started = _time.time()
        try:
            text = _run_hidden_turn(node, session_id, job.get("summary") or job.get("reason") or "")
            deliver_result(session_id, node=node, kind="background", text=text,
                           ms=(_time.time() - started) * 1000)
        except Exception as exc:
            logger.warning("harness background node %s failed", node.get("id"), exc_info=True)
            text = f"Couldn't finish: {exc}"
            deliver_result(session_id, node=node, kind="background", text=text,
                           ms=(_time.time() - started) * 1000, error=exc)
        # Returned text is what an open voice socket speaks.
        return text if node.get("deliver") == "speak_or_notify" else ""
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


def _start_job(session_id, node, runner):
    from agent import escalation
    return escalation.start_escalation(session_id=session_id, reason=f"harness:{node.get('id')}",
                                       summary="", model=node.get("model"), runner=runner)


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
        ids.append(_start_job(session_id, node, runner))
    return ids
