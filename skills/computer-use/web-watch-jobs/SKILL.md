---
name: web-watch-jobs
description: "Watch prices, packages and flights without noisy cron runs."
version: 1.0.0
author: Pranav Krishna, JarvisCopilot
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [cron, monitoring, price-tracking, package-tracking, flights, alerts, computer-use]
    related_skills: [web-task-router, flight-travel-search, shopping-research]
---

# Web Watch Jobs Skill

Sets up recurring checks on the web: price drops, back-in-stock, package
status, fare changes, a page changing. It proves the source works before
scheduling, uses a cheap script when no judgment is needed, checks at a sane
cadence, and tells him when the watcher itself is broken instead of failing
silently. One past flight-watch job ran every 5 minutes against a blocked site
140 times in a day and never told him anything.

## When to Use

- "Tell me when <thing> drops below $X", "watch this flight price", "track my
  package", "let me know when it's back in stock", "check <page> every day".
- Changing or stopping an existing watcher ("stop tracking…", "check less often").

## Prerequisites

- The `cronjob` tool (actions: create, list, update, pause, resume, remove, run).
- Scripts live in the server's `scripts/` folder under the Jarvis home
  (relative `script` paths resolve there). `.py` runs with Python, `.sh` with bash.
- Read `web-task-router`'s reachability table. A source the server can't read
  can't be watched from the server.

## How to Run

1. **Prove the source now.** Do one manual check with the same method the job
   will use (`browser_extract`, an API, or the email route below). Show him the
   current value. If the server can't read it (bot wall, empty page), don't
   schedule. Say so and offer an alternative source.
2. **Pick the job type:**

| Need | Job | Why |
|---|---|---|
| A number crossing a threshold, a status change, a page diff, from a plain page or API | `no_agent: true` + `script` | no tokens; empty stdout = no message |
| Pages that need a browser or judgment (Google Flights fares, "is any of these a good deal") | LLM job: `prompt` + `skills: ["flight-travel-search"]` or `["web-task-router"]` | the agent reads and decides |

3. **Pick the cadence** (never under 30 minutes for web pages):

| Watch | Cadence |
|---|---|
| Flight fares | `every 6h` (or `0 8,20 * * *`) |
| Retail price / stock | `every 4h`; `every 1h` only for drops he's waiting on today |
| Package tracking | `every 3h`, stop after delivery |
| A page changing | `0 9 * * *` (daily) unless he says otherwise |

4. **Give it an end:** `repeat` count or an end date in the prompt ("stop after
   Dec 20"). Package jobs remove themselves once delivered.
5. Create it with `cronjob {action: "create", name, schedule, prompt | script, no_agent, repeat}`.
   Then `cronjob {action: "run", job_id}` once and check the first result is right.
6. Tell him: what's watched, the threshold, how often, when it ends, and how to stop
   it ("say 'stop the AirPods watch'").

## Quick Reference

**Script watcher pattern** (`no_agent: true`). The script keeps its own state
file next to it:
- Fetch the value with `requests`/`urllib` (an API or a plain page).
- Compare it with the last value saved in a small JSON state file.
- Print **one human sentence** only when something he cares about changed
  ("AirPods Pro 3 is $179.00 at Walmart (was $199.00): <link>"). Otherwise print
  nothing.
- Count consecutive failed fetches in the state file. On the 3rd in a row, print
  "Watcher for <thing> can't read <site> (blocked/changed). Paused checks; say
  'fix it' to switch source." and exit non-zero so the scheduler alerts him. Never
  stay silent on errors.

**LLM job prompt pattern:** state the item, the exact source URL(s), the threshold,
and the output rule in one paragraph:
- Reply `[SILENT]` only when the check worked and nothing crossed the line.
- If a source is blocked or empty, say exactly that in one line. Do NOT reply
  `[SILENT]`.
- Include the price, where, the link, and the time checked.

**Packages:**
- Best source: his shipping emails (`himalaya` skill: search the carrier name +
  "shipped"/"delivered").
- Carrier pages are heavy: FedEx is slow, 17track needs JS. Try `browser_extract`
  once; if empty, fall back to the emails or ask for the retailer's order page on
  his Mac.

## Procedure

1. Restate the watch in one line and get the threshold if it's missing (one question).
2. Steps 1–6 above.
3. When it fires, the message has the value, the source link and what to do next
   (buy link, flight booking link).
4. `cronjob {action: "list"}` before creating, so you don't duplicate an existing watcher.

## Pitfalls

- Scheduling before proving the source. That's how a job runs 140 times on a wall.
- Every-5-minute web checks: they get the server IP flagged and cost tokens.
- `[SILENT]` on failure: failures must speak.
- Watching a variant he didn't ask for (refurbished, other color, other dates).
- Leaving jobs running forever: always an end or a stop condition.

## Verification

- The first manual check returned a real value from the planned source.
- `cronjob run` once produced the expected output (or correct silence).
- The job has a cadence ≥ 30 min, an end, and a failure message path.
