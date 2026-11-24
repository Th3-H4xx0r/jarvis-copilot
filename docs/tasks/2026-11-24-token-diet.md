# 2026-11-24 — Token diet (cheaper, faster, same intelligence)

Spec: docs/superpowers/specs/2026-11-24-token-diet-design.md · Plan: docs/superpowers/plans/2026-11-24-token-diet.md

Found: the World news cron (Sonnet via a router mislabel) was ~85% of Anthropic spend; Pranav deleted the integration 2026-11-24.

1. [x] Todo due alerts → no-model script
   - ✅ ac90fc5a8f; live 07:30 UTC: job 2fbd1954f11a is no_agent (script todo_due_alerts.py); dry run silent; signed push path verified.
2. [x] Thinking blocks sent back unchanged + kept in web history
   - ✅ e2d651962f; live: 3-step Sonnet loop reads 11786 → 11883 with ~100-token writes per step, no signature errors.
3. [x] Cache lifetimes
   - ✅ fdfe7fd7e1 (one-shot 5m) + 6b788b5527: Found live that the old 1h/5m marker mix made every NEXT turn miss the cache entirely (read 0). Now uniform: chats 1h, one-shot 5m. Live: turn 2 read 11992 (all of turn 1), turn 3 read 13650.
4. [x] User messages keep their per-turn additions (deduped)
   - ✅ 2fb6620aa5 + review fixes d658f65d60 (no image data kept, gateway replay, safer dedupe).
5. [x] Node notes → node agent's system tail (web); gateway keeps them in the turn (shared agent)
   - ✅ 0017262fb5 + d658f65d60.
6. [x] Lighter fixed prompt
   - ✅ 5856979aa2; server config always_loaded_tokens 8000 → 4000 (backup config.yaml.bak-2026-11-24-token-diet). Deferred list ~0.7k tokens in a test agent. Skills catalog unchanged (~3.9k): descriptions were already ≤60 chars.
7. [x] Memory prefetch overlaps turn setup; route logging ("harness route:" in agent.log)
   - ✅ 3473ad3108.
8. [x] Log review / one-shot / auxiliary calls (message_usage session_id usage:<source>)
   - ✅ 39a60a7c39 + async in d658f65d60; live rows: usage:review, usage:aux:memory_extraction, usage:agent:cli.
9. [x] Full suite (same 349 failures as base, none new), Opus review (fixed 2 critical + 5 important), deployed 07:30 + 07:39 UTC, live checks above.

## Shipped
- Server at 6b788b552, webui + gateway restarted 07:39 UTC (healthy 302).

## For you
- Check Insights → Costs tomorrow: scheduled spend should be ~$0.10/day (email monitor only).
- Skills catalog (~3.9k tokens) only shrinks further by listing names only — a skill-selection trade-off, your call.
- Pre-existing: resumed sessions rebuild their system prompt (3 tests in test_system_prompt_restore fail on base too) → one cache rewrite on the first turn after a restart / CLI resume.
- Pre-existing: voice turns send thinking disabled, which Sonnet 5.5 rejects per the API docs — worth a look.
- The Default harness router labels schedule prompts "computer" (→ Sonnet); route decisions are now in agent.log to check chats.
