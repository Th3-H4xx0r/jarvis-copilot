"""The run's report, built by code only — no model prose — so it can't claim a phase passed that didn't."""
from __future__ import annotations

from agent.it_agent.model import Phase, Run
from agent.it_agent.waits import RESTART_COMMAND


def _n(run: Run) -> int:
    return min(run.phase_index, len(run.phases) - 1) + 1 if run.phases else 0


def _cmd(detail: str) -> str:
    return "the restart" if detail == RESTART_COMMAND else f"`{detail}`"


def outcome_line(run: Run) -> str:
    n, d, r = _n(run), str(run.end_detail or "").rstrip("."), run.rethinks
    if n == 0 and run.end_reason in ("stopped", "error"):
        return ("Stopped before any phase started." if run.end_reason == "stopped"
                else f"Something went wrong before I started: {d}.")
    lines = {
        "checks_passed": "Every phase's check passed.",
        "check_failed": f"Phase {n}'s check still fails after {r} rethinks: {d}.",
        "approval_timeout": (f"You didn't answer the Face ID request for {_cmd(d)} in 2 minutes, so nothing ran "
                             f"elevated and I stopped at phase {n}."),
        "approval_denied": f"You declined {_cmd(d)}, so I stopped at phase {n}.",
        "restart_declined": (f"You chose not to restart now; phase {n} needs a restart to finish. Ask me again "
                             "when it suits you."),
        "signin_timeout": f"Your PC restarted but no one signed in within {d} minutes, so I stopped at phase {n}.",
        "pc_offline": f"Your PC went offline and didn't come back within {d} minutes (phase {n}).",
        "plan_failed": "I couldn't get a plan where every phase has a check I can verify.",
        "not_asked": ("I only change your PC when you ask for it in your own words, so I stopped after the research. "
                      "Ask me again yourself (for example: \"install Docker Desktop on my PC\")."),
        "gave_up": f"I stopped at phase {n}: {d}",
        "stopped": f"Stopped at phase {n}. A command that was already running on the PC may still finish.",
        "error": f"Something went wrong at phase {n}: {d}.",
    }
    return lines.get(run.end_reason, run.end_reason)


def _phase_line(i: int, p: Phase) -> str:
    what = p.check.command if p.check.kind == "shell" else f"screen: {p.check.app}"
    if p.status == "passed":
        return f"✓ {i}. {p.name} — check passed: `{what}`"
    if p.status == "failed":
        return f"✗ {i}. {p.name} — {p.detail} (check: `{what}`)"
    if p.status == "running":
        return f"■ {i}. {p.name} — stopped here"
    return f"· {i}. {p.name} — not reached"


def _source_lines(sources: list) -> str:
    return "\n".join(f"- {s.get('title') or s.get('url')} ({s.get('url')})" for s in sources)


def build_report(run: Run) -> str:
    b = run.brief
    if run.end_reason == "research_only" and b:
        return f"{b.answer}\n\nSources:\n{_source_lines(b.sources)}" if b.sources else b.answer
    head = {"done": "Done", "stopped": "Stopped"}.get(run.status, "Couldn't finish")
    parts = [f"**{head}: {run.goal}**", outcome_line(run)]
    if run.phases:
        parts.append("Phases:\n" + "\n".join(_phase_line(i, p) for i, p in enumerate(run.phases, 1)))
    sources = b.sources if b else []
    titles = "; ".join(s.get("title") or s.get("url", "") for s in sources)
    parts.append(f"Research: {len(sources)} sources — {titles}" if sources else "Research: no sources could be read")
    return "\n\n".join(parts)


def log_markdown(run: Run) -> str:
    """The full run as Markdown (brief, sources, phases, every logged step and check)."""
    out = [f"# IT task: {run.goal}", "", f"Status: {run.status} ({run.end_reason or 'running'})"]
    b = run.brief
    if b:
        out += ["", "## Brief", b.summary]
        if b.requirements:
            out.append("Requirements: " + "; ".join(b.requirements))
        out.append(f"Route: {b.route}")
        if b.sources:
            out += ["", "## Sources", _source_lines(b.sources)]
    if run.phases:
        out += ["", "## Phases"] + [_phase_line(i, p) for i, p in enumerate(run.phases, 1)]
    if run.log:
        out += ["", "## Log"]
        for entry in run.log:
            head, _, rest = str(entry.get("text", "")).partition("\n")
            out.append(f"- **{entry.get('kind')}** {head}")
            if rest.strip():
                out.append("\n```\n" + rest.replace("```", "'''") + "\n```")
    return "\n".join(out)
