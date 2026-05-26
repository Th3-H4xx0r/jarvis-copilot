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
carries across both surfaces.

## At the START of coding work in a repo
1. `code_memory action=recall kind=sessions limit=3` — read the latest handoff(s):
   what was last done, current state, open threads.
2. `code_memory action=recall kind=knowledge limit=20` — durable learnings: known
   bugs, fixes, repo structure, gotchas, decisions.
Use these to continue seamlessly.

## DURING work — store durable learnings as you go
`code_memory action=store kind=knowledge entry_type=<bug|fix|repo_structure|gotcha|decision|note> content="..."`
Store when you: fix a non-obvious bug, map out repo structure, hit a gotcha, or
make an architectural decision.

## When WRAPPING UP
`code_memory action=store kind=sessions entry_type=jarviscopilot content="<what you did; current state; open threads/next steps>"`
so the next session (here or in Claude) picks up with full context.

Project scope is automatic (derived from the repo's git remote / directory).
