---
name: session-handoff
description: "Use when starting, pausing, resuming, or finishing coding work in a repo, when context is getting full, at a milestone, or when the user says 'save state', 'create handoff', 'I need to pause', 'resume from', or 'continue where we left off'. Writes comprehensive, validated handoffs into JarvisCopilot's shared store so they carry across Claude Code and the JarvisCopilot TUI, per project."
---

# Session handoff (jarviscopilot-code-assist)

A **handoff** is a comprehensive snapshot that lets the next agent — you later, or
the JarvisCopilot TUI — resume with zero ambiguity. Handoffs are stored in
JarvisCopilot's shared, project-scoped code-memory (`store_session_handoff` /
`recall_session_handoff`), so they carry across both surfaces. Project scope is
automatic (git remote / directory).

Scripts and references below live under this skill's directory
(`${CLAUDE_PLUGIN_ROOT}/skills/session-handoff/`).

## Mode selection
- **CREATE** — wrapping up, pausing, "save state", "create handoff", context getting
  full, or a milestone reached → CREATE workflow.
- **RESUME** — starting/continuing work, "load handoff", "resume from", "continue
  where we left off" → RESUME workflow.
- **Proactive** — after substantial work (5+ file edits, hard debugging, or a key
  decision) with no recent handoff, offer: *"We've made real progress — want me to
  store a session handoff so the next session picks up seamlessly?"*

## CREATE workflow
1. **Gather real git context** — run it and keep the output:
   `bash ${CLAUDE_PLUGIN_ROOT}/skills/session-handoff/scripts/gather_git_context.sh`
   (branch, upstream sync, recent commits, HEAD, working tree). This grounds the
   handoff in actual state — use it to fill Session Metadata + Files modified.
2. **Fill the template** in `references/handoff-template.md` — replace EVERY
   `[TODO: ...]`. Be specific: file paths WITH line numbers, before→after tables for
   config/prod/knob changes (and the exact revert), exact resume commands, commit
   SHAs, and the WHY (rationale) for decisions — not just the WHAT. The most
   important section is **Important Context (read before doing anything)**. Never
   paste secrets — env-var NAMES only.
3. **Validate** before storing (write the draft to a temp file or pipe it):
   `python3 ${CLAUDE_PLUGIN_ROOT}/skills/session-handoff/scripts/validate_handoff.py <draft>`
   Fix until the verdict is READY (score ≥70, no `[TODO:]`, required sections
   complete, **no secrets**).
4. **Store + confirm** — `store_session_handoff(content="<validated handoff>")`.
   Report the score and the #1 next step. (Chaining: see below.)

## RESUME workflow
1. **Find** the latest handoff: `recall_session_handoff` (or
   `bash ${CLAUDE_PLUGIN_ROOT}/skills/session-handoff/scripts/list_handoffs.sh`).
2. **Check staleness** before trusting it:
   `python3 ${CLAUDE_PLUGIN_ROOT}/skills/session-handoff/scripts/check_staleness.py <handoff>`
   VERY_STALE → re-explore before acting.
3. **Read it in full** (and the one it "Continues from", if any).
4. **Verify context** — follow `references/resume-checklist.md` (right repo/branch,
   blockers resolved?, assumptions still valid?, critical files still exist?).
5. **Recall knowledge cheaply** — `recall_code_knowledge(query="<task/file/error>")`
   → `get_code_knowledge(ids=[…])` for the few that matter.
6. **Begin** at "Immediate next steps" #1 (honor `(USER)` markers — those need the operator).

## Chaining
A new handoff supersedes the prior one. Set `Continues from:` to the previous
handoff's title/timestamp and carry still-true facts into "Architecture &
Carried-Forward Context" so the lineage stays intact across a long project.

## Handoff vs durable knowledge (JarvisCopilot)
The handoff captures session-specific state (run results, dated findings, where you
left off). **Durable, reusable facts** (a non-obvious bug/fix, repo structure, a
gotcha, a decision) belong in *knowledge* instead — store them SHORT (1-3 sentences)
with `store_code_knowledge` as you go (see the code-memory skill). To correct rather
than duplicate, `edit_code_memory(id, …)` or `delete_code_memory(id)` (ids come from
the recall tools).

## Resources
| Path | Purpose |
|------|---------|
| `scripts/gather_git_context.sh` | Pre-fill real git metadata for the handoff |
| `scripts/validate_handoff.py [file\|-]` | Completeness + secret scan + 0-100 score |
| `scripts/check_staleness.py [file\|-]` | FRESH/STALE assessment vs current git |
| `scripts/list_handoffs.sh [N]` | List stored handoffs for this project |
| `references/handoff-template.md` | The template to fill |
| `references/resume-checklist.md` | Verification checklist for resuming |
