"""The supervisor: research always, a checked plan, phases verified by code, capped rethinks, an honest
report — never "done" unless every phase's check passed."""
import json

from agent.it_agent import supervisor
from agent.it_agent.model import Deps, Limits, Run, ScreenResult, ShellResult
from agent.it_agent.supervisor import run_task
from agent.it_agent.waits import WaitOutcome

DOCKER = "winget install -e --id Docker.DockerDesktop"


def phase(name, step=DOCKER, check="docker --version", kind="shell", restart=False):
    return {"name": name, "restart_after": restart, "steps": [{"kind": kind, "command": step, "why": "need it"}],
            "check": {"kind": "shell", "command": check, "expect": {"exit_code": 0}}}


class Script:
    def __init__(self, phases=None, rethinks=None, brief=None, check_results=None, step_results=None,
                 admin_result=None, stop_after=None, online=True):
        self.phases = phases or [phase("Install")]
        self.rethinks = list(rethinks or [])
        self.brief = brief or {"summary": "Needs WSL2", "route": "winget", "checks": ["docker --version"]}
        self.check_results = dict(check_results or {})
        self.step_results = dict(step_results or {})
        self.admin_result = admin_result or ShellResult("ran", 0, "ok", routed="admin")
        self.asks, self.shells, self.admins, self.states, self.searches = [], [], [], [], []
        self.stop_after = stop_after
        self._online = online

    def ask(self, purpose, prompt, max_tokens):
        self.asks.append((purpose, prompt))
        if "search queries" in prompt:
            return json.dumps({"queries": ["docker desktop install", "docker wsl2 requirements", "docker errors"]})
        if "Pick 3–6 URLs" in prompt:
            return json.dumps({"read": ["https://docs.docker.com/a", "https://learn.microsoft.com/b",
                                        "https://c.example/c"]})
        if "Write the brief" in prompt:
            return json.dumps(self.brief)
        if "check failed" in prompt or "give_up" in prompt and "revised" in prompt:
            reply = self.rethinks.pop(0) if self.rethinks else {"give_up": "out of ideas"}
            return json.dumps(reply)
        return json.dumps({"phases": self.phases}) if self.phases != "bad" else "not json {"

    def search(self, q):
        self.searches.append(q)
        return [{"url": u, "title": u.split("/")[2]} for u in
                ("https://docs.docker.com/a", "https://learn.microsoft.com/b", "https://c.example/c")]

    def shell(self, command, timeout):
        self.shells.append(command)
        if "ConvertTo-Json" in command:
            return ShellResult("ran", 0, json.dumps({"os": "Windows 11", "winget": True}))
        queue = self.check_results.get(command) or self.step_results.get(command)
        if isinstance(queue, list):
            return queue.pop(0) if len(queue) > 1 else queue[0]
        return queue or ShellResult("ran", 0, "Docker version 27")

    def deps(self):
        nothing = lambda *a, **k: None  # noqa: E731
        return Deps(ask=self.ask, search=self.search,
                    extract=lambda urls: [{"url": u, "title": u.split("/")[2], "content": "docs " * 50} for u in urls],
                    shell=self.shell, admin=lambda c, w, t: self.admins.append(c) or self.admin_result,
                    screen=lambda g: ScreenResult(True), read_screen=lambda a: "", online=lambda: self._online,
                    signed_in=lambda: True, wake=nothing, notify=nothing,
                    progress=lambda run: self.states.append(run.state),
                    should_stop=lambda: self.stop_after is not None and len(self.shells) >= self.stop_after,
                    sleep=lambda s: None, clock=lambda: 0.0,
                    approved=lambda c, w, t: ShellResult("ran", 0, "ok", routed="approved"))


def _run(goal="install Docker Desktop", pc_allowed=True):
    return Run(goal=goal, request_text=goal + " on my pc", device_id="pc", device_name="PC", pc_allowed=pc_allowed)


def L(**kw):
    return Limits(settle_s=0, **kw)


def test_happy_path_every_check_passes():
    s = Script(phases=[phase("Check"), phase("Install"), phase("Verify")])
    run = run_task(_run(), s.deps(), L())
    assert run.status == "done" and run.end_reason == "checks_passed" and run.report.startswith("**Done:")
    assert run.checks_passed() == 3 and "✓ 1. Check — check passed: `docker --version`" in run.report


def test_never_done_unless_every_check_passed():
    s = Script(phases=[phase("Install")], check_results={"docker --version": ShellResult("ran", 1, "nope")})
    run = run_task(_run(), s.deps(), L(max_rethinks=0))
    assert run.status != "done" and not run.report.startswith("**Done:")


def test_failed_check_rethinks_then_succeeds():
    nope = ShellResult("ran", 1, "nope")
    s = Script(phases=[phase("Install", check="docker --version")],
               rethinks=[{"phases": [phase("Install again", check="docker info")]}],
               check_results={"docker --version": [nope, nope, ShellResult("ran", 0, "Docker version 27")]})
    run = run_task(_run(), s.deps(), L())
    assert run.status == "done" and run.rethinks == 1 and run.phases[0].name == "Install again"


def test_rethink_cap_reports_failure_honestly():
    fail = ShellResult("ran", 1, "nope")
    s = Script(phases=[phase("Install")], rethinks=[{"phases": [phase("Install")]}] * 5,
               check_results={"docker --version": fail})
    run = run_task(_run(), s.deps(), L(max_rethinks=3))
    assert run.status == "failed" and run.end_reason == "check_failed" and run.rethinks == 3
    assert run.report.startswith("**Couldn't finish:") and "still fails after 3 rethinks" in run.report


def test_give_up_reports_reason():
    s = Script(check_results={"docker --version": ShellResult("ran", 1, "nope")},
               rethinks=[{"give_up": "Hyper-V is missing on this edition"}])
    run = run_task(_run(), s.deps(), L())
    assert run.end_reason == "gave_up" and "I stopped at phase 1: Hyper-V is missing on this edition" in run.report


def test_face_id_timeout_stops_without_rethink():
    s = Script(phases=[phase("WSL", step="wsl --install --no-distribution", kind="admin")],
               admin_result=ShellResult("approval_timeout"))
    run = run_task(_run(), s.deps(), L())
    assert run.end_reason == "approval_timeout" and run.rethinks == 0 and run.status == "failed"
    assert "didn't answer the Face ID request" in run.report and "nothing ran elevated" in run.report


def test_denied_stops():
    s = Script(phases=[phase("WSL", step="wsl --install --no-distribution", kind="admin")],
               admin_result=ShellResult("denied"))
    run = run_task(_run(), s.deps(), L())
    assert run.end_reason == "approval_denied" and "You declined `wsl --install --no-distribution`" in run.report


def test_restart_flow_then_check(monkeypatch):
    order = []
    monkeypatch.setattr(supervisor, "restart_and_wait", lambda run, deps, limits, name: order.append("restart") or WaitOutcome("back"))
    s = Script(phases=[phase("WSL", restart=True)])
    real_shell = s.shell
    s.shell = lambda c, t: (order.append("check") if c == "docker --version" else None, real_shell(c, t))[1]
    run = run_task(_run(), s.deps(), L())
    assert order.index("restart") < order.index("check") and run.status == "done"


def test_pc_offline_mid_step_waits_then_rechecks(monkeypatch):
    monkeypatch.setattr(supervisor, "wait_for_pc", lambda run, deps, minutes: WaitOutcome("back"))
    s = Script(step_results={DOCKER: ShellResult("offline")})
    run = run_task(_run(), s.deps(), L())
    assert s.shells.count(DOCKER) == 1 and run.phases[0].status == "passed"


def test_stop_from_card_mid_phase():
    s = Script(phases=[phase("Check"), phase("Install")], stop_after=2)
    run = run_task(_run(), s.deps(), L())
    assert run.status == "stopped" and "Stopped at phase" in run.report


def test_research_only_skips_plan():
    s = Script(brief={"summary": "s", "route": "read reviews", "checks": [], "research_only": True,
                      "answer": "The ASUS ROG GM700 is the best pick."})
    run = run_task(_run("best PC under $2k?"), s.deps(), L())
    assert not [a for a in s.asks if a[0] == "plan" and "phases" in a[1] and "Write the brief" not in a[1]]
    assert "The ASUS ROG GM700" in run.report and run.report.count("\n- ") >= 3 and run.status == "done"


def test_plan_failure_reported():
    s = Script(phases="bad")
    run = run_task(_run(), s.deps(), L())
    assert run.end_reason == "plan_failed" and run.status == "failed"


def test_research_cannot_be_skipped():
    s = Script()
    run_task(_run(), s.deps(), L())
    first_plan = next(i for i, a in enumerate(s.asks) if "UI steps" in a[1] or ("phases" in a[1] and "Write the brief" not in a[1] and "search queries" not in a[1]))
    assert s.searches and first_plan > 0


def test_every_state_change_reported():
    s = Script()
    run_task(_run(), s.deps(), L())
    seen = [x for i, x in enumerate(s.states) if i == 0 or s.states[i - 1] != x]
    wanted = ["researching", "planning", "working", "checking", "reporting"]
    it = iter(seen)
    assert all(w in it for w in wanted)


def test_log_markdown_has_brief_phases_and_log():
    from agent.it_agent.report import log_markdown
    s = Script()
    run = run_task(_run(), s.deps(), L())
    md = log_markdown(run)
    assert md.startswith("# IT task: install Docker Desktop") and "Needs WSL2" in md
    assert "## Phases" in md and "## Log" in md and DOCKER in md


# Bug sweep 2026-11-18.
HELLO = "docker run hello-world"


def test_rethink_cannot_drop_the_failing_check():
    s = Script(phases=[phase("Install", check=HELLO)],
               rethinks=[{"phases": [phase("Try again", check="docker --version")]}] * 5,
               check_results={HELLO: ShellResult("ran", 1, "engine not running")})
    run = run_task(_run(), s.deps(), L(max_rethinks=2))
    assert run.status == "failed" and not run.report.startswith("**Done:") and HELLO in run.report


def test_rethink_that_fixes_it_passes_the_original_check_too():
    fail = ShellResult("ran", 1, "engine not running")
    s = Script(phases=[phase("Install", check=HELLO)],
               rethinks=[{"phases": [phase("Start the engine", check="docker --version")]}],
               check_results={HELLO: [fail, fail, ShellResult("ran", 0, "Hello from Docker!")]})
    run = run_task(_run(), s.deps(), L())
    assert run.status == "done" and any(p.check.command == HELLO and p.status == "passed" for p in run.phases)


def test_pc_changes_need_his_own_words():
    s = Script()
    run = run_task(_run(pc_allowed=False), s.deps(), L())
    assert run.end_reason == "not_asked" and run.status == "failed" and DOCKER not in s.shells
    assert "own words" in run.report


def test_research_only_claim_ignored_for_an_install():
    s = Script(brief={"summary": "s", "route": "winget", "checks": ["docker --version"], "research_only": True,
                      "answer": "Just install it."})
    run = run_task(_run(), s.deps(), L())
    assert run.end_reason == "checks_passed" and DOCKER in s.shells


def test_stop_during_a_check_ends_stopped_not_failed():
    s = Script(check_results={"docker --version": ShellResult("ran", 1, "nope")}, stop_after=3)
    run = run_task(_run(), s.deps(), L())
    assert run.status == "stopped" and run.rethinks == 0 and "Stopped at phase 1" in run.report


def test_plan_rules_carry_the_windows_virtualization_quirk():
    # Live 2026-11-18: a check failed on VirtualizationFirmwareEnabled = False while Hyper-V ran — Windows
    # reports False there whenever a hypervisor is up.
    from agent.it_agent.model import Brief
    from agent.it_agent.prompts import plan_prompt
    text = plan_prompt("install Docker Desktop", Brief("s", [], "winget", ["docker --version"], []), {}, False)
    assert "HypervisorPresent" in text and "VirtualizationFirmwareEnabled" in text
    assert "say why" in text
