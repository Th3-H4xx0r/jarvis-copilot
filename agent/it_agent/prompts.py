"""Prompts for the IT agent (each asks for exactly the JSON the code validates in plans.py)."""
from __future__ import annotations

import json


def _facts(facts: dict) -> str:
    shown = {k: v for k, v in (facts or {}).items() if not str(k).startswith("_")}
    return json.dumps(shown) if shown else "(not known yet)"


def queries_prompt(goal: str, facts: dict, failed: list | None = None) -> str:
    retry = (f"\nThese pages couldn't be read; search differently: {', '.join(failed)}" if failed else "")
    return (f"You research a task before doing it on the user's Windows PC, like an IT support person.\n"
            f"Task: {goal}\nPC facts: {_facts(facts)}{retry}\n"
            "Write 3–5 distinct web search queries: the official docs / install guide, the system requirements, "
            "and known issues or common errors. Reply with ONLY: {\"queries\": [\"...\"]}")


def pick_prompt(goal: str, results: list) -> str:
    listed = "\n".join(f"- {r.get('url')} — {r.get('title', '')}" for r in results)
    return (f"Task: {goal}\nSearch results:\n{listed}\n"
            "Pick 3–6 URLs to read, official sources first (the vendor's docs, Microsoft Learn), then trusted "
            "guides. Only URLs from the list. Reply with ONLY: {\"read\": [\"...\"]}")


def brief_prompt(goal: str, pages: list, facts: dict) -> str:
    body = "\n\n".join(f"### {p.get('title') or p.get('url')} ({p.get('url')})\n{p.get('content', '')}" for p in pages)
    return (f"Task: {goal}\nPC facts: {_facts(facts)}\nWhat you read:\n{body}\n\n"
            "Write the brief an IT support person would before starting. Reply with ONLY this JSON:\n"
            "{\"summary\": \"2–4 sentences\", \"requirements\": [\"...\"], \"route\": \"how you'll do it "
            "(prefer the terminal: winget / PowerShell)\", \"checks\": [\"commands that prove it worked\"], "
            "\"research_only\": false, \"answer\": \"\"}\n"
            "Set research_only true (and write the answer) only when the task is a question to answer and "
            "nothing has to be done on the PC.")


_SCHEMA = ('{"phases": [{"name": "...", "restart_after": false, "steps": [{"kind": "shell", "command": "...", '
           '"goal": "", "why": "...", "timeout_s": 300, "ok_exit_codes": [0]}], "check": {"kind": "shell", '
           '"command": "...", "app": "", "timeout_s": 120, "expect": {"exit_code": 0, "contains": "", '
           '"not_contains": "", "regex": ""}}}]}')


def _rules(screen_allowed: bool) -> str:
    screen = ("- kind \"screen\": a GUI-only step for the screen hands; goal = what to do in plain words (e.g. "
              "accept the Docker Desktop license). A screen check reads an app window's text: {\"kind\": \"screen\", "
              "\"app\": \"Docker Desktop\", \"expect\": {\"contains\": \"Engine running\"}}.\n"
              if screen_allowed else
              "- Screen steps are NOT available for this task: do everything in the terminal.\n")
    return (
        "Rules (the code rejects a plan that breaks them):\n"
        "- The PC runs Windows PowerShell 5.1. Each step runs in a fresh shell with PATH refreshed from the "
        "registry, so a tool installed in an earlier step is found by name. No interactive prompts: pass the "
        "flags that make commands silent; start GUI apps without -Wait.\n"
        "- kind \"shell\": runs as the signed-in user, unelevated. Install with winget: "
        "winget install -e --id <Id> --accept-package-agreements --accept-source-agreements --silent. winget "
        "exits -1978335135 when already installed and -1978335189 when no newer version exists; list those in "
        "ok_exit_codes when that's fine. Long installs: raise timeout_s (max 1800).\n"
        "- kind \"admin\": runs elevated and asks his Face ID first, one command per approval — machine-wide "
        "installs and Windows features (dism, wsl --install, Enable-WindowsOptionalFeature) are admin steps. "
        "Group related admin work into one command (max 2400 characters).\n"
        "- Never use Start-Process -Verb RunAs (it shows a UAC prompt nobody can answer).\n"
        f"{screen}"
        "- kind \"research\": look something up mid-run; goal = what to find.\n"
        "- Every phase ends with a check that proves it worked: a read-only, unelevated command (or screen read) "
        "with an expect (exit_code / contains / not_contains / regex). A check must not change anything.\n"
        "- A restart goes in restart_after: true on the phase that needs it — never shutdown or Restart-Computer "
        "as a step. His Face ID is asked before restarting.\n"
        "- No uninstalling, deleting files, registry edits or stopping processes unless his own words ask for it.\n"
        "- 1–8 phases, 1–10 steps each.\n")


def plan_prompt(goal: str, brief, facts: dict, screen_allowed: bool) -> str:
    reqs = "; ".join(brief.requirements) if brief and brief.requirements else "(none listed)"
    checks = "; ".join(brief.checks) if brief and brief.checks else "(none listed)"
    return (f"You do IT tasks on the user's Windows PC the way an IT support person would: in phases, each "
            f"one proven by a check before moving on.\nTask: {goal}\nPC facts: {_facts(facts)}\n"
            f"Research summary: {brief.summary if brief else ''}\nRequirements: {reqs}\n"
            f"Route: {brief.route if brief else ''}\nChecks that prove it worked: {checks}\n\n"
            f"{_rules(screen_allowed)}\nReply with ONLY this JSON shape:\n{_SCHEMA}")


def rethink_prompt(run, failure: str) -> str:
    i = run.phase_index
    phase = run.phases[i] if 0 <= i < len(run.phases) else None
    passed = [p.name for p in run.phases[:i] if p.status == "passed"]
    recent = "\n".join(f"- [{e['kind']}] {e['text'][:600]}" for e in run.log[-12:]) or "(nothing yet)"
    brief = run.brief
    return (f"You're partway through an IT task on the user's Windows PC.\nTask: {run.goal}\n"
            f"PC facts: {_facts(run.facts)}\nResearch summary: {brief.summary if brief else ''}\n"
            f"Route: {brief.route if brief else ''}\n"
            f"Phases that passed: {', '.join(passed) or 'none'}\n"
            f"Phase {i + 1} ('{phase.name if phase else ''}') failed: {failure}\nRecent log:\n{recent}\n\n"
            "Work out why, then write revised phases for the rest of the task, starting with the one that failed "
            f"(don't repeat what already passed).\n{_rules(run.screen_allowed)}\n"
            f"Reply with ONLY this JSON shape:\n{_SCHEMA}\n"
            "If it can't be done on this PC, reply with ONLY {\"give_up\": \"why, in one sentence he'll understand\"}.")
