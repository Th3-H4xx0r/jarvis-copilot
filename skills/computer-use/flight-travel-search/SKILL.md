---
name: flight-travel-search
description: "Find and compare flights and hotels from real fare pages."
version: 1.0.0
author: Pranav Krishna, JarvisCopilot
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [flights, travel, hotels, google-flights, fares, computer-use]
    related_skills: [web-task-router, web-watch-jobs, shopping-research]
---

# Flight & Travel Search Skill

Flights and hotels for Pranav: cheapest fares, date comparisons, nonstop
options, hotel prices for a stay, flight status. It reads real fares on the
server from pre-filled Google Flights and Google Hotels searches (no clicking
through forms) and compares dates in parallel. It answers with exact prices,
times and a booking link. It doesn't book or pay. Booking is his, or goes
through `web-forms-logins` with his yes.

## When to Use

- "Find flights from Houston to SF Dec 23 to Jan 3", "cheapest day to fly",
  "nonstop options", "how much is a flight to…", "hotels in <city> for <dates>".
- "Is my flight on time / where is UA1234" (status).
- Before setting up a fare watch (`web-watch-jobs`).

## Prerequisites

- Home: Houston. "Houston" covers IAH and HOU; search the city unless he names an
  airport.
- Dates: use his timezone; resolve "next Friday" etc. to real dates and say them
  back. Dates in the past mean the next occurrence.
- Load tools: `tool_search` `select:browser_extract,browser_vision`.

## How to Run

All on the server with `browser_extract {url, instruction}`. Measured working 2026-11-03.

| Search | URL (`%20` for spaces) |
|---|---|
| Round trip | `https://www.google.com/travel/flights?q=Flights%20from%20<FROM>%20to%20<TO>%20on%20<YYYY-MM-DD>%20through%20<YYYY-MM-DD>` |
| One way | `https://www.google.com/travel/flights?q=One%20way%20flights%20from%20<FROM>%20to%20<TO>%20on%20<YYYY-MM-DD>` |
| Nonstop / cabin | add words to q: `Nonstop%20flights…`, `…%20business%20class` |
| Hotels for a stay | `https://www.google.com/travel/search?q=hotels%20in%20<City>%20from%20<Month>%20<D>%20<YYYY>%20to%20<Month>%20<D>%20<YYYY>` |
| Flight status | `https://www.flightradar24.com/data/flights/<code>` (e.g. `ua1234`) |

Instruction for fares: "List the N cheapest options shown: airline, price,
stops, departure and arrival times, total duration. Also say the dates the page
is showing." Always check the page's dates match what you asked for.

## Quick Reference

- Blocked from the server: Kayak, Expedia, Booking.com, FlightAware. Don't try
  them. Google Flights and Google Hotels cover them.
- An airline he asks about missing from the results: say so, and offer to open
  that airline's site on his Mac. Don't assume it has no flights.
- Flexible dates ("cheapest weekend in December"): issue several
  `browser_extract` calls in the **same turn** (one per date pair), up to ~6,
  then compare.
- Prices on Google are per person, in USD, round trip unless it says one way.
- Booking link to give him: the same Google Flights URL (he picks the fare there),
  or open it on his Mac/phone if he asks (`device_open_url` with the device).

## Procedure

1. Pin down: from, to, dates (or date range), one-way vs round trip, nonstop
   needs, bags or cabin if he said. Ask one question only if from/to/dates are
   missing.
2. Build the URL(s) from the table and run the extract(s) in one turn.
3. Check each result's shown dates and route match the request. If a page comes
   back empty, retry once with `browser_navigate {url, engine: "chrome"}` then
   `browser_extract` on the current page.
4. Answer as a short table: price, airline, nonstop/stops, times, duration, best
   pick and why. For date comparisons, the cheapest pair first.
5. If he wants to see it: `browser_vision` on the results page, then
   `MEDIA:<screenshot_path>` in the reply.
6. Offer the next step in one line: a fare watch (`web-watch-jobs`), opening it on
   his Mac, or hotels for the same dates.

## Pitfalls

- Clicking through the Google Flights form (date pickers, airport boxes): slow
  and fragile. Always use the `q=` URL.
- Reporting a fare without the dates shown on the page. Google sometimes snaps
  to nearby dates.
- Hotels search ignoring dates when they're URL params (`checkin=`): put the dates
  in the `q` words as shown.
- Opening flights on his phone or Mac when he only asked for prices.
- Basic Economy: note it when the cheapest fare is Basic (no seat choice, no
  carry-on on some airlines).

## Verification

- Every fare in the reply was read from a results page whose dates and route match.
- The reply includes the search link he can open to book.
