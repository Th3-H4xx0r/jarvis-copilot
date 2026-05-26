# Resume Checklist

Follow this when resuming from a handoff so you continue with zero ambiguity.

## Pre-resume
- [ ] `recall_session_handoff` and read the latest handoff IN FULL (it's the head;
      older entries are the chain). If it says "Continues from", skim that one too.
- [ ] Confirm you're in the right repo, and the branch matches `Branch:` (or know why it differs).
- [ ] Check staleness: `python3 scripts/check_staleness.py <handoff-file>` (or eyeball
      `Created:` + `git log --oneline` since `HEAD:`). VERY_STALE → re-explore before trusting it.

## Context validation
- [ ] Read "Important Context" thoroughly.
- [ ] Are the "Assumptions" still valid? Have the "Blockers/open questions" been resolved?
- [ ] Review "Potential gotchas" to avoid known traps.
- [ ] Do the "Critical Files" still exist at the stated paths? If not, the codebase moved on — re-explore.

## State verification
- [ ] `git status`, `git branch --show-current`, `git log --oneline -10` — compare to the handoff.
- [ ] Set any required env-var NAMES listed (you supply the values).
- [ ] Start any "Active processes" the work needs.
- [ ] Pull durable knowledge: `recall_code_knowledge(query="<task/file/error/symbol>")`
      → `get_code_knowledge(ids=[…])` for the few that matter.

## Execute
- [ ] Start with "Immediate next steps" #1 (honor any (USER) markers — those need the operator).
- [ ] Apply the documented "Key Patterns / Conventions".
- [ ] As you learn durable facts, store them SHORT via `store_code_knowledge`; edit/delete by id to avoid duplicates.
- [ ] For a long session, store a fresh handoff (with `Continues from:` the current one) before stopping.

## Red flags — STOP and verify
- Files named in the handoff don't exist → codebase changed significantly.
- Branch diverged a lot (`git log`) → re-orient before editing.
- An assumption is clearly false now → reassess the approach.
- A "resolved" blocker is blocking you again → escalate to the user.
