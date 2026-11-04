---
name: web-task-router
description: "Pick the right browser for a web task; verify the facts."
version: 1.0.0
author: Pranav Krishna, JarvisCopilot
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [browser, web, research, shopping, prices, routing, computer-use]
    related_skills: [shopping-research, flight-travel-search, web-forms-logins, web-watch-jobs, blocked-page-recovery, mac-control]
---

# Web Task Router Skill

The first step for any task that touches the web: lookups, price checks,
research, "open this", "find me…". It decides whether to just answer, read
pages on the server, use the cloud browser, or use his Mac, and which sites to
skip because they block the server. Every number it reports comes from a page
it read, with the link. Topic playbooks (`shopping-research`,
`flight-travel-search`, `web-forms-logins`, `web-watch-jobs`) build on this.

## When to Use

- Any request needing current facts from the web, a price, a listing, a page's
  content, or "open <site>".
- Before calling `browser_*`, `chrome_*`, `computer_do` or `device_open_url` for
  a web task.

## Prerequisites

- Deferred tools: load what you need in one call, e.g.
  `tool_search` `select:browser_navigate,browser_extract,browser_run,browser_vision`.

## How to Run

**Step 1. Answer or show?**
- He asked a question ("how far", "how much", "is it open", "what's the score"):
  find the answer on the server and **tell him**. Don't open anything on his phone
  or Mac.
- He asked to open, show or watch something, or to act on a site where he's signed
  in: go to Step 2.

**Step 2. Where?** First match wins:

| Situation | Surface | Tools |
|---|---|---|
| He said "on my Mac / laptop / in my browser / my Chrome" | his Mac | `device_open_url` (just open), `computer_do` (do things) — see `mac-control` |
| He said "on my phone" | iPhone | `device_open_url` with the iPhone as `device` |
| Needs his logins (his accounts, orders, email web UI) | his Mac | `computer_do` in his browser |
| Plain facts, prices, listings, research | server | `web_search` (+`read_top`), `browser_extract`, `browser_run` |
| Interactive steps on a site (filters, forms) and he wants to watch | cloud browser | `browser_navigate` then interactive calls (auto-move; repeat the first one) |

Never say a page opened on a device unless the tool's `ran_on` says that device.

**Step 3. Read with the fewest calls.**
- Discovery: `web_search {query, read_top: 3}` gives results plus page text in one call.
- One page → data: `browser_extract {url, instruction, schema?}` (navigate + read in one).
- A search box/filter sequence: `browser_run` with
  `open → fill → press Enter → wait_for → extract` in one call.
- Build result URLs directly instead of clicking through home pages (table below).
- A page came back empty (heavy JS app): retry once with
  `browser_navigate {url, engine: "chrome"}`, then `browser_extract`.

## Quick Reference

Server reachability, measured 2026-11-03 from the Jarvis server:

| Site | From the server | Use |
|---|---|---|
| Google Search / Google Shopping | **blocked** (`/sorry`) | `web_search`, or Bing |
| Bing search / Bing Shopping `bing.com/shop?q=` | works | multi-store price list in one page |
| DuckDuckGo html | works sometimes; captchas under load | not first choice |
| Google Flights `google.com/travel/flights?q=…` | works (real fares) | see `flight-travel-search` |
| Google Hotels `google.com/travel/hotels/<City>` | works | hotels + nightly price |
| Amazon `amazon.com/s?k=` | blocked by default; **works with `engine: "chrome"`** | navigate with chrome, then extract |
| Walmart `walmart.com/search?q=`, Target `target.com/s?searchTerm=` | work | prices |
| Best Buy | very slow (60 s+), prices missing | Bing Shopping or his Mac |
| Newegg, Micro Center, CamelCamelCamel | **Cloudflare wall** | Bing Shopping; his Mac if he wants the store page |
| eBay | error page | his Mac |
| Kayak | bot page | Google Flights |
| FlightAware | **Cloudflare wall** | FlightRadar24 `flightradar24.com/data/flights/<code>` |
| Zillow rentals `zillow.com/<city>-<st>/rentals/` | works | listings + prices |
| Apartments.com | loads, prices missing | Zillow, or open the listing page |
| Finviz | works | quotes |

A site not listed: try once. On a bot wall ("Just a moment", captcha, "Access
denied", "/sorry", empty page), don't retry the same URL. Use the alternative
above, the `blocked-page-recovery` ladder, or his Mac.

## Procedure

1. Classify (Step 1) and pick the surface (Step 2). If he named a device or
   corrected one earlier in the chat, that wins.
2. Plan the reads: which 2–3 sources answer it. Prefer first-party pages
   (retailer, airline, official) over snippets.
3. Read (Step 3). Stop as soon as the question is answered.
4. **Verify every number.** A price, date or spec is only reported if you read it
   on its page in this task. Quote it exactly ($199.00 is not $199.99) and give
   the URL. Search snippets and memory are leads, not facts.
5. Evidence when it matters (prices, listings, "show me"): `browser_vision` on the
   page with a question ("what's the price and seller?"). Put its `screenshot_path`
   in the reply as `MEDIA:<path>` on its own line.
6. Reply: the answer first, then sources (store — price — link). Say what you could
   not check ("Best Buy didn't load from the server").

## Pitfalls

- Opening things he only asked about ("Can you just tell me? Not open it on my
  phone").
- Retrying a blocked site, or trying DDG html, then lite, then the API: one wall
  means switch sources.
- Mixing variants: refurbished vs new, Pro vs Pro Max, used listings. Match the
  exact model before comparing.
- Saying "opened rickpanchang.com" when the page is hinduplace.com: report the URL
  the tool returned.
- Calling a deferred tool before `tool_search` loaded it.
- More than ~15 tool calls on a lookup means the plan is wrong. Step back and
  pick a better source.

## Verification

- Every figure in the reply has a source URL read in this task.
- The reply names where anything was opened (server / cloud / Mac / iPhone),
  matching `ran_on`.
- No blocked site was hit twice.
