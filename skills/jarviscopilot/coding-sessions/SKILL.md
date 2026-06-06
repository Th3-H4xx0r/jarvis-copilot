---
name: coding-sessions
description: Launch and drive interactive Claude Code coding sessions from chat — start a coding agent on a project/task, see what running sessions are doing, send them follow-up messages, and stop them. Use when the user asks to "spin up claude on X", "have a coding agent do Y", "what's session N doing", or "tell that session to also Z".
version: 0.1.0
platforms: [all]
metadata:
  jarviscopilot:
    tags: [coding, claude-code, sessions, orchestration]
---

# Coding Sessions

Jarvis can launch and supervise **Claude Code** coding sessions on the user's
behalf. Each session is a real, interactive `claude` running in its own tmux
session on this host — live-watchable in the WebUI/mobile "Coding" tab — and is
auto-equipped with the `jarviscopilot-code-assist` plugin (so the session can
reach back into Jarvis for memory/skills) and seeded with Jarvis memory at launch.

You drive sessions with these tools (toolset `coding_sessions`):

- **`coding_session_launch`** — start a session. Requires `cwd` (the absolute
  project directory). Optional: `title`, `prompt` (the initial task), `model`
  (`opus`/`sonnet`/`haiku`). Returns the session record (including its `id`).
- **`coding_session_list`** — list tracked sessions (optional `status` filter:
  `running`, `idle`, `stopped`, …). Use to answer "what's running?".
- **`coding_session_status`** — details for one session by `session_id`.
- **`coding_session_message`** — send an instruction INTO a running session
  (`session_id` + `text`). This is how you relay the user's follow-ups, e.g.
  "tell the session to also fix the failing tests".
- **`coding_session_stop`** — stop a session (`session_id`).
- **`coding_project_create`** / **`coding_project_list`** — register/list named
  project directories sessions can run in.

## How to use it

- When the user says something like *"spin up a coding session on
  ~/code/myapp to add dark mode"*, call `coding_session_launch` with that `cwd`
  and a `prompt` describing the task, then report the new session id.
- When they ask *"what's it doing?"* or *"how's session X going?"*, call
  `coding_session_status` / `coding_session_list` and summarize. (Rich live
  output + a subagent tree live in the "Coding" tab; this skill is the
  conversational control surface.)
- When they give a follow-up instruction for a specific session, call
  `coding_session_message`. Confirm which session if it's ambiguous.
- Only `coding_session_stop` when the user asks to stop/cancel, or the task is
  clearly done.

## Notes & failure modes

- Sessions need the `claude` CLI and `tmux` installed on this host. If they're
  absent the launch tool returns a clear error — relay it; don't retry blindly.
- The session runs agentically with its own tools; you are the supervisor, not
  the coder. Hand it a clear task, then monitor and relay.
- Memory is seeded as a `JARVIS-CONTEXT.md` in the project at launch and the
  session can also pull live memory via the code-assist plugin — you don't need
  to paste memory into the prompt yourself.
