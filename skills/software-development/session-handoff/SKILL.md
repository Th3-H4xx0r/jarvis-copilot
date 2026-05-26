---
name: session-handoff
description: "Recall/store project coding context across sessions (Claude ↔ JarvisCopilot). Use when starting or finishing coding work in a repo."
version: 1.0.0
platforms: [linux, macos, windows]
metadata:
  jarviscopilot:
    tags: [code, memory, handoff, session, continuity, project]
---

# Session handoff & project code-memory

This project's coding knowledge and session history are stored in the shared
code-memory (the `code_memory` tool), scoped to the current repo. The SAME store
is used by Claude Code (via the jarviscopilot-code-assist MCP server) — so context
carries across both surfaces. Use it on EVERY coding task; it is not optional.

## At the START of coding work in a repo — recall (token-cheap)
1. `code_memory action=recall kind=sessions limit=3` — the latest handoff(s):
   what was last done, current state, open threads.
2. `code_memory action=search kind=knowledge query="<task / file / error / symbol>"`
   — returns COMPACT rows (`id  [type]  one-line summary`), no bodies.
3. `code_memory action=get ids=["<id>", ...]` — full bodies for only the few rows
   that look relevant. (Use `action=recall kind=knowledge` only when you truly
   want everything; prefer search → get.)

## DURING work — store durable facts as you go, SHORT
`code_memory action=store kind=knowledge entry_type=<bug|fix|repo_structure|gotcha|decision|note> content="..."`
Store the moment you: fix a non-obvious bug, map repo structure, hit a gotcha,
make a decision, or find an approach works/fails — don't batch it.

Write a **short declarative fact, 1-3 sentences (~400 chars), one per call**. The
tool returns a `warning` if it's too long — trim to the durable nugget or split.
Do NOT store run-specific results, dollar figures, dated verdicts, PR/commit
SHAs, or "Phase N done" (stale within a week) — those go in the handoff below.

- ✅ "`prot=` in the 'Effective config' log line = `watchlist_sector_protected_slots`, not `protect_days`."
- ❌ A 200-word essay, or "run 404780 returned +152% on 2026-05-26…" (run-specific → a handoff, not knowledge).

## When WRAPPING UP — store a handoff
`code_memory action=store kind=sessions entry_type=jarviscopilot content="<what you did; current state; open threads/next steps>"`
so the next session (here or in Claude) picks up with full context.

## FIX or REMOVE an entry
Every row from `search`/`recall` carries an `id`. To keep memory correct instead
of piling on duplicates:
- `code_memory action=edit id="<id>" content="…"` (optional `entry_type=…`) —
  edits that entry in place, preserving its timestamp.
- `code_memory action=delete id="<id>"` — removes just that one entry.

Project scope is automatic (derived from the repo's git remote / directory).
