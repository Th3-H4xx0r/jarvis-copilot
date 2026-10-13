"""Harness planner: which node answers this turn, and what runs after it.

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
import time
from dataclasses import dataclass, field

from agent.harness.refs import split_ref
from agent.harness.schema import parse_when, validate_harness

logger = logging.getLogger(__name__)
SESSION_MODEL = "@session"


def single_harness() -> dict:
    from agent.harness.builtins import builtin_harnesses
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
    route: dict | None = None
    # The Computer node this turn's computer_do uses; computer_first when a Route
    # sent the turn to it (its fast loop runs before the Answer node's model).
    computer: dict | None = None
    computer_first: bool = False

    def cache_key(self, session_id: str) -> str:
        """Each node keeps its own warm agent (and so its own prompt cache)."""
        if self.harness_id == "single":
            return session_id
        return f"{session_id}#{self.harness_id}:{self.node_id}"

    def meta(self) -> dict:
        out = {"harness": self.harness_id, "harness_name": self.harness_name, "node": self.node_id,
               "model": self.model, "provider": self.provider, "kind": "answer", "note": self.note}
        if self.route:
            out["route"] = self.route
        return out


def _model_and_provider(ref, session_model, session_provider):
    if not ref or ref == SESSION_MODEL:
        return session_model, session_provider
    q = split_ref(ref)
    return (ref, q[0]) if q else (ref, None)


def resolve_harness(store, *, session, surface, requested_id, explicit_model):
    """Return ``(doc, note)``; ``note`` explains a fallback to Single."""
    if requested_id:
        hid = requested_id
    elif explicit_model:
        return single_harness(), None
    else:
        hid = getattr(session, "harness_id", None) or store.effective(surface)
    doc = store.get(hid)
    if doc is None:
        return single_harness(), f"harness '{hid}' not found; ran Single model"
    errors = validate_harness(doc, strict=False)[1]
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


_NONE = "none"
_NONE_NOTE = "None of the other routes fit."
_ROUTE_QUESTION = "Which route should handle the user's message?"


@dataclass
class RouteDecision:
    """What a Route node picked; ``label`` None means the default wire."""
    label: str | None
    by: str  # rules · model · decision
    model: str | None = None
    confidence: float | None = None
    ms: int = 0
    error: str | None = None


def _route_choices(node):
    """``[(label, description|None)]`` (unique) plus a "none" option (→ default wire)."""
    labels = list(dict.fromkeys(node.get("labels") or []))
    notes = node.get("label_descriptions") or {}
    out = [(l, notes.get(l) or None) for l in labels]
    if not any(l.lower() == _NONE for l in labels):
        out.append((_NONE, _NONE_NOTE))
    return out


def _route_prompt(node, text):
    lines = [node.get("instructions") or "Pick the route that should handle the user's message.", "", "Routes:"]
    lines += [f"- {v}: {d}" if d else f"- {v}" for v, d in _route_choices(node)]
    lines += ["", "Reply with the route name only.", "", "Message: " + (text or "")[:1500]]
    return "\n".join(lines)


def _parse_label(out, labels):
    """The label a chat model replied with: exact first, else the first label
    named as a whole word; a reply starting "none" means the default wire."""
    o = (out or "").strip().strip(" .\"'`*").lower()
    if o.startswith(_NONE) and not any(l.lower().startswith(_NONE) for l in labels):
        return None
    exact = next((l for l in labels if l.lower() == o), None)
    if exact:
        return exact
    return next((l for l in sorted(labels, key=len, reverse=True)
                 if re.search(rf"\b{re.escape(l.lower())}\b", o)), None)


def classify_with_model(node, text, timeout=1.5, *, one_shot=None):
    """Ask the Route's model which label fits. Never raises; a slow or failing
    router means the default wire, with the reason in ``error``. A decision
    model (Celeris-1 Decision) gets one choice question; a chat model a
    one-line prompt with reasoning off, through ``one_shot`` (default
    ``agent.harness.llm.one_shot_completion``)."""
    ref = str(node.get("model") or "")
    labels = node.get("labels") or []
    try:
        from providers import is_decision_model
        q = split_ref(ref)
        decision = bool(q) and is_decision_model(q[0], q[1])
    except Exception:
        q, decision = None, False
    by = "decision" if decision else "model"
    if not any(l.lower() != _NONE for l in labels):
        return RouteDecision(None, by, ref, error="no labels to pick from")
    result = {}

    def _run():
        try:
            if decision:
                from agent import decision_client
                d = decision_client.choose(
                    q[0], q[1], instructions=node.get("instructions") or _ROUTE_QUESTION,
                    choices=_route_choices(node), text=(text or "")[:4000], timeout=timeout)
                result["label"] = next((l for l in labels if l == d.choice), None)
                result["confidence"] = d.confidence
            else:
                if one_shot is None:
                    from agent.harness.llm import one_shot_completion as _one_shot_fn
                else:
                    _one_shot_fn = one_shot
                out = _one_shot_fn(ref, _route_prompt(node, text), max_tokens=8, reasoning_off=True)
                result["label"] = _parse_label(out, labels)
        except Exception as exc:
            logger.debug("harness: model route failed", exc_info=True)
            result["error"] = str(exc)[:160] or type(exc).__name__

    started = time.monotonic()
    t = threading.Thread(target=_run, daemon=True, name="jc-harness-route")
    t.start()
    t.join(timeout)
    ms = int((time.monotonic() - started) * 1000)
    if t.is_alive():
        return RouteDecision(None, by, ref, None, ms, "timed out")
    return RouteDecision(result.get("label"), by, ref, result.get("confidence"), ms, result.get("error"))


# How long a model Route may take to label a message. A user waiting on a chat
# turn gets the quick default; a schedule has nobody waiting, and its router is a
# cold agent in the gateway, so it gets long enough to actually answer.
ROUTE_TIMEOUTS = {"schedule": 20.0}


def plan_turn(doc, *, session_model, session_provider, text, surface, has_attachments, classify=None):
    nodes = {n["id"]: n for n in doc["nodes"]}
    out = {}
    for e in doc["edges"]:
        out.setdefault(e["from"], []).append(e)
    nid = next(n["id"] for n in doc["nodes"] if n["type"] == "message")
    hops = 0
    route = None
    computer = None
    while nodes[nid]["type"] != "answer" and hops < len(nodes):
        hops += 1
        node, edges = nodes[nid], out.get(nid, [])
        if node["type"] == "computer":
            computer = node
            nid = next(e["to"] for e in edges if e["when"] == "stuck")
        elif node["type"] == "route":
            if node.get("by") == "model":
                if classify is not None:
                    d = classify(node, text)
                elif surface in ROUTE_TIMEOUTS:
                    d = classify_with_model(node, text, timeout=ROUTE_TIMEOUTS[surface])
                else:
                    d = classify_with_model(node, text)
            else:
                d = RouteDecision(next((r["label"] for r in node.get("rules") or []
                                        if _rule_matches(r, text, surface, has_attachments)), None), "rules")
            wired = next((e for e in edges if d.label and e["when"] == f"label:{d.label}"), None)
            chosen = wired or next(e for e in edges if e["when"] == "default")
            route = {"node": node["id"], "label": d.label if wired else "default", "by": d.by,
                     "model": d.model, "confidence": d.confidence, "ms": d.ms, "error": d.error}
            nid = chosen["to"]
        else:
            nid = edges[0]["to"]
    answer = nodes[nid]
    model, provider = _model_and_provider(answer.get("model"), session_model, session_provider)
    handoff = next((nodes[e["to"]] for e in out.get(nid, []) if e["when"] == "handoff"), None)
    after = [(nodes[e["to"]], e["when"]) for e in out.get(nid, [])
             if parse_when(e["when"])[0] in ("always", "slow", "tools")
             and nodes[e["to"]]["type"] in ("background", "review")]
    hands = next((nodes[e["to"]] for e in out.get(nid, []) if e["when"] == "hands"), None)
    return TurnPlan(harness_id=doc["id"], harness_name=doc.get("name") or doc["id"], node_id=nid,
                    model=model, provider=provider, tools=answer.get("tools", "lean"),
                    instructions=answer.get("instructions", ""), max_steps=answer.get("max_steps"),
                    fallback_model=answer.get("fallback_model"), handoff_node=handoff, after=after,
                    surface=surface, route=route, computer=computer or hands,
                    computer_first=computer is not None)


def after_condition_holds(when, *, elapsed_s, tool_count) -> bool:
    """Whether an after-answer wire (always · slow:<s> · tools:<n>) fires."""
    kind, value = parse_when(when)
    if kind == "slow":
        return elapsed_s > int(value)
    if kind == "tools":
        return tool_count > int(value)
    return kind == "always"


def review_prompt(question, answer) -> str:
    """What a Review node is asked about the answer just given."""
    return ("You are reviewing an answer a faster model just gave. Reply ONLY with JSON "
            '{"verdict": "ok" | "fix", "text": "<corrected or fuller answer when fix>"}.\n\n'
            f"Question: {question}\n\nAnswer given: {answer}")


def review_result(node, raw) -> str:
    """The text a Review node posts ('' when nothing): its correction on a
    "fix" verdict, or its text whenever the node delivers ``post``."""
    import json
    try:
        data = json.loads(raw[raw.index("{"):raw.rindex("}") + 1])
    except Exception:
        return ""
    if not isinstance(data, dict):
        return ""
    text = str(data.get("text") or "").strip()
    if text and (data.get("verdict") == "fix" or node.get("deliver") == "post"):
        return text
    return ""
