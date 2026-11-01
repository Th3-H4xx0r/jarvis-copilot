---
name: cost-insights
description: "Answer what Jarvis's models and services cost."
version: 1.0.0
author: Pranav Krishna (th3-h4xx0r), JarvisCopilot
license: MIT
platforms: [linux, macos, windows]
metadata:
  jarviscopilot:
    tags: [Costs, Spending, Billing, API, Usage, Budget]
    category: productivity
    related_skills: []
---

# Cost Insights Skill

Answers spending questions from the Insights → Costs data: per-service spend, daily
trends, month-to-date, the projected month, balances, plan prices and budget. It reads
what the collector already stored. It never handles API keys or plan prices; the user
sets those on the Costs tab.

## When to Use

- "What am I spending on Jarvis / AI this month?"
- "Why was yesterday expensive?" / "What's my Anthropic bill looking like?"
- "How much have Parallel searches cost?" / "How much Ollama allowance is left?"
- "Am I on track for my budget?" / "Compare this month to last."

Not for: making models cheaper by changing config (that's a code/config task), or
token-floor questions about a single chat (use `session_search` / Insights → Usage).

## Prerequisites

The `cost_insights` tool (toolset `costs`). Data comes from the webui's collector, which
runs every 3 hours; there's nothing to configure for the tool itself.

## How to Run

Call `cost_insights`:

- `action="summary"`, `days=30` (or 7/90/365): totals, budget, per-service lines, trend.
- `action="service"`, `service_id="anthropic"`: one service's days, models, billing items.
- `action="services"`: every service with its status, plus what can still be connected.
- `action="refresh"`: pull fresh billing data first. Use it when the user asks for
  "right now" numbers or the last sync looks stale. It's slow (several APIs).

## Quick Reference

| status | meaning | how to say it |
|---|---|---|
| billing | provider's own billing API | state the number plainly |
| estimated | Jarvis's count × list price | say "about" / "≈" |
| subscription | plan price spread per day | "your $X/month plan" |
| needs_price | plan price not entered | ask them to add it on the Costs tab |
| error | billing API failed | give the error, fall back to the estimate |
| free | no cost | mention only if asked |

`api_equiv_usd` on a subscription = what the covered calls would cost on the pay-as-you-go
API. That's useful for "is my plan worth it" questions, but it isn't money spent.

## Procedure

1. Pick the period from the question (default 30 days; "this month" means `month_to_date_usd`).
2. Call `cost_insights` `summary`. If one service dominates or is asked about, call `service`.
3. Lead with the total and the top 2-3 services, then the trend (up/down vs previous period).
4. Mark estimates as approximate. Never present `needs_price` services as $0 spend; say the
   price is missing.
5. If they want a service connected or a price set, tell them where: Insights → Costs → the
   service → connect/plan price. Don't ask for keys in chat.

## Pitfalls

- Subscriptions with no start date start at the first day Jarvis has usage for, so the first
  weeks of history include plan costs.
- Anthropic estimates assume 1-hour cache writes when `prompt_caching.retention` is `long`.
  Connecting an Admin key gives exact billing.
- Parallel searches before the meter existed are estimated from chat history (`from_history`).
- Celeris router decisions aren't logged per call, so Celeris is slightly under-counted.

## Verification

The numbers you quote should match the Costs tab for the same period (both read the same
`costs.db` through `agent/costs/report.py`).
