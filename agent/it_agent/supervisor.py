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
from agent.it_agent.waits import RESTART_COMMAND, restart_and_wait, wait_for_pc, with_face_id_retries

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


# ── the job view's live stream ─────────────────────────────────────────────
_TOOL_NAMES = {"shell": "PowerShell", "admin": "PowerShell (admin · Face ID)", "screen": "Screen",
               "research": "Research"}


def _say(deps: Deps, text: str) -> None:
    try:
        deps.feed("token", {"text": text})
    except Exception:  # noqa: BLE001 — a viewer's stream never breaks the run
        logger.debug("it_agent: feed failed", exc_info=True)


def _tool_start(run: Run, deps: Deps, name: str, args: dict, preview: str) -> str:
    run.feed_seq = getattr(run, "feed_seq", 0) + 1
    tid = f"it-{run.feed_seq}"
    try:
        deps.feed("tool", {"tid": tid, "tool_call_id": tid, "name": name, "args": args, "preview": preview})
    except Exception:  # noqa: BLE001
        logger.debug("it_agent: feed failed", exc_info=True)
    return tid


def _tool_done(deps: Deps, tid: str, name: str, ok: bool, result: str, preview: str, started: float) -> None:
    result = (result or "").strip()[-2500:]
    try:
        if result:
            deps.feed("tool_snippet", {"tool_call_id": tid, "name": name, "snippet": result})
        deps.feed("tool_complete", {"tid": tid, "tool_call_id": tid, "name": name, "is_error": not ok,
                                    "preview": preview, "result": result,
                                    "duration": round(max(0.0, deps.clock() - started), 1)})
    except Exception:  # noqa: BLE001
        logger.debug("it_agent: feed failed", exc_info=True)


def _sig(step: Step) -> str:
    """What makes a step the same step: a longer timeout or newly allowed exit codes is a real retry (review)."""
    what = " ".join(str(step.command if step.kind in ("shell", "admin") else step.goal).split())
    return f"{step.kind}: {what} [timeout {step.timeout_s}s, ok {sorted(step.ok_exit_codes)}]"


def _phase_sig(phase: Phase) -> str:
    return json.dumps([[_sig(s) for s in phase.steps], phase.check.kind, phase.check.command, phase.check.app])


def _no_repeat(run: Run, new):
    """A rethink must not start by doing again what just failed (live 2026-11-18: one failing 'open Edge'
    step planned 4 times in a row, then the run gave up)."""
    if isinstance(new, str) or not new:
        return new
    first = new[0]
    if _phase_sig(first) in run.failed_phases:
        raise PlanError(f"phase 1 ('{first.name}') already ran exactly like this and its check failed: "
                        "change the approach")
    if first.steps and _sig(first.steps[0]) in run.failed_steps:
        raise PlanError(f"phase 1 step 1 already failed this run ({_sig(first.steps[0])[:160]}): "
                        "take a different route")
    return new


def _log_step(run: Run, step: Step, res) -> None:
    what = step.command if step.kind in ("shell", "admin") else step.goal
    code = f" (exit {res.exit_code})" if res.exit_code is not None else ""
    why = f" — {res.detail}" if res.detail and not res.ok else ""
    tail = (res.output or "")[-1500:].strip()
    run.add_log("step", f"{step.kind}: {what[:300]} → {res.status}{code}{why}" + (f"\n{tail}" if tail else ""))


def _wait_back(run: Run, deps: Deps, limits: Limits) -> None:
    _say(deps, f"The PC went offline — waiting for it to come back (up to {limits.offline_wait_minutes} min)…\n")
    out = wait_for_pc(run, deps, limits.offline_wait_minutes)
    if out.status == "stopped":
        raise _End("stopped", "stopped")
    if out.status != "back":
        raise _End("failed", "pc_offline", str(limits.offline_wait_minutes))


def _do_phase(run: Run, phase: Phase, deps: Deps, limits: Limits):
    """None when the phase's check passed; otherwise the failure detail (for the rethink)."""
    phase.status, phase.detail = "running", ""
    restart = phase.restart_after and not run.read_only
    _say(deps, f"\n**Phase {run.phase_index + 1}/{len(run.phases)} · {phase.name}**\n")
    for j, step in enumerate(phase.steps, 1):
        _stop_check(deps)
        label = _label(step)
        face = needs_face_id(step, run.request_text)
        _set(run, deps, "approval" if face else "working", label)
        name = _TOOL_NAMES.get(step.kind, step.kind)
        args = {"command": step.command} if step.kind in ("shell", "admin") else {"goal": step.goal}
        started = deps.clock()
        tid = _tool_start(run, deps, name, args, ("Waiting for your Face ID · " if face else "") + label)
        res = (with_face_id_retries(deps, lambda: run_step(step, run, deps)) if face
               else run_step(step, run, deps))
        code = f"exit {res.exit_code}" if res.exit_code is not None else res.status
        _tool_done(deps, tid, name, res.ok, "\n".join(x for x in (f"{res.status} ({code})" if not res.ok else "",
                                                                     res.detail if not res.ok else "",
                                                                     res.output or "") if x),
                   f"{label} · {code}", started)
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
            run.failed_steps.append(_sig(step))
            run.failed_phases.append(_phase_sig(phase))   # the whole phase can't come back word for word either
            return phase.detail
        restart = restart or (res.restart_needed and not run.read_only)
    if restart:
        _say(deps, "Restarting the PC (Face ID first), then waiting for it to come back and for you to be "
                   "signed in…\n")
        out = restart_and_wait(run, deps, limits, phase.name)
        if out.status == "stopped":
            raise _End("stopped", "stopped")
        if out.status in _RESTART_END:
            detail = {"approval_timeout": RESTART_COMMAND, "timeout": str(limits.reboot_wait_minutes)}.get(out.status, "")
            raise _End("failed", _RESTART_END[out.status], detail)
        if out.status != "back":
            phase.status, phase.detail = "failed", f"the restart didn't happen: {out.detail or out.status}"
            return phase.detail
        _say(deps, "The PC is back.\n")
    _stop_check(deps)
    _set(run, deps, "checking", "")
    check_name = "Check" if phase.check.kind == "shell" else "Check (screen)"
    check_what = phase.check.command or phase.check.app
    started = deps.clock()
    tid = _tool_start(run, deps, check_name, {"command": check_what}, " ".join(check_what.split())[:80])
    chk = run_check(phase.check, deps, limits.settle_s)
    if not chk.passed and deps.should_stop():
        _tool_done(deps, tid, check_name, False, "stopped", "stopped", started)
        raise _End("stopped", "stopped")
    if not chk.passed and chk.detail == "PC offline":
        _tool_done(deps, tid, check_name, False, "the PC went offline", "PC offline", started)
        _wait_back(run, deps, limits)
        _set(run, deps, "checking", "")
        started = deps.clock()
        tid = _tool_start(run, deps, check_name, {"command": check_what}, " ".join(check_what.split())[:80])
        chk = run_check(phase.check, deps, limits.settle_s)
    run.add_log("check", f"{phase.name}: {'passed' if chk.passed else chk.detail}"
                + (f"\n{chk.output[-1500:].strip()}" if chk.output and chk.output.strip() else ""))
    _tool_done(deps, tid, check_name, chk.passed,
               "\n".join(x for x in ("passed" if chk.passed else f"failed: {chk.detail}", chk.output or "") if x),
               "passed" if chk.passed else "failed", started)
    if chk.passed:
        phase.status = "passed"
        deps.progress(run)
        return None
    phase.status, phase.detail = "failed", f"check failed: {chk.detail}"
    run.failed_phases.append(_phase_sig(phase))
    return chk.detail


def _drive(run: Run, deps: Deps, limits: Limits) -> None:
    _set(run, deps, "researching")
    _say(deps, f"Researching how to do this: {run.goal}\n")
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
    titles = "; ".join(str(x.get("title") or x.get("url") or "") for x in run.brief.sources[:6])
    _say(deps, f"\n**Research** · {len(run.brief.sources)} sources ({titles})\nRoute: {run.brief.route}\n")
    deps.progress(run)
    if run.brief.research_only:
        if not past_limits(run.goal):
            raise _End("done", "research_only")
        run.add_log("research", "the brief said research-only, but this is a job on the PC: planning it")
    if not run.pc_allowed:
        raise _End("failed", "not_asked")
    _set(run, deps, "planning")
    try:
        run.phases = ask_json(deps.ask, "plan",
                              plan_prompt(run.goal, run.brief, run.facts, run.screen_allowed, run.read_only,
                                          run.previous),
                              lambda text: parse_plan(text, read_only=run.read_only), max_tokens=4000)
    except PlanError as exc:
        raise _End("failed", "plan_failed", str(exc)) from None
    _say(deps, "\n**Plan**" + (" (read-only)" if run.read_only else "") + "\n"
         + "\n".join(f"{k}. {p.name}" + (" · restart after" if p.restart_after else "")
                     for k, p in enumerate(run.phases, 1)) + "\n")
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
        _say(deps, f"\nPhase {run.phase_index + 1} didn't pass: {failure[:300]}\nRethinking "
                   f"({run.phase_rethinks}/{limits.max_rethinks} for this phase)…\n")
        try:
            new = ask_json(deps.ask, "plan", rethink_prompt(run, failure),
                           lambda text: _no_repeat(run, parse_rethink(text, read_only=run.read_only)),
                           max_tokens=4000)
        except PlanError as exc:
            raise _End("failed", "plan_failed", str(exc)) from None
        if isinstance(new, str):
            raise _End("failed", "gave_up", new)
        run.add_log("rethink", f"rethink {run.rethinks}: {len(new)} new phases after: {failure}")
        _say(deps, "New plan from here: " + "; ".join(p.name for p in new) + "\n")
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
    _say(deps, "\n" + run.report.split("\n", 1)[0] + "\n")   # the runner ends the stream once the transcript is saved
    return run
