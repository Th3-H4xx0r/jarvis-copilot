"""IT agent: the run model and code-checked plan validation (a phase without a check is re-asked)."""
import json

import pytest

from agent.it_agent.model import Phase, PlanError, Run, Step, Check, activity_line, card_it
from agent.it_agent.plans import (ask_json, extract_json, parse_brief, parse_pick, parse_plan, parse_queries)

GOOD = {"phases": [{"name": "Install", "steps": [{"kind": "shell", "command": "winget --version"}],
                    "check": {"kind": "shell", "command": "winget --version", "expect": {"exit_code": 0}}}]}


def _plan(**phase):
    p = json.loads(json.dumps(GOOD["phases"][0]))
    p.update(phase)
    return json.dumps({"phases": [p]})


def test_plan_without_check_is_rejected_and_reasked():
    replies = [json.dumps({"phases": [{"name": "Install", "steps": [{"kind": "shell", "command": "x"}]}]}),
               json.dumps(GOOD)]
    prompts = []
    phases = ask_json(lambda p, prompt, n: (prompts.append(prompt), replies.pop(0))[1], "plan", "PLAN",
                      parse_plan, max_tokens=4000)
    assert len(prompts) == 2 and "phase 1 ('Install') has no check" in prompts[1]
    assert phases[0].check.exit_code == 0


def test_malformed_json_is_reasked_then_gives_up():
    calls = []
    with pytest.raises(PlanError, match="gave up after 3 tries"):
        ask_json(lambda *a: calls.append(a) or "not json {", "plan", "P", parse_plan, max_tokens=10)
    assert len(calls) == 3


def test_extract_json_strips_fences():
    assert extract_json('```json\n{"a": 1}\n```') == {"a": 1}


def test_restart_command_as_step_rejected():
    for cmd in ("shutdown /r /t 0", "Restart-Computer -Force", "Stop-Computer"):
        with pytest.raises(PlanError, match="set restart_after"):
            parse_plan(_plan(steps=[{"kind": "shell", "command": cmd}]))


def test_regex_must_compile():
    with pytest.raises(PlanError, match="doesn't compile"):
        parse_plan(_plan(check={"kind": "shell", "command": "x", "expect": {"regex": "("}}))


def test_limits():
    with pytest.raises(PlanError, match="too many phases"):
        parse_plan(json.dumps({"phases": [GOOD["phases"][0]] * 9}))
    with pytest.raises(PlanError, match="needs 1–10 steps"):
        parse_plan(_plan(steps=[]))
    with pytest.raises(PlanError, match="command too long \\(max 8000"):
        parse_plan(_plan(steps=[{"kind": "shell", "command": "x" * 8001}]))
    with pytest.raises(PlanError, match="command too long \\(max 2400"):
        parse_plan(_plan(steps=[{"kind": "admin", "command": "x" * 2401}]))
    with pytest.raises(PlanError, match="the plan has no phases"):
        parse_plan(json.dumps({"phases": []}))


def test_defaults_and_clamps():
    low = parse_plan(_plan(steps=[{"kind": "shell", "command": "a", "timeout_s": 0}]))
    high = parse_plan(_plan(steps=[{"kind": "shell", "command": "a", "timeout_s": 99999}],
                            check={"kind": "shell", "command": "a", "timeout_s": 99999}))
    assert low[0].steps[0].timeout_s == 5 and high[0].steps[0].timeout_s == 1800
    assert high[0].check.timeout_s == 600 and low[0].steps[0].ok_exit_codes == [0]


def test_brief_rules():
    with pytest.raises(PlanError, match="the brief needs a route"):
        parse_brief(json.dumps({"summary": "s", "route": "", "checks": ["c"]}), [])
    with pytest.raises(PlanError, match="the brief needs the checks to run"):
        parse_brief(json.dumps({"summary": "s", "route": "winget", "checks": []}), [])
    with pytest.raises(PlanError, match="a research-only brief needs the answer"):
        parse_brief(json.dumps({"summary": "s", "route": "read", "checks": [], "research_only": True}), [])
    ok = parse_brief(json.dumps({"summary": "s", "route": "winget", "checks": ["docker --version"]}), [{"url": "u"}])
    assert ok.route == "winget" and ok.sources == [{"url": "u"}]


def test_parse_pick_keeps_only_offered_urls():
    allowed = ["https://a", "https://b"]
    assert parse_pick(json.dumps({"urls": ["https://a", "https://evil"]}), allowed) == ["https://a"]
    assert parse_pick("garbage", allowed) == []


def test_all_checks_passed_needs_phases():
    assert Run(goal="g", request_text="g", device_id="d", device_name="PC", phases=[]).all_checks_passed() is False


def test_activity_line_copy():
    phases = [Phase(name=n, steps=[Step(kind="shell", command="x")], check=Check(kind="shell", command="x"))
              for n in ("Check", "Enable WSL2", "Install", "Verify")]
    run = Run(goal="g", request_text="g", device_id="d", device_name="PC", state="working", phases=phases,
              phase_index=1, step_label="wsl --status")
    assert activity_line(run) == "Phase 2/4 · Enable WSL2 — wsl --status"
    card = card_it(run)
    assert card["phase_no"] == 2 and card["phases"] == 4 and card["state"] == "working"


def test_destructive_check_rejected():
    with pytest.raises(PlanError, match="phase 1 check must not change anything: deletes files"):
        parse_plan(_plan(check={"kind": "shell", "command": "Remove-Item C:\\x", "expect": {"exit_code": 0}}))


def test_check_that_tests_nothing_is_rejected():
    with pytest.raises(PlanError, match="phase 1 check must test something"):
        parse_plan(_plan(check={"kind": "shell", "command": "docker --version", "expect": {"exit_code": None}}))


def test_malformed_expect_is_reasked_not_crashed():
    replies = [_plan(check={"kind": "shell", "command": "docker --version", "expect": "Docker version"}), json.dumps(GOOD)]
    prompts = []
    ask_json(lambda p, prompt, n: (prompts.append(prompt), replies.pop(0))[1], "plan", "P", parse_plan, max_tokens=10)
    assert len(prompts) == 2 and "expect" in prompts[1]


def test_string_lists_are_not_split_into_letters():
    with pytest.raises(PlanError):
        parse_queries('{"queries": "docker install"}')
    brief = parse_brief('{"route": "winget", "checks": "docker --version", "requirements": "WSL2"}', [])
    assert brief.checks == ["docker --version"] and brief.requirements == ["WSL2"]


def test_research_only_needs_a_real_true():
    assert parse_brief('{"route": "r", "checks": ["x"], "research_only": "false"}', []).research_only is False


def test_hidden_characters_in_commands_are_rejected():
    with pytest.raises(PlanError, match="hidden characters"):
        parse_plan(_plan(steps=[{"kind": "admin", "command": "echo safe\u202e;del C:\\x", "why": "x"}]))


def test_power_actions_are_not_it_steps():
    for cmd in ("rundll32.exe powrprof.dll,SetSuspendState 0,1,0", "rundll32 user32.dll,LockWorkStation"):
        with pytest.raises(PlanError, match="power actions"):
            parse_plan(_plan(steps=[{"kind": "shell", "command": cmd}]))



@pytest.mark.parametrize("cmd", ["Write-Output 'License research must be completed first'; exit 0", "echo ok",
                                 "exit 0", "Write-Host 'done'\nexit 0"])
def test_a_check_that_only_prints_is_rejected(cmd):
    # Live 2026-11-18: "Review Docker terms" passed with a check that only printed a sentence.
    with pytest.raises(PlanError, match="phase 1 check must test something"):
        parse_plan(_plan(check={"kind": "shell", "command": cmd, "expect": {"exit_code": 0}}))


def test_a_check_that_prints_and_probes_is_fine():
    parse_plan(_plan(check={"kind": "shell", "command": "Write-Output 'checking'; docker --version",
                            "expect": {"exit_code": 0}}))


@pytest.mark.parametrize("phase_fields,reason", [
    ({"steps": [{"kind": "admin", "command": "dism /online /get-features", "why": "x"}]}, "admin"),
    ({"restart_after": True}, "restart"),
    ({"steps": [{"kind": "shell", "command": "Remove-Item C:\\temp\\x"}]}, "change"),
    ({"steps": [{"kind": "screen", "goal": "open Docker Desktop"}]}, "screen")])
def test_read_only_plans_only_look(phase_fields, reason):
    # Live 2026-11-18: "see if it's fully installed now" restarted his PC.
    with pytest.raises(PlanError, match="read-only"):
        parse_plan(_plan(**phase_fields), read_only=True)
    parse_plan(_plan(), read_only=True)   # plain probes are fine



@pytest.mark.parametrize("cmd", ["echo $env:PATH", "Write-Output (Get-Service docker).Status; exit 0",
                                 "Write-Output (docker --version)", "echo (Test-Path 'C:\\Program Files\\Docker')",
                                 'Write-Output "WSL: $(wsl --status)"'])
def test_checks_that_print_what_they_probe_are_fine(cmd):
    # Review: these real checks were rejected as "only prints a message".
    parse_plan(_plan(check={"kind": "shell", "command": cmd, "expect": {"contains": "x"}}))


@pytest.mark.parametrize("cmd", ["winget install -e --id Docker.DockerDesktop",
                                 "Invoke-WebRequest https://x/a.exe -OutFile a.exe; Start-Process a.exe",
                                 "Start-Service com.docker.service", "wsl --update", "Set-Service x -StartupType Automatic"])
def test_read_only_plans_reject_commands_that_change_the_pc(cmd):
    # Review: a read-only plan accepted winget install, downloads, Start-Service and wsl --update.
    with pytest.raises(PlanError, match="read-only"):
        parse_plan(_plan(steps=[{"kind": "shell", "command": cmd}]), read_only=True)
