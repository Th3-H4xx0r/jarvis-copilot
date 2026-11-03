---
name: integration-ui
description: Design an integration's own card and page in the app.
version: 1.0.0
author: Pranav Krishna, JarvisCopilot
license: MIT
platforms: [linux, macos, windows]
metadata:
  jarviscopilot:
    tags: [JarvisCopilot, iOS, Integrations, UI, Design]
    category: jarviscopilot
    related_skills: [widgets, dynamic-island]
---

# Integration UI Skill

Gives one Jarvis integration its own UI: a compact **card** on the app's Integrations tab
and a full **page** at the top of the integration's screen (the generic schedules, skills
and data sections stay below it). The UI is a JSON layout tree drawn natively on the
phone, bound to a **state** dict that a `load` script builds; every tap, toggle or
submit runs a named Python script on the server. It does not make Home Screen widgets
(see `widgets`) or Dynamic Island designs (see `dynamic-island`).

## When to Use

- The integration setup sheet reaches its UI step, or the person opens "Edit UI".
- "Give my shopping list a card with a quick add", "show this week's casino total as a
  chart", "add a refresh button to the flight tracker page".
- An integration's UI is broken: `load` errors, a button does nothing, a binding is empty.

## Prerequisites

- The integration exists (`integration_create`) and its data is in the registry.
- The `registry` toolset: `integration_ui_get`, `integration_ui_set`,
  `integration_ui_test`, plus `registry_catalog` to see what the space holds.
- Read `references/elements.md` (every node, prop, binding and the script helpers) and
  `references/examples.md` (three complete UIs) with `skill_view` before designing.

## How to Run

1. `integration_ui_get {space}` — the current UI (or null) and the `prompt` it came from.
2. `registry_catalog {space}` — the documents and collections `load` can read.
3. Write `load` first: it reads the space and returns every value the trees bind to.
4. Write the card and the page from the elements, and one script per action.
5. `integration_ui_set {space, card?, page?, scripts, prompt}` — send the WHOLE UI each
   time (anything left out is removed). Errors come back one per line; fix and resend.
6. Check `state_preview` has what the trees bind to and `load_error` is null.
7. `integration_ui_test {space, action, event}` only for actions safe to run for real
   (it changes real data), or undo what the test did.

## Quick Reference

```json
{"card": NODE, "page": NODE,
 "scripts": {"load": {"code": "<python>"},
             "add_item": {"code": "<python>", "confirm": "Add it?", "label": "Add item"}},
 "prompt": "what the person asked for, plus later changes"}
```

- Bind with `{"$": "totals.spent"}`; inside a list row with `{"$row": "name"}`. Add
  `fmt` (`"{} left"`), `map` and `default` to any binding.
- Controls: `button` (`action`), `row` (`action`, `check`, `swipe`), `toggle`,
  `textField` (`submit`), `picker`, `slider`, `stepper`, `date` — inputs need an `id`.
- Script skeleton:

```python
from jarvis_registry import ui_script as u
s = u.space()                       # this integration's registry space
name = (u.inputs().get("new_item") or "").strip()
if not name:
    u.fail("Type something first")  # shown to the person, nothing changes
s.append("items", {"name": name})
u.reply(toast=f"Added {name}")      # no state: load runs again
```

## Procedure

**Design for the app.** It is a dark app with one accent colour, large-title pages and
small labels over cards. Follow it:

- **Card = a glance plus one or two quick actions.** One headline number or status, at
  most three short rows, and a button or two. 10–25 nodes; nothing that scrolls.
- **Page = sections of cards.** Top-level `section`s with short titles ("Today", "Add",
  "History"); one idea per section. Never nest sections.
- **Numbers in stat grids.** A `grid` of 2–3 columns of `stat`s with `caption`s; let the
  most important one `span` 2. Put a `progress` or `gauge` next to a goal.
- **Charts for history**, `sparkline` for a trend inside a card, `keyValue` for details.
- **No custom colours** outside charts, rings, badges and dots: the accent comes from the
  app. Size, weight and opacity are fine for hierarchy (`opacity: 0.6` for secondary text).
- **Lists:** `row` with `check` for to-dos, `trailing` for a value, `swipe` for delete
  (`role: "destructive"`), and always an `empty` node.
- **Buttons:** one `primary` per section at most; `secondary` for the rest; `full: true`
  for a section's main action; `confirm` on anything destructive or that sends something.

**Write scripts that can't break the page.**

- `load` must succeed on an empty space: use `get(key, default=…)`, guard empty lists,
  never divide by zero. It runs every time the card or page opens — keep it fast
  (under ~2 s); do slow work (APIs, scans) in an action that stores its result.
- Actions usually `reply(toast=…)` without state so `load` redraws everything.
- Validate input and `fail("…")` with a sentence the person understands.
- Lists you edit live in a document with an `id` per item; records are append-only history.
- Everything a binding reads must be in the state `load` returns, as plain JSON (no NaN).

## Pitfalls

- An `action` naming a script that doesn't exist is refused; so is a missing `load`.
- `{"$row": …}` outside a `list`'s `row`, `src` bindings, and the island's `regions`
  node are refused.
- Grid `span` larger than the grid's `columns` is refused.
- Two inputs with the same `id` in one tree are refused.
- Leaving `card` or `page` out of `integration_ui_set` removes it — resend both.
- Printing logs is fine, but the LAST stdout line must be the JSON result; `u.reply`
  and `u.fail` handle that and exit.
- `integration_ui_test` with an action does it for real.

## Verification

- `integration_ui_set` returns `ok: true`, `load_error: null`, and a `state_preview`
  containing every key the card and page bind to.
- `integration_ui_test {space}` returns the same state; each safe action returns
  `ok: true` with the change visible in its state.
- The person sees the card on the Integrations tab and the page on the integration.
