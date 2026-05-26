---
name: code-memory
description: "Use JarvisCopilot's shared code-memory to recall project context and store learnings/handoffs. Use at the start of work and whenever you learn something durable about the project."
---

# JarvisCopilot code-memory (jarviscopilot-code-assist)

This project's coding context lives in JarvisCopilot's shared, project-scoped
code-memory — the SAME store used by the JarvisCopilot TUI, so context carries
across both surfaces (scoped by the repo's git remote / directory).

- **At session start** the SessionStart hook already registered the project and
  injected the recalled knowledge + latest session handoff. Read it before
  diving in. To pull more on demand: `recall_code_knowledge`, `recall_session_handoff`.
- **Store durable learnings as you go** with `store_code_knowledge`
  (`entry_type`: `bug` | `fix` | `repo_structure` | `gotcha` | `decision` | `note`)
  — after fixing a non-obvious bug, mapping repo structure, hitting a gotcha, or
  making an architectural decision.
- **Before finishing**, call `store_session_handoff` with what you did, the
  current state, and open threads, so the next session (here or in the
  JarvisCopilot TUI) continues seamlessly.
- Also available: `query_memory` (JarvisCopilot's general MEMORY.md / USER.md);
  `ask` (one-shot question to the JarvisCopilot agent — its model, skills, and
  memory; use for reasoning/help, slower than recall); `run_skill` (run a named
  JarvisCopilot skill); and `register_project` (normally automatic via the hook).
