"""The messaging gateway (Telegram, Photon/iMessage, …) runs the one default harness.

Each message is planned through the shared core planner (agent/harness/planner.py,
the one schedules use too): a Route picks the Answer node, whose model, tool
limit, notes and step budget run the turn. A wired hand-off, or a Background node
after the answer, runs on a background thread here and its result is posted to
the same chat as a follow-up message. Review nodes are not run on messaging.

Anything that can't be planned — a Single default, a /model override on the
chat, a missing or invalid harness, no credentials for the node's provider —
runs the default model exactly as before.
"""
from __future__ import annotations

import logging
import threading
from dataclasses import dataclass
from typing import Callable, List, Optional

logger = logging.getLogger(__name__)

# What the fast node is told when a bigger node is wired behind it (the tool's
# description alone isn't enough: small models never call it unprompted).
HANDOFF_RULE = (
    "You are the quick first responder; a bigger model works behind you. Call "
    "`handoff` straight away, before any other tool, when the request needs several "
    "steps, creates or changes something, needs research or a long answer, or you are "
    "not sure how to do it. Answer yourself only quick questions and single simple "
    "actions. After handing off, tell the user in one line that you're on it.")

FAILED_NOTE = "I couldn't finish that in the background — ask me again and I'll retry."


@dataclass
class MessagePlan:
    harness_id: str
    harness_name: str
    plan: object          # agent.harness.planner.TurnPlan
    model: str            # bare model name
    provider: Optional[str]
    runtime: Optional[dict]  # credentials when the node's provider isn't the chat's


def _split(ref, provider=None):
    """``"@provider:model"`` → ``(model, provider)``, routed the way schedules route
    a subscription Anthropic pick (through Claude Code when it is installed)."""
    from agent.harness.refs import route_anthropic_via_claude_code, split_ref

    q = split_ref(ref) if isinstance(ref, str) else None
    model, provider = (q[1], q[0]) if q else (ref, provider)
    model, provider, _ = route_anthropic_via_claude_code(model, provider, None)
    return model, provider


def _runtime_for(provider: str) -> dict:
    """Credentials for a node's provider, in the gateway's runtime-kwargs shape."""
    from jarviscopilot_cli.runtime_provider import resolve_runtime_provider

    rt = resolve_runtime_provider(requested=provider)
    return {"api_key": rt.get("api_key"), "base_url": rt.get("base_url"), "provider": rt.get("provider"),
            "api_mode": rt.get("api_mode"), "command": rt.get("command"), "args": list(rt.get("args") or []),
            "credential_pool": rt.get("credential_pool")}


def plan_message(text, *, session_model, session_provider, has_session_override) -> Optional[MessagePlan]:
    """The default harness's plan for this message, or None to run the default model."""
    if has_session_override:
        return None
    try:
        from agent.harness.planner import plan_turn
        from agent.harness.schema import validate_harness
        from agent.harness.store import store_for_home

        store = store_for_home()
        hid = store.effective("messaging")
        if hid == "single":
            return None
        doc = store.get(hid)
        if doc is None or validate_harness(doc, strict=False)[1]:
            logger.warning("Messaging: the default harness %r is missing or invalid; ran the default model", hid)
            return None
        plan = plan_turn(doc, session_model=session_model, session_provider=session_provider,
                         text=text or "", surface="messaging", has_attachments=False)
        model, provider = _split(plan.model, plan.provider)
        runtime = _runtime_for(provider) if provider and provider != session_provider else None
        return MessagePlan(hid, str(doc.get("name") or hid), plan, model, provider, runtime)
    except Exception as exc:
        logger.warning("Messaging: harness planning failed (%s); ran the default model", exc)
        return None


def _attach_handoff_tool(agent) -> None:
    """The ``handoff`` tool on this agent (gateway toolsets don't carry it)."""
    import importlib

    importlib.import_module("agent.escalation")  # registers `handoff`
    from tools.registry import registry

    tools = list(getattr(agent, "tools", None) or [])
    names = {(t.get("function") or {}).get("name") for t in tools if isinstance(t, dict)}
    if "handoff" not in names:
        tools += list(registry.get_definitions({"handoff"}) or [])
        try:
            from agent.tool_policy import canonical_tools
            tools = canonical_tools(tools)
        except Exception:
            pass
        agent.tools = tools
    agent.valid_tool_names = set(getattr(agent, "valid_tool_names", None) or set()) | {"handoff"}


def apply_node(agent, mp: MessagePlan, *, task_id: str, deliver: Callable[[str], None], platform: str,
               question: str, toolsets) -> None:
    """This turn's node on the (possibly cached) agent: its tool limit, notes and
    step budget, and — when a bigger node is wired behind it — the hand-off."""
    from agent.tool_policy import node_tool_policy

    plan = mp.plan
    if getattr(agent, "_jc_harness_node", None) is None:
        # The agent's own limits, saved once, before any node changes them.
        agent._jc_harness_node = {"max_iterations": getattr(agent, "max_iterations", None)}
    own_steps = agent._jc_harness_node.get("max_iterations")
    allowed, note = node_tool_policy(plan.tools)
    agent.allowed_tool_names = allowed
    notes = [plan.instructions or "", note or ""]
    agent.max_iterations = int(plan.max_steps) if plan.max_steps else own_steps
    agent._computer_node = getattr(plan, "computer", None)
    agent._computer_first = bool(getattr(plan, "computer_first", False))
    node = plan.handoff_node
    agent._handoff_wired = bool(node)
    if node:
        from agent import escalation

        _attach_handoff_tool(agent)
        if agent.allowed_tool_names is not None:
            agent.allowed_tool_names = frozenset(agent.allowed_tool_names) | {"handoff"}
        chat_tools = list(toolsets) if toolsets else None

        def runner(job: dict) -> str:
            try:
                text = _run_background_node(node, str(job.get("summary") or job.get("reason") or ""),
                                            platform=platform, toolsets=chat_tools)
            except Exception:
                logger.warning("Messaging: hand-off to %s failed", node.get("id"), exc_info=True)
                text = FAILED_NOTE
            if text and text.strip():
                deliver(text)
            return ""  # delivered here; nothing for escalation to queue

        escalation.bind_turn_context(
            task_id, session_id=task_id, runner=runner, escalation_model=node.get("model"),
            question=question or "", auto_handoff_after=escalation.AUTO_HANDOFF_AFTER,
            node_id=node.get("id") or "", node_label=node.get("label") or node.get("id") or "",
            kind=node.get("type") or "")
        notes.append(HANDOFF_RULE)
    agent._turn_user_context = "\n\n".join(
        p.strip() for p in [getattr(agent, "_turn_user_context", "") or ""] + notes if p and p.strip())


def clear_node(agent) -> None:
    """A turn without a plan on an agent a planned turn used: drop that node's limits."""
    saved = getattr(agent, "_jc_harness_node", None)
    if saved is None:
        return
    agent.allowed_tool_names = None
    if saved.get("max_iterations"):
        agent.max_iterations = saved["max_iterations"]
    agent._handoff_wired = False
    agent._computer_node = None
    agent._computer_first = False
    agent._jc_harness_node = None


def _run_background_node(node: dict, prompt: str, *, platform: str, toolsets) -> str:
    """Run a Background node's model on ``prompt`` with the chat's tools; its reply.
    Nobody is there to approve a dangerous command, so those are refused."""
    from run_agent import AIAgent
    from tools.approval import unattended_run

    model, provider = _split(node.get("model"))
    runtime = _runtime_for(provider) if provider else {}
    agent = AIAgent(model=model, **runtime, max_iterations=int(node.get("max_steps") or 90),
                    quiet_mode=True, verbose_logging=False, enabled_toolsets=toolsets,
                    platform=platform, skip_memory=True)
    instructions = str(node.get("instructions") or "").strip()
    with unattended_run():
        return str(agent.chat(f"{instructions}\n\n{prompt}" if instructions else prompt) or "").strip()


def after_turn(mp: MessagePlan, *, task_id: str, question: str, answer: str, elapsed_s: float,
               tool_count: int, deliver: Callable[[str], None], platform: str,
               toolsets) -> List[threading.Thread]:
    """Start the Background nodes wired after the answer whose condition holds;
    each posts its result as a follow-up. Returns the threads started."""
    from agent.harness.planner import after_condition_holds

    chat_tools = list(toolsets) if toolsets else None
    started = []
    for node, when in getattr(mp.plan, "after", None) or []:
        if not after_condition_holds(when, elapsed_s=elapsed_s, tool_count=tool_count):
            continue
        if node.get("type") != "background":
            logger.info("Messaging: %s node %s skipped (not run on messaging)", node.get("type"), node.get("id"))
            continue
        prompt = (f"The user asked: {question}\n\nThe first answer was: {answer}\n\n"
                  "Finish the task fully and reply with the complete answer for the user.")

        def work(node=node, prompt=prompt):
            try:
                text = _run_background_node(node, prompt, platform=platform, toolsets=chat_tools)
            except Exception:
                logger.warning("Messaging: background node %s failed", node.get("id"), exc_info=True)
                text = FAILED_NOTE
            if text:
                deliver(text)

        t = threading.Thread(target=work, name=f"jc-msg-after-{node.get('id')}", daemon=True)
        t.start()
        started.append(t)
    return started


def release(task_id: Optional[str]) -> None:
    """Drop the turn's hand-off binding (a hand-off already started keeps running)."""
    if not task_id:
        return
    try:
        from agent import escalation
        escalation.clear_turn_context(task_id)
    except Exception:
        logger.debug("Messaging: hand-off unbind failed", exc_info=True)
