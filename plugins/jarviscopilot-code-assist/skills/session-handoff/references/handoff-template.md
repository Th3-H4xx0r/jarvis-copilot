# Handoff Template

Replace EVERY `[TODO: ...]` placeholder with specific, concrete content, then store
the finished document with `store_session_handoff(content="...")`. The validator
fails if any `[TODO:` remains. Prioritize **Current State**, **Important Context**,
and **Immediate Next Steps** — those are required. Be specific: file paths WITH line
numbers (`src/x.py:142`), before→after tables for config/knob changes, exact commands
to resume, commit SHAs, and the WHY (rationale) behind decisions — not just the WHAT.
Never paste secrets (tokens, keys, passwords, connection strings) — env-var NAMES only.

The metadata block comes from `scripts/gather_git_context.sh` — run it first and
paste the real values. The validator and staleness checker parse `Created:`,
`Branch:`, and `HEAD:`.

---

# Handoff: [TODO: task title]

## Session Metadata
- Created: [TODO: UTC timestamp, e.g. 2026-05-26 10:00 UTC]
- Project: [TODO: jarviscopilot project slug — the repo's git remote / dir]
- Branch: [TODO: branch (ahead N / behind M vs upstream, or "in sync"; merged to main?)]
- HEAD: [TODO: short-sha subject]
- Session commits: [TODO: start-sha..head-sha (N new this session: shas)]
- Working tree: [TODO: clean | dirty paths — note any auto-edited files to NOT stage]
- Continues from: [TODO: prior handoff title/ts, or "— (head)"] · Supersedes: [TODO: older handoffs or "None"]

## Current State Summary
[TODO: One paragraph — what was being worked on, current status, and exactly where
things left off. One short paragraph per arc if the session had several.]

## Architecture & Carried-Forward Context (still true)
[TODO: For chained work, the durable system facts the next agent needs (stack, key
topology, conventions) that stay true across sessions — pull stable ones from
recall_code_knowledge rather than re-deriving. Write "— (self-contained)" if N/A.]

## Codebase Understanding
### Critical Files
| File | Purpose | Relevance to this task |
|------|---------|------------------------|
| [TODO: path:line] | [TODO: what it does] | [TODO: why it matters here] |

### Key Patterns / Conventions
[TODO: patterns, idioms, project conventions to follow — test commands, commit
footer, files never to stage, MCP/tool quirks, etc.]

## Work Completed
### Tasks finished
- [x] [TODO: task — what was done]

### Commits
- `[TODO: sha]` [TODO: message — what it changed] [TODO: (pushed / local)]

### Files modified
| File | Changes | Rationale |
|------|---------|-----------|
| [TODO: path:line] | [TODO: what changed] | [TODO: why] |

### Decisions made
| Decision | Options considered | Rationale |
|----------|--------------------|-----------|
| [TODO: chose X] | [TODO: X, Y, Z] | [TODO: why X] |

[TODO: for config/knob/prod changes, add a before→after table AND the exact revert,
e.g. "ROLLBACK = restore a=14,b=8 and delete flag Z". Delete this line if N/A.]

## Pending Work
### Immediate next steps (ordered)
1. [TODO: most critical next action — mark (USER) if it needs the operator, e.g. a deploy/backtest]
2. [TODO: next]
3. [TODO: next]

### Blockers / open questions
- [ ] [TODO: Blocker — needs: what unblocks it / Question — suggested resolution]

### Deferred
- [TODO: item — why deferred, or "None"]

## Context for Resuming Agent
### Important Context (READ BEFORE DOING ANYTHING)
[TODO: the single most important section — must-know facts, live side effects,
anything dangerous or surprising the next agent has to know first.]

### Assumptions Made
- [TODO: what was taken to be true and not re-verified]

### Potential Gotchas
- [TODO: edge cases, silent behavior, non-obvious traps, test baselines]

## Environment State
- Tools / services: [TODO: DBs, hosts, access — read-only? Tailscale? reachable vs denied]
- Active processes: [TODO: running backtests/dev servers/watchers with IDs, or "None"]
- Environment variables: [TODO: NAMES only — never values]
- Resume commands: [TODO: exact commands to re-establish state / re-run tests / pull logs]

## Related Resources
- [TODO: specs/plans, prior handoffs in the chain, dashboards, tickets]
