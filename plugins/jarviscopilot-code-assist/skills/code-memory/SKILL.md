---
name: code-memory
description: "Use JarvisCopilot's shared project code-memory to recall context and store learnings. ALWAYS recall at the start of a task and store durable facts as you go. Use whenever working in a code repository."
---

# JarvisCopilot code-memory (jarviscopilot-code-assist)

This project's coding context lives in JarvisCopilot's shared, project-scoped
code-memory — the SAME store the JarvisCopilot TUI uses, so context carries
across both surfaces (scoped by the repo's git remote / directory). Using it is
**not optional**: it is how you avoid relearning this repo every session.

## RECALL — at the start of any non-trivial task

The SessionStart hook injects a small **digest** (counts + latest handoff + a few
key facts). That is a teaser, not the whole store. Before doing real work:

1. Run `recall_code_knowledge` with a `query` describing the task (e.g. the
   feature, file, error string, or symbol). It returns **compact rows**:
   `id  [type]  one-line summary` — cheap, no bodies.
2. Pick the few ids that look relevant and call `get_code_knowledge(ids=[...])`
   to read their full bodies. Fetch only what you need; don't dump everything.
3. `recall_session_handoff` for what the last session left open.

This search → pick ids → fetch pattern is what keeps recall token-cheap, so
recall **often** and **early** — it's nearly free.

## STORE — immediately, proactively, and SHORT

The moment you learn something durable, call `store_code_knowledge` — don't batch
it to the end (you'll forget). Store when you:

- fix a **non-obvious bug** (`bug` then `fix`), hit a **gotcha**, learn the
  **repo structure**, make a **decision**, or find an approach **works/fails**.

**Write a short, declarative fact — 1-3 sentences (~400 chars), one fact per
call.** The tool returns a `warning` if it's too long; if so, trim to the durable
nugget or split it. Quality bar (from the agent's memory discipline):

- ✅ "`prot=` in the 'Effective config' log line = `watchlist_sector_protected_slots`, not `protect_days`."
- ❌ A 200-word essay, OR "run 404780 returned +152% on 2026-05-26…" (run-specific
  results, dollar figures, dated verdicts, PR/commit SHAs, "Phase N done" are
  **stale within a week** — they do NOT belong in knowledge).

Run-specific findings and "where I left off" go in a **session handoff**, not
knowledge: call `store_session_handoff` (what you did, current state, open
threads). The Stop hook will also remind you periodically — but store as you go.

If a fact supersedes one you recalled, store the corrected version concisely and
say what changed; don't pile on many near-identical entries (the periodic
`jc-client code-memory distill` pass merges and trims near-duplicates).

## Other tools

`query_memory` (JarvisCopilot's general MEMORY.md / USER.md); `ask` (one-shot
question to the JarvisCopilot agent — its model, skills, and memory; for
reasoning/help, slower than recall); `run_skill` (run a named JarvisCopilot
skill); `register_project` (normally automatic via the hook).
