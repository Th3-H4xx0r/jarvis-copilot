---
name: code-memory
description: "Browse and manage JarvisCopilot's project code-memory by chatting: list projects, show stored knowledge/handoffs, add notes, delete entries/projects. Use when the user asks about their coding projects or wants to view/change stored coding knowledge."
version: 1.0.0
platforms: [linux, macos, windows]
metadata:
  jarviscopilot:
    tags: [code, memory, projects, manage, recall, delete]
---

# Interacting with the code-memory

Use the `code_memory` tool to answer the user's questions about their coding
projects and to view/change stored coding knowledge. It is the same store the
web-UI "Code Memory" tab and Claude Code's jarviscopilot-code-assist plugin use.

- **"What projects do I have?"** → `code_memory action=list_projects`.
- **"Show me X's knowledge / what do you know about X?"** →
  `code_memory action=recall kind=knowledge project=<slug-or-name>` (and
  `kind=sessions` for session handoffs). If the user names a project, match it
  against `list_projects`; otherwise use the current repo (omit `project`).
  For a large store or a targeted question, prefer `action=search query="…"`
  (compact ranked rows) then `action=get ids=[…]` for the full bodies.
- **"Remember / add a note that …"** →
  `code_memory action=store kind=knowledge entry_type=<bug|fix|repo_structure|gotcha|decision|note> content="…"`.
  Store a SHORT declarative fact (1-3 sentences); keep run-specific results in a
  session handoff (`kind=sessions`), not knowledge.
- **"Edit / fix / shorten that entry"** → find its `id` via `recall`/`search`,
  then `code_memory action=edit id=<id> content="…"` (optionally `entry_type=…`).
  Edits in place, preserving the timestamp.
- **"Forget that … / delete that entry"** → find its `id` via `recall`/`search`,
  then `code_memory action=delete id=<id>` (precise — removes only that entry).
- **"Wipe / delete all memory for X"** → `code_memory action=delete_project project=<X>`.
  **Always confirm with the user before delete_project** — it removes everything
  for that project and cannot be undone.

Summarize results conversationally rather than dumping raw entries. This is the
general browse/edit interface; the `session-handoff` skill covers start/end-of-
session continuity.
