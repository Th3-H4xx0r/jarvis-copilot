# Memory map + first-try recall — 2026-10-21

Spec: docs/superpowers/specs/2026-10-21-memory-map-recall-design.md (gitignored) · Plan: docs/superpowers/plans/2026-10-21-memory-map-recall.md

## Shipped (server deployed 2026-10-22 03:53 UTC, commits 22605194cd..)
- [x] Recall on the current turn (not the previous one), with the last turn as context
- [x] Multi-channel recall: meaning, keywords (bm25, no filler words), people/places/events, role slots ("the venue"), time windows ("this weekend")
- [x] Memory map: event times, entities + roles, slots, supersession (old facts marked past), merged sources
- [x] Always-on "now" brief (coming up 14 d, active, people, health, inbox, messages waiting, home/car, tasks, pinned)
- [x] Vague references resolved only when nothing else names them (≤1.2 s)
- [x] One memory-model setting (default Haiku 5.5 on the API key) — web + iPhone
- [x] Phone pushes calendar + reminders + time zone; time zone follows the phone
- [x] Cleanup/backfill with backup + report (web + iPhone), Live = summaries only, merges keep every source
- [x] Personal eval (6 real misses mined; baseline old injection 1/6)

## Waiting on live checks
- [ ] Backfill finishes on the server (started 2026-10-22 ~04:00 UTC; log $HERMES_HOME/memory/backfill.log)
- [ ] Eval after backfill: `scripts/memory_eval.py compare` — venue case passes
- [ ] iPhone build installed; context snapshot arrives (calendar in the brief)
- [ ] He grants Reminders in Long-term Memory
- [ ] Ask "navigate to the venue"-style question live → right first time
- [ ] Glance at the cleanup report (merges / hidden trivia) and Restore anything wrong

## Deferred (minor)
- Old backups in $HERMES_HOME/memory/backups are never pruned (each run = one full copy)
- Deleting a merged fact from one chat's screen removes it from iMessage entirely (all chats)
- The gateway process (Telegram etc.) uses the default memory model for the vague resolver, not his setting
- jarvis_health latest_relapse picks the most recently logged relapse, not the latest `at`
- UTC ranges written with an ASCII hyphen aren't restamped
- Eval counts a memory as existing by created_at (event time for iMessage/Live)
