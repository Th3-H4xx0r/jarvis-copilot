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
