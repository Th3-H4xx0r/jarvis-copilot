---
name: session-handoff
description: "Use when starting, pausing, resuming, or finishing coding work in a repo — or when the user says 'save state', 'create handoff', 'I need to pause', 'context is getting full', 'resume from', or 'continue where we left off'. Project-scoped, shared between Claude Code and the JarvisCopilot TUI."
version: 1.1.0
platforms: [linux, macos, windows]
metadata:
  jarviscopilot:
    tags: [code, memory, handoff, session, continuity, resume, project]
---

# Session handoff & project code-memory

A **handoff** is a comprehensive snapshot of a session that lets the next agent
resume with zero ambiguity. Handoffs (and durable knowledge) live in JarvisCopilot's
shared, project-scoped code-memory — the `code_memory` tool, the SAME store Claude
Code uses (via the jarviscopilot-code-assist MCP server) — so context carries across
both surfaces. Project scope is automatic (git remote / directory).

## Mode selection
- **RESUME** — starting or continuing work; "load handoff", "resume from",
  "continue where we left off" → RESUME workflow.
- **CREATE** — wrapping up, pausing, "save state", "create handoff", context
  getting full, or a milestone reached → CREATE workflow.
- **Proactive** — after substantial work (several file edits, hard debugging, or a
  key decision) with no recent handoff, offer: *"We've made real progress — want me
  to store a session handoff so the next session picks up seamlessly?"*

## RESUME — at the START of work
1. `code_memory action=recall kind=sessions limit=3` — read the latest handoff(s)
   IN FULL. The newest is the head; older ones are the chain/history.
2. **Verify the context still holds before acting:**
   - Right repo and branch? (`git status`, `git branch --show-current`, `git log --oneline -10`)
   - Have the handoff's *Blockers/Open questions* been resolved? Do its *Assumptions* still hold?
   - Do the *Critical files* still exist? If the codebase has moved on, re-explore before trusting the handoff.
3. Pull durable knowledge cheaply: `code_memory action=search kind=knowledge query="<task/file/error/symbol>"`
   → `action=get ids=[…]` for the few that matter (avoid dumping everything).
4. Begin with **Next steps #1** from the handoff; follow its *Key patterns* and avoid its *Gotchas*.

## CREATE — when wrapping up, pausing, or context is filling
Fill the template below and store it:
`code_memory action=store kind=sessions entry_type=jarviscopilot content="<filled template>"`

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

## DURING work — keep memory current (and SHORT)
Store durable, reusable facts as you go as **short** knowledge entries
(1-3 sentences, ~400 chars, one fact per call):
`code_memory action=store kind=knowledge entry_type=<bug|fix|repo_structure|gotcha|decision|note> content="…"`.
Keep run-specific results, dated verdicts, and numbers in the **handoff**, not in
knowledge — they go stale within a week.

- ✅ "`prot=` in the 'Effective config' log line = `watchlist_sector_protected_slots`, not `protect_days`."
- ❌ A 200-word essay, or "run 404780 returned +152% on 2026-05-26…" (run-specific → a handoff, not knowledge).

To correct rather than duplicate, edit/delete by `id` (ids come from search/recall):
`code_memory action=edit id="<id>" content="…"` (optional `entry_type=…`) or
`code_memory action=delete id="<id>"`.
