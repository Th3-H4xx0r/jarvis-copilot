"""The IT agent's supervisor: research (always) → a code-checked plan → phases, each proven by a check →
capped rethinks → an honest report. Code owns the skeleton; the model only fills in content. The run is never
"done" unless every phase's check passed (or it was a question answered by research)."""
from __future__ import annotations

import json
import logging

from agent.it_agent.executor import needs_face_id, run_check, run_step
from agent.it_agent.handover import past_limits
from agent.it_agent.model import FACTS_SCRIPT, Deps, Limits, Phase, PlanError, Run, Step
from agent.it_agent.plans import ask_json, parse_plan, parse_rethink
from agent.it_agent.prompts import plan_prompt, rethink_prompt
from agent.it_agent.report import build_report
from agent.it_agent.research import research
from agent.it_agent.waits import RESTART_COMMAND, restart_and_wait, wait_for_pc

logger = logging.getLogger(__name__)
_RESTART_END = {"denied": "restart_declined", "approval_timeout": "approval_timeout", "timeout": "signin_timeout"}


class _End(Exception):
    def __init__(self, status: str, reason: str, detail: str = ""):
        super().__init__(reason)
        self.status, self.reason, self.detail = status, reason, detail


def _set(run: Run, deps: Deps, state: str, label: str | None = None) -> None:
    run.state = state
    if label is not None:
        run.step_label = label
    deps.progress(run)


def _stop_check(deps: Deps) -> None:
    if deps.should_stop():
        raise _End("stopped", "stopped")


def _label(step: Step) -> str:
    text = " ".join(str(step.command if step.kind in ("shell", "admin") else step.goal).split())
    return text if len(text) <= 80 else text[:79] + "…"


def _log_step(run: Run, step: Step, res) -> None:
    what = step.command if step.kind in ("shell", "admin") else step.goal
    code = f" (exit {res.exit_code})" if res.exit_code is not None else ""
    why = f" — {res.detail}" if res.detail and not res.ok else ""
    tail = (res.output or "")[-1500:].strip()
    run.add_log("step", f"{step.kind}: {what[:300]} → {res.status}{code}{why}" + (f"\n{tail}" if tail else ""))


def _wait_back(run: Run, deps: Deps, limits: Limits) -> None:
    out = wait_for_pc(run, deps, limits.offline_wait_minutes)
    if out.status == "stopped":
        raise _End("stopped", "stopped")
    if out.status != "back":
        raise _End("failed", "pc_offline", str(limits.offline_wait_minutes))


def _do_phase(run: Run, phase: Phase, deps: Deps, limits: Limits):
    """None when the phase's check passed; otherwise the failure detail (for the rethink)."""
    phase.status, phase.detail = "running", ""
    restart = phase.restart_after
    for j, step in enumerate(phase.steps, 1):
        _stop_check(deps)
        label = _label(step)
        face = needs_face_id(step, run.request_text)
        _set(run, deps, "approval" if face else "working", label)
        res = run_step(step, run, deps)
        run.steps_run += 1
        _log_step(run, step, res)
        if run.state == "approval":
            _set(run, deps, "working", label)
        if res.status == "denied":
            raise _End("failed", "approval_denied", step.command)
        if res.status == "approval_timeout":
            raise _End("failed", "approval_timeout", step.command)
        if res.status == "stopped":
            raise _End("stopped", "stopped")
        if face and res.status == "error":   # the approval/admin path itself is down: no plan can fix that
            raise _End("failed", "admin_unavailable", res.detail or "the admin path didn't answer")
        if res.status == "offline":
            _wait_back(run, deps, limits)
            break                      # straight to the check; the step isn't re-run
        if not res.ok:
            phase.status, phase.detail = "failed", f"step {j} failed: {res.detail or res.status}"
            return phase.detail
        restart = restart or res.restart_needed
    if restart:
        out = restart_and_wait(run, deps, limits, phase.name)
        if out.status == "stopped":
            raise _End("stopped", "stopped")
        if out.status in _RESTART_END:
            detail = {"approval_timeout": RESTART_COMMAND, "timeout": str(limits.reboot_wait_minutes)}.get(out.status, "")
            raise _End("failed", _RESTART_END[out.status], detail)
        if out.status != "back":
            phase.status, phase.detail = "failed", f"the restart didn't happen: {out.detail or out.status}"
            return phase.detail
    _stop_check(deps)
    _set(run, deps, "checking", "")
    chk = run_check(phase.check, deps, limits.settle_s)
    if not chk.passed and deps.should_stop():
        raise _End("stopped", "stopped")
    if not chk.passed and chk.detail == "PC offline":
        _wait_back(run, deps, limits)
        _set(run, deps, "checking", "")
        chk = run_check(phase.check, deps, limits.settle_s)
    run.add_log("check", f"{phase.name}: {'passed' if chk.passed else chk.detail}"
                + (f"\n{chk.output[-1500:].strip()}" if chk.output and chk.output.strip() else ""))
    if chk.passed:
        phase.status = "passed"
        deps.progress(run)
        return None
    phase.status, phase.detail = "failed", f"check failed: {chk.detail}"
    return chk.detail


def _drive(run: Run, deps: Deps, limits: Limits) -> None:
    _set(run, deps, "researching")
    if deps.online():
        res = deps.shell(FACTS_SCRIPT, 60)
        try:
            facts = json.loads(res.output) if res.status == "ran" else {}
        except (TypeError, ValueError):
            facts = {}
        run.facts = facts if isinstance(facts, dict) else {}
    try:
        run.brief = research(run.goal, run.facts, deps)
    except PlanError as exc:
        raise _End("failed", "error", f"I couldn't write the research brief ({exc})") from None
    run.add_log("research", f"{len(run.brief.sources)} sources read · route: {run.brief.route}")
    deps.progress(run)
    if run.brief.research_only:
        if not past_limits(run.goal):
            raise _End("done", "research_only")
        run.add_log("research", "the brief said research-only, but this is a job on the PC: planning it")
    if not run.pc_allowed:
        raise _End("failed", "not_asked")
    _set(run, deps, "planning")
    try:
        run.phases = ask_json(deps.ask, "plan", plan_prompt(run.goal, run.brief, run.facts, run.screen_allowed),
                              parse_plan, max_tokens=4000)
    except PlanError as exc:
        raise _End("failed", "plan_failed", str(exc)) from None
    if not deps.online():
        _wait_back(run, deps, limits)
    while run.phase_index < len(run.phases):
        failure = _do_phase(run, run.phases[run.phase_index], deps, limits)
        if failure is None:
            run.phase_index += 1
            run.phase_rethinks = 0
            continue
        if run.phase_rethinks >= limits.max_rethinks or run.rethinks >= limits.max_total_rethinks:
            raise _End("failed", "check_failed", failure)
        run.rethinks += 1
        run.phase_rethinks += 1
        _set(run, deps, "rethinking")
        try:
            new = ask_json(deps.ask, "plan", rethink_prompt(run, failure), parse_rethink, max_tokens=4000)
        except PlanError as exc:
            raise _End("failed", "plan_failed", str(exc)) from None
        if isinstance(new, str):
            raise _End("failed", "gave_up", new)
        run.add_log("rethink", f"rethink {run.rethinks}: {len(new)} new phases after: {failure}")
        failed = run.phases[run.phase_index]
        if not any(p.check == failed.check for p in new):
            # The check that failed still has to pass: new phases can't swap it for an easier one.
            name = failed.name if failed.name.startswith("Re-check: ") else f"Re-check: {failed.name}"
            new = list(new) + [Phase(name=name, steps=[], check=failed.check)]
        run.phases = run.phases[:run.phase_index] + new
    raise _End("done", "checks_passed")


def run_task(run: Run, deps: Deps, limits: Limits) -> Run:
    try:
        _drive(run, deps, limits)
    except _End as end:
        run.status, run.end_reason, run.end_detail = end.status, end.reason, end.detail
    except Exception as exc:  # a crash still ends with an honest report, never a silent job
        logger.exception("it_agent: run crashed")
        run.status, run.end_reason, run.end_detail = "failed", "error", f"{type(exc).__name__}: {exc}"
    if run.status == "done" and not (run.all_checks_passed() or run.end_reason == "research_only"):
        run.status, run.end_reason = "failed", "check_failed"   # the invariant: never a false "done"
    _set(run, deps, "reporting")
    run.report = build_report(run)
    deps.progress(run)
    return run
