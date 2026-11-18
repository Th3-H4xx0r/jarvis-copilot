"""The IT agent's run model: a task done like an IT support person — research, phases with a check each,
terminal first, verify, rethink, report (spec docs/superpowers/specs/2026-11-18-it-agent-design.md)."""
from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Callable, Optional

STEP_KINDS = ("shell", "admin", "screen", "research")
CHECK_KINDS = ("shell", "screen")
MAX_PHASES = 8
MAX_STEPS = 10
SHELL_MAX_CHARS = 8000
ADMIN_MAX_CHARS = 2400
REBOOT_EXIT_CODES = (3010, 1641)   # msiexec / installers: "restart required"

# Read-only facts about the PC, one JSON line (the plan prompt gets them).
FACTS_SCRIPT = (
    "$o = [ordered]@{}; $o.os = (Get-CimInstance Win32_OperatingSystem).Caption; "
    "$o.build = [Environment]::OSVersion.Version.Build; $o.powershell = $PSVersionTable.PSVersion.ToString(); "
    "$o.winget = [bool](Get-Command winget -ErrorAction SilentlyContinue); "
    "$o.wsl = [bool](Get-Command wsl -ErrorAction SilentlyContinue); "
    "$o.virtualization = [bool](Get-CimInstance Win32_ComputerSystem).HypervisorPresent; "
    "$o.free_gb = [math]::Round((Get-PSDrive C).Free / 1GB, 1); $o | ConvertTo-Json -Compress"
)
SIGNED_IN_SCRIPT = "if (Get-Process -Name explorer -ErrorAction SilentlyContinue) { 'yes' } else { 'no' }"


class PlanError(ValueError):
    """A model reply the code rejects (its message is fed back to the model)."""


@dataclass
class Check:
    kind: str
    command: str = ""
    app: str = ""
    timeout_s: int = 120
    exit_code: Optional[int] = 0
    contains: str = ""
    not_contains: str = ""
    regex: str = ""


@dataclass
class Step:
    kind: str
    command: str = ""
    goal: str = ""
    why: str = ""
    timeout_s: int = 300
    ok_exit_codes: list = field(default_factory=lambda: [0])


@dataclass
class Phase:
    name: str
    steps: list
    check: Check
    restart_after: bool = False
    status: str = "pending"      # pending · running · passed · failed
    detail: str = ""


@dataclass
class Brief:
    summary: str
    requirements: list
    route: str
    checks: list
    sources: list
    research_only: bool = False
    answer: str = ""


@dataclass
class ShellResult:
    status: str                  # ran · timeout · offline · denied · approval_timeout · refused · error · stopped
    exit_code: Optional[int] = None
    output: str = ""
    truncated: bool = False
    duration_ms: int = 0
    error: str = ""
    routed: str = "shell"


@dataclass
class ScreenResult:
    ok: bool
    text: str = ""
    error: str = ""


@dataclass
class StepResult:
    ok: bool
    status: str
    output: str = ""
    exit_code: Optional[int] = None
    restart_needed: bool = False
    detail: str = ""


@dataclass
class CheckResult:
    passed: bool
    detail: str
    output: str = ""


@dataclass
class Limits:
    max_rethinks: int = 3
    reboot_wait_minutes: int = 60
    offline_wait_minutes: int = 30
    settle_s: float = 15.0


@dataclass
class Run:
    goal: str
    request_text: str
    device_id: str
    device_name: str
    screen_allowed: bool = False
    # His own words this turn ask for something on the PC (it_jobs.asked_for_pc): without it the run
    # researches and answers but never changes the PC (an email or page the chat read can't start one).
    pc_allowed: bool = False
    state: str = "researching"
    status: str = "running"
    end_reason: str = ""
    end_detail: str = ""         # what the report's outcome line names (the command, the reason, the minutes)
    brief: Optional[Brief] = None
    phases: list = field(default_factory=list)
    phase_index: int = 0
    rethinks: int = 0
    steps_run: int = 0
    step_label: str = ""
    log: list = field(default_factory=list)
    report: str = ""
    facts: dict = field(default_factory=dict)

    def checks_passed(self) -> int:
        return sum(1 for p in self.phases if p.status == "passed")

    def all_checks_passed(self) -> bool:
        return bool(self.phases) and all(p.status == "passed" for p in self.phases)

    def add_log(self, kind: str, text: str) -> None:
        self.log.append({"kind": kind, "text": str(text), "at": time.time()})
        del self.log[:-200]


@dataclass
class Deps:
    ask: Callable[[str, str, int], str]
    search: Callable[[str], list]
    extract: Callable[[list], list]
    shell: Callable[[str, int], ShellResult]
    admin: Callable[[str, str, int], ShellResult]
    screen: Callable[[str], ScreenResult]
    read_screen: Callable[[str], str]
    online: Callable[[], bool]
    signed_in: Callable[[], bool]
    wake: Callable[[], None]
    notify: Callable[[str, str], None]
    progress: Callable[[Run], None]
    should_stop: Callable[[], bool]
    sleep: Callable[[float], None] = time.sleep
    clock: Callable[[], float] = time.monotonic
    # A destructive non-admin command: Face ID first, then it runs UNELEVATED (approval gates, never widens).
    approved: Optional[Callable[[str, str, int], ShellResult]] = None


def _phase(run: Run) -> Optional[Phase]:
    return run.phases[run.phase_index] if 0 <= run.phase_index < len(run.phases) else None


def _sources(run: Run) -> int:
    return len(run.brief.sources) if run.brief else len(run.facts.get("_sources", []))


def activity_line(run: Run) -> str:
    """The job card's one human line for the run's state."""
    i, n = run.phase_index + 1, len(run.phases)
    p = _phase(run)
    name = p.name if p else ""
    lines = {
        "researching": f"Researching · {_sources(run)} sources read",
        "planning": "Planning the phases",
        "working": f"Phase {i}/{n} · {name} — {run.step_label}",
        "approval": f"Phase {i}/{n} · waiting for your Face ID",
        "checking": f"Phase {i}/{n} · {name} — checking",
        "restarting": "Restarting your PC",
        "signin": "Waiting for you to sign in on the PC",
        "offline": "Waiting for your PC to come back",
        "rethinking": f"Phase {i}/{n} · check failed — rethinking",
        "reporting": "Writing the report",
    }
    return lines.get(run.state, run.state)


def card_it(run: Run) -> dict:
    """The job card's ``it`` field (W5)."""
    p = _phase(run)
    return {"state": run.state, "phase": p.name if p else "", "phase_no": run.phase_index + 1 if p else 0,
            "phases": len(run.phases), "checks_passed": run.checks_passed(), "step": run.step_label,
            "brief": (run.brief.summary if run.brief else "")[:600], "sources": _sources(run)}
