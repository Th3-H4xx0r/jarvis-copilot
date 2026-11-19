"""IT tasks as Background jobs (agent/it_agent): the chat's "IT agent" card shows the phase and step live,
the code-built report lands in the chat when the run ends, and the PC is held awake for the run."""
from __future__ import annotations

import json
import logging
import re
import time

import api.harness_runner as hr
from agent.it_agent import pc
from agent.it_agent.model import Deps, Run, ScreenResult, activity_line, card_it
from agent.it_agent.report import build_report, log_markdown
from agent.it_agent.settings import fast_ref as _fast_ref, limits as _limits, supervisor_ref as _supervisor_ref
from agent.it_agent.supervisor import run_task

logger = logging.getLogger(__name__)

IT_PARENT = {"kind": "background", "node_id": "it", "node_label": "IT agent"}
_NODE = {"id": "it", "label": "IT agent", "deliver": "notify"}
_TRAIL = 12
_last_key: dict = {}          # job_id → (phase_index, state) last saved on the chat's card
# His own words ask for a job on the PC: an IT verb or the PC itself.
_ASKS_PC = re.compile(r"\b(?:install|uninstall|reinstall|update|upgrade|set\s*up|setup|configure|enable|disable|"
                      r"fix|repair|troubleshoot|diagnose|remove|delete|clean\s*up|pc|computer|laptop|windows)\b", re.I)


# "see if it's installed", "is docker running?", "check whether WSL is set up" — looking, not changing.
_LOOK = re.compile(r"^\s*(?:see|check|verify|confirm|find\s+out|tell\s+me|look)\b|"
                   r"\b(?:see|check|find\s+out|verify|confirm)\s+(?:if|whether|that|what|which|how)\b|"
                   r"^\s*(?:is|are|was|were|did|does|do|has|have)\b.*\?\s*$|"
                   r"\bwhat(?:'s|\s+is)\s+(?:the\s+)?(?:status|version)\b", re.I)
_CHANGE = re.compile(r"\b(?:(?:re|un)?install(?:ing)?|updat(?:e|ing)|upgrad(?:e|ing)|(?<!is\s)(?<!are\s)(?<!was\s)"
                     r"(?<!been\s)(?:set\s*up|setup)|configur(?:e|ing)|enabl(?:e|ing)|disabl(?:e|ing)|fix|repair|remove|"
                     r"delete|clean\s*up|continue|restart|reboot|start|launch|run|turn\s+on|make|get\s+it|sort\s+out|"
                     r"you\s+can|can\s+you|could\s+you|get\s+\w+(?:\s+\w+)?\s+working)\b", re.I)
# "the install", "the update" are things he asks about, not things to do (review: "did the install finish?").
_NOUNS = re.compile(r"\b(?:the|that|this|my|your|its|an?)\s+(?:install(?:ation)?|update|upgrade|set\s*up|setup|fix|"
                    r"repair|restart|reboot)\b", re.I)


def read_only(request_text: str) -> bool:
    """His words only ask to look (live 2026-11-18: "see if it's fully installed now" restarted his PC)."""
    text = str(request_text or "")
    return bool(_LOOK.search(text)) and not _CHANGE.search(_NOUNS.sub(" ", text))


def asked_for_pc(request_text: str, screen_allowed: bool) -> bool:
    """Whether this turn's own words (never text the chat read) ask for something on the PC."""
    return bool(screen_allowed or _ASKS_PC.search(str(request_text or "")))


def supervisor_ref():
    return _supervisor_ref()


def fast_ref():
    return _fast_ref()


def limits():
    return _limits()


def _power():
    from api import mac_power
    return mac_power.store()


def _one_shot(ref: str, prompt: str, max_tokens: int) -> str:
    from api.harness_llm import one_shot_completion
    return one_shot_completion(ref, prompt, max_tokens=max_tokens)


def _dispatch(name: str, args: dict):
    import model_tools  # noqa: F401  (tool discovery)
    from tools.registry import registry
    return registry.dispatch(name, args)


def _parse(raw) -> dict:
    try:
        data = json.loads(raw) if isinstance(raw, str) else raw
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}


def _alert(title: str, body: str, data: dict) -> None:
    from api.push import alert_phones
    alert_phones(title, body, data=data, level="time-sensitive")


def publish_progress(session_id: str, job_id: str, run: Run) -> None:
    """The card follows the run; the chat's stored card is rewritten when the phase or state changes."""
    trail = [{"t": str(e.get("text", "")).split("\n", 1)[0][:120], "tool": e.get("kind", ""),
              "detail": str(e.get("text", ""))[:300], "at": e.get("at")} for e in run.log[-_TRAIL:]]
    card = hr._record_job(session_id, job_id, activity=activity_line(run), steps=run.steps_run, it=card_it(run),
                          trail=trail)
    key = (run.phase_index, run.state)
    if card is not None and _last_key.get(job_id) != key:
        _last_key[job_id] = key
        try:
            hr._persist_card(hr._job_session(job_id, session_id), card)
        except Exception:
            logger.warning("IT job card not saved", exc_info=True)


def _screen_text(look: dict) -> str:
    from agent.computer.choices import element_line
    if not look.get("ok"):
        return ""
    lines = [str(look.get(k) or "") for k in ("app", "title", "text") if look.get(k)]
    lines += [element_line(e) for e in look.get("elements") or [] if isinstance(e, dict)]
    return "\n".join(lines)


def build_deps(job_id: str, session_id: str, run: Run, ref: str) -> Deps:
    did = run.device_id

    def should_stop() -> bool:
        return hr._stop_requested(job_id)

    def ask(purpose: str, prompt: str, max_tokens: int) -> str:
        model = (fast_ref() or ref) if purpose == "fast" else ref
        return _one_shot(model, prompt, max_tokens)

    def search(query: str) -> list:
        web = (_parse(_dispatch("web_search", {"query": query, "limit": 6})).get("data") or {}).get("web") or []
        return [r for r in web if isinstance(r, dict) and r.get("url")]

    def extract(urls: list) -> list:
        return [r for r in _parse(_dispatch("web_extract", {"urls": list(urls)[:5]})).get("results") or []
                if isinstance(r, dict)]

    def screen(goal: str) -> ScreenResult:
        from agent.computer import loop, turns
        res = loop.run(goal, None, turns.config_for(None, ref), device=did, device_name=run.device_name,
                       should_stop=should_stop)
        return ScreenResult(res.status == "done", res.say or "", "" if res.status == "done" else res.reason)

    def read_screen(app: str) -> str:
        from agent.computer import mac
        return _screen_text(mac.look(did, app=app or None))

    return Deps(
        ask=ask, search=search, extract=extract,
        shell=lambda c, t: pc.shell(did, c, t, should_stop),
        admin=lambda c, w, t: pc.admin(did, c, w, t, should_stop),
        approved=lambda c, w, t: pc.approved(did, c, w, t, should_stop),
        screen=screen, read_screen=read_screen,
        online=lambda: pc.online(did), signed_in=lambda: pc.signed_in(did),
        wake=lambda: _power().wake(did),
        notify=lambda title, body: _alert(title, body, {"kind": "it_task", "session_id": session_id,
                                                        "job_id": job_id}),
        progress=lambda r: publish_progress(hr._job_session(job_id, session_id), job_id, r),
        should_stop=should_stop)


def make_runner(session_id: str, goal: str, request_text: str, screen_allowed: bool, ref: str, device_id: str,
                device_name: str, pc_allowed: bool = False, look_only: bool = False, previous: str = ""):
    def _run(job: dict) -> str:
        job_id = job.get("job_id")
        started = time.time()
        run = Run(goal=goal, request_text=request_text, device_id=device_id, device_name=device_name,
                  screen_allowed=screen_allowed and not look_only, pc_allowed=pc_allowed, read_only=look_only,
                  previous=previous)
        # The job view's live stream (his ask 2026-11-18: the expanded chat didn't update until the end).
        feed = hr._open_feed(job_id) if job_id else None
        power, held = None, False
        try:   # hold the PC awake for the run, then put his setting back
            power = _power()
            if not power.device(device_id).get("keep_awake"):
                power.keep_awake(device_id, True)
                held = True
        except Exception:
            logger.warning("IT job couldn't hold the PC awake", exc_info=True)
        try:
            deps = build_deps(job_id, session_id, run, ref)
            if feed is not None:
                deps.feed = feed.add
            run_task(run, deps, limits())
        except Exception as exc:  # run_task reports its own failures; this is the last resort
            logger.exception("IT job %s crashed", job_id)
            run.status, run.end_reason, run.end_detail = "failed", "error", str(exc)
            run.report = build_report(run)
        finally:
            if held:
                try:
                    power.keep_awake(device_id, False)
                except Exception:
                    logger.warning("IT job couldn't restore keep-awake", exc_info=True)
        sid = hr._job_session(job_id, session_id)
        hr.deliver_result(sid, node={**_NODE, "model": ref}, kind="background", text=run.report,
                          ms=(time.time() - started) * 1000,
                          error=None if run.status == "done" else (run.end_reason or run.status))
        hr._save_transcript(job_id, sid, run.goal, [{"role": "assistant", "content": log_markdown(run)}])
        if feed is not None:   # after the transcript: a viewer re-reading the job then gets the whole log
            feed.add("done", {})
            feed.close()
        hr._finish_job(sid, job_id, {"done": "done", "stopped": "stopped"}.get(run.status, "failed"),
                       result=run.report)
        _last_key.pop(job_id, None)
        return ""
    return _run


def _attach_to_parent_reply(session_id: str, job_id: str) -> None:
    """A Background worker started it: no turn of the chat will attach its card, so put it on the chat's
    last reply now."""
    from agent import escalation
    try:
        session = hr._load_session(session_id)
        reply = next((m for m in reversed(getattr(session, "messages", None) or [])
                      if isinstance(m, dict) and m.get("role") == "assistant"), None)
        job = escalation.get_job(job_id)
        if session is not None and reply is not None and job:
            hr.attach_job_cards(session, reply, [hr.job_card(job)])
    except Exception:
        logger.warning("IT job card not attached", exc_info=True)


PREVIOUS_MAX_AGE_S = 3 * 3600


def _previous_report(device_id: str) -> str:
    """The report of the last IT run on this PC, when it ended under 3 hours ago ("continue" builds on it)."""
    from agent import escalation
    now = time.time()
    with escalation._lock:
        ended = [j for j in escalation._jobs.values()
                 if j.get("reason") == "it_task" and j.get("device_id") == device_id and j.get("status") != "running"
                 and j.get("result") and now - float(j.get("completed_at") or 0) <= PREVIOUS_MAX_AGE_S]
    newest = max(ended, key=lambda j: float(j.get("completed_at") or 0), default=None)
    return str(newest.get("result") or "")[:4000] if newest else ""


def _running_on(device_id: str) -> str:
    """The summary of an IT job still running on this PC, or ''."""
    from agent import escalation
    with escalation._lock:
        for job in escalation._jobs.values():
            if (job.get("reason") == "it_task" and job.get("status") == "running"
                    and job.get("device_id") == device_id):
                return str(job.get("summary") or "a job")[:80]
    return ""


def start_it_job(task_id: str, goal: str) -> dict:
    from agent import escalation, mac_browser_gate
    sid = str(task_id or "").split("~", 1)[0]
    goal = " ".join(str(goal or "").split())
    if not sid or not goal:
        return {"ok": False, "error": "it_task needs a goal."}
    ref, error = supervisor_ref()
    if not ref:
        return {"ok": False, "error": error}
    request_text = mac_browser_gate.turn_text(task_id)
    screen_allowed = bool(mac_browser_gate.allowed(task_id))
    device_id, device_name, error = pc.find_pc(f"{goal} {request_text}")
    if not device_id:
        return {"ok": False, "error": error}
    looking = read_only(request_text)   # his words only ask to look: the plan may only inspect
    busy = _running_on(device_id)
    if busy:
        # Live 2026-11-18: two runs on one PC — the second acted the moment the PC woke.
        return {"ok": False, "error": f"An IT job is already running on {device_name} ({busy}). It has a Stop "
                                      "button on its card; start this one after it finishes."}
    job_id = escalation.start_escalation(
        session_id=sid, reason="it_task", summary=goal, model=ref,
        runner=make_runner(sid, goal, request_text, screen_allowed, ref, device_id, device_name,
                           pc_allowed=asked_for_pc(request_text, screen_allowed), look_only=looking,
                           previous=_previous_report(device_id)),
        parent={**IT_PARENT, "question": request_text or goal}, origin=hr.job_origin(sid, "chat"))
    escalation.update_job(job_id, device_id=device_id)
    if "~" in str(task_id):
        _attach_to_parent_reply(sid, job_id)
    return {"ok": True, "job_id": job_id, "device_name": device_name}
