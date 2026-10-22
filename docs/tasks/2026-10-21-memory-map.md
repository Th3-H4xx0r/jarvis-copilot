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
- [x] Backfill mapped ~7k memories (parallel: ~170/min after batching + no-thinking); 667 nodes / 11k links
- [x] Eval: venue case passes first try (brief + retrieval); 2/6 vs 1/6 old (other 4 = ESP32 board follow-ups)
- [x] iPhone build installed; context snapshot arrived (13 events, CT)
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

## Phase 2 + 3 (2026-10-22)
- [x] Memory map screen: web + iPhone (Long-term Memory → Map/List; you at the center; filters; node sheet with fix tools; Recent recalls; "memories used" chip)
- [x] Every source into the map: calendar, reminders, email reports, integration reports, health (day finished), places, drives
- [x] Cleanup & map: Stop button, clear naming, runs from anywhere shown
- [x] Parallel bug sweep (server 14, web 11, iOS 12) → fixed
- [ ] He opens Long-term Memory → Map and tries it; check gestures/VoiceOver on device
- [x] Recheck live recall latency after the backfill finishes → slow: see Latency below
- [ ] Health + places memories appear from tomorrow (written for the day just finished)

## Latency (2026-10-22, "messages take way too long")
Measured on the server: before the memory map, prep before the model call was ~0.07 s; after it, 0.3–0.7 s (up to 1.5 s during the backfill). Nearly all of it was ONE bge-m3 embed of "message + previous message + names" (0.55–0.65 s on the 4-vCPU CPU); the rest of recall is <20 ms.
- [x] Embed starts as the message arrives (webui `_warm_memory_query`), overlapping the ~0.3–0.7 s agent build
- [x] Embed only his message; the previous message's vector comes from cache (it was last turn's query) and is blended in
- [x] No recall for small talk ("Hello", "Yooo", "What's up") — no embed, no injected memories
- [x] Deploy + check `jarvis_memory prefetch … ms` on live turns → 8–82 ms on real questions (embed wait 2–57 ms), 0 ms small talk; "Yoo" (2 o's) slipped through → fixed
Other time in a turn (not memory): agent build 0.3–0.7 s; ~1.4–2.2 s between the phone's tap and the server's turn start/finish (network + new-chat round trip); first two turns of a chat had ~10k uncached prompt tokens.
- [ ] First chat after every webui restart: /api/chat/start sat 6.8–7.7 s in resolve_model_provider — `has_aws_credentials()` → botocore probing EC2 instance metadata (not on AWS). Fixed by systemd drop-in `AWS_EC2_METADATA_DISABLED=true` (webui + gateway; check 4.2 s → 0.17 s); live after next webui restart. Also: setup 2.1 s on the first turn after a restart (cold), ~0.35–0.7 s after.
- [ ] New chat's first message only 77% cached: volatile system tail (MEMORY/USER ~4.4k, chat guidance, date/model) after the last system marker → marker moved after the tail (e419f4d89); verify ~95% on first message after restart
- [ ] New chat +0.3 s setup: Anthropic /v1/models context-length lookup ran on every agent build (never saved to the context cache) → cached; verify after restart
- Router (Celeris decision, his Route harness) costs 230–270 ms before every message — by design; offer: overlap/skip for small talk
