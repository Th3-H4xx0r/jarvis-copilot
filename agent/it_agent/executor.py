"""Runs one step and one check. Terminal steps run unelevated; destructive ones only after his Face ID (and
still unelevated); admin steps elevated after Face ID; screen steps only when he asked for his PC himself.
Checks are evaluated by code — a model never decides a phase passed."""
from __future__ import annotations

import re

from agent.it_agent.classify import classify
from agent.it_agent.model import (REBOOT_EXIT_CODES, Check, CheckResult, Deps, Run, ShellResult, Step,
                                  StepResult)

_SCREEN_GATE = "Screen steps need you to ask for your PC in your own words."


def needs_face_id(step: Step, request_text: str) -> bool:
    return step.kind == "admin" or (step.kind == "shell" and classify(step.command, request_text).destructive)


def _from_shell(res: ShellResult, ok_codes: list) -> StepResult:
    out = (res.output or "")[-4000:]
    if res.status != "ran":
        return StepResult(False, res.status, out, res.exit_code, detail=res.error or res.status)
    restart = res.exit_code in REBOOT_EXIT_CODES
    ok = res.exit_code in set(ok_codes or [0]) or restart
    return StepResult(ok, "ran", out, res.exit_code, restart_needed=restart,
                      detail="" if ok else f"exit {res.exit_code}")


def run_step(step: Step, run: Run, deps: Deps) -> StepResult:
    if step.kind in ("shell", "admin"):
        verdict = classify(step.command, run.request_text)
        if verdict.refuse:
            return StepResult(False, "refused", detail=verdict.reason)
        if step.kind == "admin":
            res = deps.admin(step.command, step.why[:300] or "Admin step", step.timeout_s)
        elif verdict.destructive:
            if deps.approved is None:   # never elevate a command just because it needed approval
                return StepResult(False, "refused", detail=f"needs your Face ID ({verdict.reason})")
            res = deps.approved(step.command, f"{step.why} ({verdict.reason})".strip()[:300], step.timeout_s)
        else:
            res = deps.shell(step.command, step.timeout_s)
        return _from_shell(res, step.ok_exit_codes)
    if step.kind == "screen":
        if not run.screen_allowed:
            return StepResult(False, "refused", detail=_SCREEN_GATE)
        shot = deps.screen(step.goal)
        return StepResult(bool(shot.ok), "ran" if shot.ok else "error", (shot.text or "")[-4000:],
                          detail=shot.error)
    if step.kind == "research":
        results = deps.search(step.goal or step.command) or []
        pages = deps.extract([r["url"] for r in results[:2] if r.get("url")]) or []
        text = "\n\n".join(str(p.get("content") or "") for p in pages if not p.get("error"))
        return StepResult(bool(text), "ran", text[-4000:], detail="" if text else "nothing readable")
    return StepResult(False, "refused", detail=f"unknown step kind {step.kind!r}")


def _judge(check: Check, text: str, exit_code) -> CheckResult:
    if check.kind == "shell" and check.exit_code is not None and exit_code != check.exit_code:
        return CheckResult(False, f"exit {exit_code} (expected {check.exit_code})", text)
    if check.contains and check.contains not in text:
        return CheckResult(False, f'output lacks "{check.contains}"', text)
    if check.not_contains and check.not_contains in text:
        return CheckResult(False, f'output contains "{check.not_contains}"', text)
    if check.regex and not re.search(check.regex, text):
        return CheckResult(False, f"output doesn't match /{check.regex}/", text)
    return CheckResult(True, "passed", text)


def _check_once(check: Check, deps: Deps) -> CheckResult:
    if check.kind == "screen":
        return _judge(check, str(deps.read_screen(check.app) or ""), None)
    res = deps.shell(check.command, check.timeout_s)   # never elevated
    if res.status == "timeout":
        return CheckResult(False, f"timed out after {check.timeout_s} s", res.output or "")
    if res.status == "offline":
        return CheckResult(False, "PC offline", "")
    if res.status != "ran":
        return CheckResult(False, res.error or res.status, res.output or "")
    return _judge(check, res.output or "", res.exit_code)


def run_check(check: Check, deps: Deps, settle_s: float) -> CheckResult:
    first = _check_once(check, deps)
    if first.passed:
        return first
    deps.sleep(settle_s)   # an install can need a moment before its command answers
    return _check_once(check, deps)
