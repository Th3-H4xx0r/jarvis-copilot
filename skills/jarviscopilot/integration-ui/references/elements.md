# Integration UI — elements

Every node is a JSON object with a `type`. Any node may also carry:

- `when` — a condition; the node (and everything inside it) shows only when it holds.
- `style` — `{size, weight, color, tint, opacity, padding, width, height, minHeight}`.
  `weight`: `ultraLight` … `regular`, `medium`, `semibold`, `bold`, `heavy`, `black`.
  Use `size`/`weight`/`opacity` freely; keep `color`/`tint` to charts, rings and badges.
- `span` — inside a `grid` only: how many of its columns this child takes (1…columns).

A **value** is a literal (text, number, bool) or a binding (below). An **array value** is
a literal list or a binding to a list. An **action** is the name of a key in `scripts`.

Limits: card ≤ 80 nodes, page ≤ 400, nesting ≤ 16, the whole UI ≤ 256 KB.

## Bindings

| Binding | Reads |
|---|---|
| `{"$": "count"}` | `state["count"]` |
| `{"$": "totals.spent"}` | `state["totals"]["spent"]` (dotted path) |
| `{"$row": "name"}` | the current list row's `name` (only inside a `list`'s `row`) |
| `{"$row": "price.amount"}` | dotted inside the row too |
| `{"clock": "remaining", "to": …}` | on-device clocks: `phase`, `fraction` (`from`,`to`), `remaining` (`to`), `elapsed` (`from`), `index` (`keys`) |

Any `$`/`$row` binding may add:

- `"fmt": "{} left"` — the value replaces `{}`.
- `"map": {"ok": "green", "bad": "red"}` — swaps the value for the mapped one (labels, colours).
- `"default": "—"` — shown while the value is missing.

`src` bindings (widget data sources) are **not** available: put what you need in the state.

## Conditions (`when`)

`{"op": "eq"|"ne"|"gt"|"lt", "a": value, "b": value}`, `{"op": "exists", "a": value}`,
`{"op": "between", "a": value, "lo": n, "hi": n}`, `{"op": "and"|"or", "items": [cond…]}`,
`{"op": "not", "item": cond}`, `{"op": "after"|"before", "at": time}`.
Example: `{"op": "gt", "a": {"$": "done_count"}, "b": 0}`.

## Layout

| type | props |
|---|---|
| `vstack` | `children`, `spacing?` (default 6), `align?`: `leading`/`center`/`trailing` |
| `hstack` | `children`, `spacing?`, `align?`: `top`/`center`/`bottom`/`firstBaseline` |
| `zstack` | `children` (layered) |
| `grid` | `columns` (1–6), `spacing?`, `children`; any child may carry `span` |
| `section` | `title?`, `subtitle?` (values), `children` (required), `plain?` (true = no card behind it) |
| `hscroll` | `children`, `spacing?` — a horizontally scrolling row |
| `list` | `data` (array value), `row` (the node drawn per item; `$row` works inside), `empty?` (node shown when there are no items), `max?` (most rows shown), `columns?` (lay rows out in a grid) |
| `spacer` | `minLength?` — pushes siblings apart in a stack |
| `divider` | — a thin line |

On the page, use `section`s as the top-level blocks: each draws a small label over a card,
like every other screen in the app. Don't put a section inside a section.

## Display

| type | props |
|---|---|
| `text` | `value`; `lineLimit?` (default 1; `0` = no limit); `markdown?` (bool) |
| `titleSubtitle` | `title`, `subtitle` |
| `stat` | `value`, `unit?`, `caption?` — a big number |
| `symbol` | `name` (SF Symbol), `effect?`: `pulse`/`bounce`/`variableColor` |
| `symbolValue` | `symbol`, `value` — an icon with a short value beside it |
| `image` | `source` (SF Symbol name, `"orb"`, or an https URL), `fallback?` (SF Symbol), `shape?`: `circle`/`rounded`; size via `style.width/height` |
| `dot` | `color` — a small status dot |
| `badge` | `text`, `color?` — a capsule label (good with `map`) |
| `progress` | `value` (0–1, or set `scale: 100` for 0–100), `tint?`, `tip?` (SF Symbol at the fill edge, or `{symbol, color?, size?, rotation?}`) |
| `segbar` | `segments` (array of `{weight?, color?}`), `progress?`/`from?`/`to?`, `tip?` |
| `gauge` | `rings: [{value, tint?}]` (0–1; several = concentric), or a single `value`; `label?`; `scale?` |
| `timer` | `to` (epoch seconds or ISO date), `mode?`: `countdown`/`up`, `format?`: `relative` |
| `timeProgress` | `from`, `to` (dates), `tint?` — a bar that fills by itself |
| `keyValue` | `pairs: [{label, value}]` — label left, value right, one per line |
| `sparkline` | `points` (array of numbers), `kind?`: `line`/`area`, `tint?` |
| `chart` | `series` (numbers, or `[{x: "Mon", y: 3}]`), `style?`: `line`/`bar`/`area`, `color?`, `min?`, `max?`, `height?` (default 60), `axes?` (bool) |
| `iconStrip` | `items` (array of SF Symbol names), `max?` |
| `waveform` | `active?` — a static voice-style bar strip |
| `accent` | `color?` — a thin vertical accent bar |
| `model` | `device`: `ring`/`x5ring`/`band`/`glasses`/`bottle`/`scale`/`esp32`/`pod` — a wearable's 3D picture |

## Interactive

Every interaction runs one script on the server. The app never changes data by itself.

| type | props |
|---|---|
| `button` | `label`, `symbol?`, `action` (required), `role?`: `primary` (default) / `secondary` / `destructive`, `full?` (full width) |
| `row` | `title`, `subtitle?`, `symbol?`, `trailing?` (value on the right), `check?` (bool value: draws a checkbox), `action?` (tap), `swipe?: [{label, action, role?}]` |
| `toggle` | `id`, `label`, `value` (bool binding), `action` (required; gets the new bool as `value`) |
| `textField` | `id`, `placeholder?`, `value?`, `submit?` (action run on return), `keyboard?`: `text`/`number`/`email`/`url` |
| `picker` | `id`, `options` (`[{label, value}]` or a binding to such a list), `value?`, `action?` (runs on change), `variant?`: `segmented` (default) / `menu` |
| `slider` | `id`, `min`, `max`, `step?`, `value?`, `action?` (runs on release) |
| `stepper` | `id`, `label?`, `min?`, `max?`, `step?`, `value?`, `action?` |
| `date` | `id`, `value?` (ISO date), `mode?`: `date`/`time`/`dateTime`, `action?` |

- `id`: lowercase letters, digits and `_`, unique within the card or page.
- Every input's current value reaches every script as `inputs()[id]`, so a button can
  read a text field and a stepper together. The control that fired also sends its own
  value as `value()`.
- A `row` or input inside a `list` sends that list item as `row()` with the event.
- A script with `confirm` makes the app ask before running it.

## Script I/O

stdin (one JSON object):

```json
{"event": {"action": "add_item", "control": "new_item", "value": null,
           "inputs": {"new_item": "Milk"}, "row": null},
 "state": {"...": "the last state load or an action returned, or {}"},
 "integration": "shopping-list"}
```

stdout: the LAST non-empty line must be one JSON object — earlier lines are ignored:

```json
{"state": {"...": "the whole new state"}, "toast": "Added Milk", "error": "shown instead"}
```

- `state` absent → the server runs `load` again (the usual choice for actions).
- `error` → shown to the person; the state they see does not change.
- A non-zero exit, a timeout or a last line that is not JSON is an error, with the end of
  stderr attached. `load` has 20 s, actions 60 s.
- Scripts run as `python3 <name>.py` in `$HERMES_HOME/integration_ui/<space>/`, with
  Jarvis's full access: files, network, other integrations, `subprocess`. Environment:
  `JARVIS_UI_SPACE` (the space id), `JARVIS_REGISTRY_PATH` (the registry database).

## The helper module

```python
from jarvis_registry import ui_script as u
```

| Call | Returns / does |
|---|---|
| `u.space()` | this integration's registry space: `get(key, default=)`, `put(key, body, description=)`, `append(collection, body, ts=, source=)`, `records(collection, since=, until=, where=, limit=, newest_first=)`, `delete_document(key)`, `delete_record(id)` |
| `u.other_space(id)` | another integration's space |
| `u.event()` | `{action, control, value, inputs, row}` |
| `u.inputs()` | `{input id: current value}` |
| `u.row()` | the list item the control belongs to, or `None` |
| `u.value()` | the firing control's own value |
| `u.state()` | the previous state (`{}` if none) |
| `u.integration()` | the space id |
| `u.reply(state=None, toast=None)` | prints the result and exits; no state = re-run `load` |
| `u.fail(message)` | prints `{"error": message}` and exits |

Records are history (append-only; ids come back on each record). Keep editable lists
(shopping items, todos) in a document you rewrite, and give each item an `id` so a row's
action can find it.
