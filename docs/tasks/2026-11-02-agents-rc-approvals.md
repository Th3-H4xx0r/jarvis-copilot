# 2026-11-02 — Agents: Remote Control, new-session sheet, usage, long-running approvals + view

Order: build everything → parallel bug sweep → deploy (server + jc-client + Mac) → iPhone OTA (release.sh).

1. [ ] **Remote Control toggle in the new-session sheet (+ on Agents).** On → the session starts in Claude Code Remote Control mode (`claude --remote-control [name]`), for both server and Mac sessions.
   - Built: `remote_control` flag server → `claude --bg --remote-control=<folder>`; Mac via the `agent_launch` frame (needs `jc-client update`). Toggle remembered, hidden for Codex.
2. [ ] **New-session sheet: big UI revamp** — match the modern Apple / Jarvis styling of the other pages.
   - Built: nav bar, glass Run-on / Agent tiles, folder card, options card, Remote Control card, first-message card, pinned Start button.
3. [ ] **Claude usage on the Agents tab** — only Codex usage shows there; Settings shows Claude usage fine.
   - Cause: Agents only read statusLine-relayed numbers. Built: falls back to the OAuth usage snapshot Settings uses.
4. [ ] **Long-running session approvals** — the Agents session screen shows "Needs approval" + "Allow or deny the request above first." with no Allow/Deny controls (screenshot IMG_9685). Also show Allow / Deny right in the main chat (iPhone + web) for long-running sessions.
   - Cause: a Background job waits on a hidden worker session nobody draws; Agents only got a bare "needs approval" note; the iPhone chat never drew command approvals at all.
   - Built: every Jarvis approval is an Agents request (`webui/api/jarvis_approvals.py`) → buttons on Agents, push (job / unwatched chat), Live Activity; job card carries Allow/Always/Deny (iPhone + web); iPhone chat draws a command approval bar.
5. [ ] **Long-running session view** — open a long-running session from its card in the main chat; see everything it does in full chat form (reuse the regular chat).
   - Built: server job feed + `/api/harnesses/jobs/<chat>/<job>/view|stream` + saved transcripts; iPhone `HarnessJobSheet` (ChatConversationView, read-only); web modal.

## Shipped

## For you

- The Mac **voice library** (`mac_app/build.sh`) doesn't build, and hasn't since 51af68c078 (6 days):
  shared voice files use phone-only types (`LiveActivityCoordinating`, `TalkHereBridge`), and
  `ChatModels.swift` used `ChatFileRefs`, which I've guarded. The Mac app itself (`build-app.sh`) is unaffected. Not part of this work.
