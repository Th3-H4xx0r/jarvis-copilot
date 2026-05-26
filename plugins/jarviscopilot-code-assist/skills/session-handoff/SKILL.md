---
name: session-handoff
description: "Use when starting, pausing, resuming, or finishing coding work in a repo, when context is getting full, at a milestone, or when the user says 'save state', 'create handoff', 'I need to pause', 'resume from', or 'continue where we left off'. Writes comprehensive handoffs into JarvisCopilot's shared store so they carry across Claude Code and the JarvisCopilot TUI, per project."
---

# Session handoff (jarviscopilot-code-assist)

A **handoff** is a comprehensive snapshot of a session that lets the next agent —
you in a later session, or the JarvisCopilot TUI — resume with zero ambiguity.
Handoffs are stored in JarvisCopilot's shared, project-scoped code-memory (the same
store as `recall_code_knowledge`), so they carry across both surfaces. Project
scope is automatic (git remote / directory).

## Mode selection
- **RESUME** — starting or continuing work; "load handoff", "resume from",
  "continue where we left off" → RESUME workflow.
- **CREATE** — wrapping up, pausing, "save state", "create handoff", context
  getting full, or a milestone reached → CREATE workflow.
- **Proactive** — after substantial work (5+ file edits, hard debugging, or a key
  decision) with no recent handoff, offer: *"We've made real progress — want me to
  store a session handoff so the next session picks up seamlessly?"*

## RESUME — at the START of work
1. `recall_session_handoff` — read the latest handoff(s) IN FULL. The newest is the
   head; older ones are the chain/history.
2. **Verify the context still holds before acting:**
   - Right repo and branch? (`git status`, `git branch --show-current`, `git log --oneline -10`)
   - Have the handoff's *Blockers/Open questions* been resolved? Do its *Assumptions* still hold?
   - Do the *Critical files* still exist? If the codebase moved on, re-explore before trusting the handoff.
3. Pull durable knowledge cheaply: `recall_code_knowledge` with a `query`
   (task/file/error/symbol) → `get_code_knowledge(ids=[…])` for the few that matter.
4. Begin with **Next steps #1** from the handoff; follow its *Key patterns* and avoid its *Gotchas*.

## CREATE — when wrapping up, pausing, or context is filling
Fill the template below and store it: `store_session_handoff(content="<filled template>")`.

- Be specific and concrete: file paths with line numbers, and WHAT **and WHY**
  (rationale), not vague summaries.
- **Never paste secrets** (tokens, keys, passwords) — env-var *names* only.
- **Chaining:** a new handoff supersedes the prior one; open with a one-line
  `Continues from: <prev ts/title>` so the lineage is clear.

### Handoff template
```
# Handoff: <task title>
Continues from: <prev handoff ts/title, or "—">
Current state: <one paragraph — what was being worked on, status, where it left off>

Work completed:
- <task> — <what was done>
Files touched: <path:line — change — why>
Decisions: <chose X over Y — because …>

Pending:
- Next steps (ordered): 1) … 2) … 3) …
- Blockers / open questions: <…> — needs: <…>
- Deferred: <… — why>

Context to resume:
- Important: <the must-know facts the next agent needs>
- Assumptions: <what was taken to be true>
- Gotchas: <edge cases / non-obvious behavior>
- Env / processes: <dev servers, watchers, required env-var NAMES — no values>
```

## Handoff vs durable knowledge
The handoff captures session-specific state (run results, dated findings, where you
left off). **Durable, reusable facts** (a non-obvious bug/fix, repo structure, a
gotcha, a decision) go in knowledge instead — store them SHORT (1-3 sentences) with
`store_code_knowledge` as you go (see the code-memory skill). To correct rather than
duplicate, `edit_code_memory(id, …)` or `delete_code_memory(id)` (ids come from the
recall tools).
