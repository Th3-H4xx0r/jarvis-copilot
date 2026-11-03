# Integration UI — worked examples
Each example is a complete UI document: `presentations.card`, `presentations.page`, `scripts` and `prompt` map one-to-one onto `integration_ui_set`'s `card`, `page`, `scripts` and `prompt`. The scripts are shown first as Python so they are easy to read; the JSON block after them is the exact document (the tests validate every block tagged `json ui-example` and run its `load` on an empty space).

## 1. Shopping list — add, check off, delete

A document `items` holds the list; rows tick off with `check` + `action`, swipe to delete, and `clear_done` asks first (`confirm`). Every action returns no state, so `load` runs again and the card and page both update.

`load`:

```python
from jarvis_registry import ui_script as u

items = u.space().get("items", default=[])
open_items = [i for i in items if not i.get("done")]
done_items = [i for i in items if i.get("done")]
u.reply({
    "open": open_items,
    "done": done_items,
    "open_count": len(open_items),
    "done_count": len(done_items),
})
```

`add_item` (label: "Add item"):

```python
import uuid
from jarvis_registry import ui_script as u

name = str(u.inputs().get("new_item") or "").strip()
if not name:
    u.fail("Type an item first")
s = u.space()
items = s.get("items", default=[])
items.append({"id": uuid.uuid4().hex[:8], "name": name, "done": False})
s.put("items", items, description="Shopping list: id, name, done")
u.reply(toast=f"Added {name}")
```

`toggle_item`:

```python
from jarvis_registry import ui_script as u

row = u.row() or {}
s = u.space()
items = s.get("items", default=[])
for item in items:
    if item.get("id") == row.get("id"):
        item["done"] = not item.get("done")
s.put("items", items)
u.reply()
```

`delete_item`:

```python
from jarvis_registry import ui_script as u

row = u.row() or {}
s = u.space()
s.put("items", [i for i in s.get("items", default=[]) if i.get("id") != row.get("id")])
u.reply(toast=f"Removed {row.get('name', 'it')}")
```

`clear_done` (confirm: "Remove every checked item?", label: "Clear checked"):

```python
from jarvis_registry import ui_script as u

s = u.space()
s.put("items", [i for i in s.get("items", default=[]) if not i.get("done")])
u.reply(toast="Cleared")
```

The document:

```json ui-example
{
  "schema": 1,
  "prompt": "A shopping list: add things, tick them off, clear the ticked ones.",
  "presentations": {
    "card": {
      "type": "vstack",
      "spacing": 8,
      "children": [
        {
          "type": "hstack",
          "children": [
            {
              "type": "stat",
              "value": {
                "$": "open_count"
              },
              "unit": "to buy"
            },
            {
              "type": "spacer"
            },
            {
              "type": "button",
              "label": "Clear",
              "symbol": "checkmark.circle",
              "role": "secondary",
              "action": "clear_done",
              "when": {
                "op": "gt",
                "a": {
                  "$": "done_count"
                },
                "b": 0
              }
            }
          ]
        },
        {
          "type": "list",
          "data": {
            "$": "open"
          },
          "max": 3,
          "row": {
            "type": "row",
            "title": {
              "$row": "name"
            },
            "check": {
              "$row": "done"
            },
            "action": "toggle_item"
          },
          "empty": {
            "type": "text",
            "value": "All done",
            "style": {
              "opacity": 0.6
            }
          }
        }
      ]
    },
    "page": {
      "type": "vstack",
      "spacing": 16,
      "children": [
        {
          "type": "section",
          "title": "Add",
          "children": [
            {
              "type": "hstack",
              "children": [
                {
                  "type": "textField",
                  "id": "new_item",
                  "placeholder": "Milk, eggs…",
                  "submit": "add_item"
                },
                {
                  "type": "button",
                  "label": "Add",
                  "symbol": "plus",
                  "action": "add_item"
                }
              ]
            }
          ]
        },
        {
          "type": "section",
          "title": "To buy",
          "subtitle": {
            "$": "open_count",
            "fmt": "{} left"
          },
          "children": [
            {
              "type": "list",
              "data": {
                "$": "open"
              },
              "row": {
                "type": "row",
                "title": {
                  "$row": "name"
                },
                "check": {
                  "$row": "done"
                },
                "action": "toggle_item",
                "swipe": [
                  {
                    "label": "Delete",
                    "action": "delete_item",
                    "role": "destructive"
                  }
                ]
              },
              "empty": {
                "type": "text",
                "value": "Nothing to buy",
                "style": {
                  "opacity": 0.6
                }
              }
            }
          ]
        },
        {
          "type": "section",
          "title": "In the basket",
          "when": {
            "op": "gt",
            "a": {
              "$": "done_count"
            },
            "b": 0
          },
          "children": [
            {
              "type": "list",
              "data": {
                "$": "done"
              },
              "row": {
                "type": "row",
                "title": {
                  "$row": "name"
                },
                "check": {
                  "$row": "done"
                },
                "action": "toggle_item",
                "swipe": [
                  {
                    "label": "Delete",
                    "action": "delete_item",
                    "role": "destructive"
                  }
                ]
              }
            },
            {
              "type": "button",
              "label": "Clear checked",
              "role": "destructive",
              "full": true,
              "action": "clear_done"
            }
          ]
        }
      ]
    }
  },
  "scripts": {
    "load": {
      "code": "from jarvis_registry import ui_script as u\n\nitems = u.space().get(\"items\", default=[])\nopen_items = [i for i in items if not i.get(\"done\")]\ndone_items = [i for i in items if i.get(\"done\")]\nu.reply({\n    \"open\": open_items,\n    \"done\": done_items,\n    \"open_count\": len(open_items),\n    \"done_count\": len(done_items),\n})\n"
    },
    "add_item": {
      "label": "Add item",
      "code": "import uuid\nfrom jarvis_registry import ui_script as u\n\nname = str(u.inputs().get(\"new_item\") or \"\").strip()\nif not name:\n    u.fail(\"Type an item first\")\ns = u.space()\nitems = s.get(\"items\", default=[])\nitems.append({\"id\": uuid.uuid4().hex[:8], \"name\": name, \"done\": False})\ns.put(\"items\", items, description=\"Shopping list: id, name, done\")\nu.reply(toast=f\"Added {name}\")\n"
    },
    "toggle_item": {
      "code": "from jarvis_registry import ui_script as u\n\nrow = u.row() or {}\ns = u.space()\nitems = s.get(\"items\", default=[])\nfor item in items:\n    if item.get(\"id\") == row.get(\"id\"):\n        item[\"done\"] = not item.get(\"done\")\ns.put(\"items\", items)\nu.reply()\n"
    },
    "delete_item": {
      "code": "from jarvis_registry import ui_script as u\n\nrow = u.row() or {}\ns = u.space()\ns.put(\"items\", [i for i in s.get(\"items\", default=[]) if i.get(\"id\") != row.get(\"id\")])\nu.reply(toast=f\"Removed {row.get('name', 'it')}\")\n"
    },
    "clear_done": {
      "confirm": "Remove every checked item?",
      "label": "Clear checked",
      "code": "from jarvis_registry import ui_script as u\n\ns = u.space()\ns.put(\"items\", [i for i in s.get(\"items\", default=[]) if not i.get(\"done\")])\nu.reply(toast=\"Cleared\")\n"
    }
  }
}
```

## 2. Water tracker — stats, a ring and a chart

Records in `drinks` are summed per day by `load`. The page uses a 3-column grid with `span`, a segmented `picker` that stores the chart range, a bar `chart`, and a `stepper` whose value reaches `log_amount` through `inputs()`.

`load`:

```python
import time
from datetime import datetime, timedelta
from jarvis_registry import ui_script as u

s = u.space()
settings = s.get("settings", default={}) or {}
goal = int(settings.get("goal_ml") or 2000)
days = int(settings.get("range_days") or 7)
today = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
start = today - timedelta(days=days - 1)
drinks = s.records("drinks", since=start.timestamp(), limit=1000)

totals = {}
for d in drinks:
    day = datetime.fromtimestamp(d["ts"]).strftime("%Y-%m-%d")
    totals[day] = totals.get(day, 0) + int(d.get("ml") or 0)
series = []
for i in range(days):
    day = start + timedelta(days=i)
    label = day.strftime("%a") if days <= 7 else str(day.day)
    series.append({"x": label, "y": totals.get(day.strftime("%Y-%m-%d"), 0)})

today_ml = series[-1]["y"]
values = [p["y"] for p in series]
u.reply({
    "today_ml": today_ml,
    "goal_ml": goal,
    "goal_frac": min(1.0, today_ml / goal) if goal else 0,
    "left_ml": max(0, goal - today_ml),
    "series": series,
    "average_ml": round(sum(values) / len(values)) if values else 0,
    "best_ml": max(values) if values else 0,
    "days_met": sum(1 for v in values if v >= goal),
    "range": str(days),
})
```

`log_250` (label: "Log a glass"):

```python
from jarvis_registry import ui_script as u

u.space().append("drinks", {"ml": 250}, source="ui")
u.reply(toast="250 ml logged")
```

`log_amount` (label: "Log amount"):

```python
from jarvis_registry import ui_script as u

ml = int(u.inputs().get("amount") or 0)
if ml <= 0:
    u.fail("Pick an amount first")
u.space().append("drinks", {"ml": ml}, source="ui")
u.reply(toast=f"{ml} ml logged")
```

`set_range`:

```python
from jarvis_registry import ui_script as u

s = u.space()
settings = s.get("settings", default={}) or {}
settings["range_days"] = int(u.value() or 7)
s.put("settings", settings, description="Water goal and chart range")
u.reply()
```

The document:

```json ui-example
{
  "schema": 1,
  "prompt": "Track how much water I drink against a daily goal, with a weekly chart.",
  "presentations": {
    "card": {
      "type": "hstack",
      "spacing": 12,
      "children": [
        {
          "type": "gauge",
          "rings": [
            {
              "value": {
                "$": "goal_frac"
              }
            }
          ]
        },
        {
          "type": "vstack",
          "spacing": 2,
          "children": [
            {
              "type": "stat",
              "value": {
                "$": "today_ml"
              },
              "unit": "ml"
            },
            {
              "type": "text",
              "value": {
                "$": "left_ml",
                "fmt": "{} ml to go"
              },
              "style": {
                "opacity": 0.6,
                "size": 12
              }
            }
          ]
        },
        {
          "type": "spacer"
        },
        {
          "type": "button",
          "label": "Glass",
          "symbol": "drop.fill",
          "action": "log_250"
        }
      ]
    },
    "page": {
      "type": "vstack",
      "spacing": 16,
      "children": [
        {
          "type": "section",
          "title": "Today",
          "children": [
            {
              "type": "grid",
              "columns": 3,
              "children": [
                {
                  "type": "stat",
                  "value": {
                    "$": "today_ml"
                  },
                  "unit": "ml",
                  "caption": "drunk",
                  "span": 2
                },
                {
                  "type": "gauge",
                  "rings": [
                    {
                      "value": {
                        "$": "goal_frac"
                      }
                    }
                  ]
                },
                {
                  "type": "progress",
                  "value": {
                    "$": "goal_frac"
                  },
                  "span": 3
                }
              ]
            }
          ]
        },
        {
          "type": "section",
          "title": "History",
          "children": [
            {
              "type": "picker",
              "id": "range",
              "value": {
                "$": "range"
              },
              "options": [
                {
                  "label": "Week",
                  "value": "7"
                },
                {
                  "label": "Month",
                  "value": "30"
                }
              ],
              "action": "set_range"
            },
            {
              "type": "chart",
              "series": {
                "$": "series"
              },
              "style": "bar",
              "height": 120,
              "axes": true
            },
            {
              "type": "keyValue",
              "pairs": [
                {
                  "label": "Average",
                  "value": {
                    "$": "average_ml",
                    "fmt": "{} ml"
                  }
                },
                {
                  "label": "Best day",
                  "value": {
                    "$": "best_ml",
                    "fmt": "{} ml"
                  }
                },
                {
                  "label": "Days on goal",
                  "value": {
                    "$": "days_met"
                  }
                }
              ]
            }
          ]
        },
        {
          "type": "section",
          "title": "Log",
          "children": [
            {
              "type": "stepper",
              "id": "amount",
              "label": "Amount (ml)",
              "min": 50,
              "max": 1000,
              "step": 50,
              "value": 250
            },
            {
              "type": "button",
              "label": "Log it",
              "symbol": "plus",
              "full": true,
              "action": "log_amount"
            }
          ]
        }
      ]
    }
  },
  "scripts": {
    "load": {
      "code": "import time\nfrom datetime import datetime, timedelta\nfrom jarvis_registry import ui_script as u\n\ns = u.space()\nsettings = s.get(\"settings\", default={}) or {}\ngoal = int(settings.get(\"goal_ml\") or 2000)\ndays = int(settings.get(\"range_days\") or 7)\ntoday = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)\nstart = today - timedelta(days=days - 1)\ndrinks = s.records(\"drinks\", since=start.timestamp(), limit=1000)\n\ntotals = {}\nfor d in drinks:\n    day = datetime.fromtimestamp(d[\"ts\"]).strftime(\"%Y-%m-%d\")\n    totals[day] = totals.get(day, 0) + int(d.get(\"ml\") or 0)\nseries = []\nfor i in range(days):\n    day = start + timedelta(days=i)\n    label = day.strftime(\"%a\") if days <= 7 else str(day.day)\n    series.append({\"x\": label, \"y\": totals.get(day.strftime(\"%Y-%m-%d\"), 0)})\n\ntoday_ml = series[-1][\"y\"]\nvalues = [p[\"y\"] for p in series]\nu.reply({\n    \"today_ml\": today_ml,\n    \"goal_ml\": goal,\n    \"goal_frac\": min(1.0, today_ml / goal) if goal else 0,\n    \"left_ml\": max(0, goal - today_ml),\n    \"series\": series,\n    \"average_ml\": round(sum(values) / len(values)) if values else 0,\n    \"best_ml\": max(values) if values else 0,\n    \"days_met\": sum(1 for v in values if v >= goal),\n    \"range\": str(days),\n})\n"
    },
    "log_250": {
      "label": "Log a glass",
      "code": "from jarvis_registry import ui_script as u\n\nu.space().append(\"drinks\", {\"ml\": 250}, source=\"ui\")\nu.reply(toast=\"250 ml logged\")\n"
    },
    "log_amount": {
      "label": "Log amount",
      "code": "from jarvis_registry import ui_script as u\n\nml = int(u.inputs().get(\"amount\") or 0)\nif ml <= 0:\n    u.fail(\"Pick an amount first\")\nu.space().append(\"drinks\", {\"ml\": ml}, source=\"ui\")\nu.reply(toast=f\"{ml} ml logged\")\n"
    },
    "set_range": {
      "code": "from jarvis_registry import ui_script as u\n\ns = u.space()\nsettings = s.get(\"settings\", default={}) or {}\nsettings[\"range_days\"] = int(u.value() or 7)\ns.put(\"settings\", settings, description=\"Water goal and chart range\")\nu.reply()\n"
    }
  }
}
```

## 3. Server status — a page with a refresh button

`load` only reads the last checks, so opening the page is instant; the `refresh` action does the slow work, appends a record, and lets `load` redraw. The badge colour comes from a `map` on the state.

`load`:

```python
import time
from jarvis_registry import ui_script as u

def ago(ts):
    mins = int((time.time() - ts) // 60)
    if mins < 1:
        return "just now"
    if mins < 60:
        return f"{mins} min ago"
    return f"{mins // 60} h ago"

checks = u.space().records("checks", limit=10)
last = checks[0] if checks else None
recent = [{"when": time.strftime("%a %H:%M", time.localtime(c["ts"])),
           "summary": c.get("summary", ""), "status": c.get("status", "ok")}
          for c in checks]
u.reply({
    "status": last.get("status", "ok") if last else "unknown",
    "status_label": (last.get("status", "ok").upper() if last else "NOT CHECKED"),
    "checked_ago": ago(last["ts"]) if last else "never",
    "disk_pct": last.get("disk_pct", 0) if last else 0,
    "disk_frac": (last.get("disk_pct", 0) / 100) if last else 0,
    "load": last.get("load", 0) if last else 0,
    "free_gb": last.get("free_gb", 0) if last else 0,
    "recent": recent,
})
```

`refresh` (label: "Check now"):

```python
import os
import shutil
from jarvis_registry import ui_script as u

disk = shutil.disk_usage("/")
disk_pct = round(disk.used / disk.total * 100)
try:
    load = round(os.getloadavg()[0], 2)
except (AttributeError, OSError):
    load = 0
status = "bad" if disk_pct > 95 else "warn" if disk_pct > 85 or load > 4 else "ok"
u.space().append("checks", {
    "status": status, "disk_pct": disk_pct, "load": load,
    "free_gb": round(disk.free / 1e9, 1),
    "summary": f"disk {disk_pct}% · load {load}",
}, source="ui")
u.reply(toast="Checked")
```

The document:

```json ui-example
{
  "schema": 1,
  "prompt": "Show whether my server is healthy, with a button to check it now.",
  "presentations": {
    "card": {
      "type": "hstack",
      "spacing": 10,
      "children": [
        {
          "type": "badge",
          "text": {
            "$": "status_label"
          },
          "color": {
            "$": "status",
            "map": {
              "ok": "green",
              "warn": "orange",
              "bad": "red",
              "unknown": "gray"
            }
          }
        },
        {
          "type": "text",
          "value": {
            "$": "checked_ago"
          },
          "style": {
            "opacity": 0.6,
            "size": 12
          }
        },
        {
          "type": "spacer"
        },
        {
          "type": "button",
          "label": "Check",
          "symbol": "arrow.clockwise",
          "role": "secondary",
          "action": "refresh"
        }
      ]
    },
    "page": {
      "type": "vstack",
      "spacing": 16,
      "children": [
        {
          "type": "section",
          "title": "Now",
          "subtitle": {
            "$": "checked_ago"
          },
          "children": [
            {
              "type": "hstack",
              "children": [
                {
                  "type": "badge",
                  "text": {
                    "$": "status_label"
                  },
                  "color": {
                    "$": "status",
                    "map": {
                      "ok": "green",
                      "warn": "orange",
                      "bad": "red",
                      "unknown": "gray"
                    }
                  }
                },
                {
                  "type": "spacer"
                }
              ]
            },
            {
              "type": "grid",
              "columns": 3,
              "children": [
                {
                  "type": "stat",
                  "value": {
                    "$": "disk_pct"
                  },
                  "unit": "%",
                  "caption": "disk used"
                },
                {
                  "type": "stat",
                  "value": {
                    "$": "free_gb"
                  },
                  "unit": "GB",
                  "caption": "free"
                },
                {
                  "type": "stat",
                  "value": {
                    "$": "load"
                  },
                  "caption": "load"
                },
                {
                  "type": "progress",
                  "value": {
                    "$": "disk_frac"
                  },
                  "span": 3
                }
              ]
            }
          ]
        },
        {
          "type": "section",
          "title": "Recent checks",
          "children": [
            {
              "type": "list",
              "data": {
                "$": "recent"
              },
              "max": 10,
              "row": {
                "type": "row",
                "title": {
                  "$row": "when"
                },
                "subtitle": {
                  "$row": "summary"
                },
                "trailing": {
                  "$row": "status"
                }
              },
              "empty": {
                "type": "text",
                "value": "No checks yet — tap Check now.",
                "style": {
                  "opacity": 0.6
                }
              }
            }
          ]
        },
        {
          "type": "button",
          "label": "Check now",
          "symbol": "arrow.clockwise",
          "full": true,
          "action": "refresh"
        }
      ]
    }
  },
  "scripts": {
    "load": {
      "code": "import time\nfrom jarvis_registry import ui_script as u\n\ndef ago(ts):\n    mins = int((time.time() - ts) // 60)\n    if mins < 1:\n        return \"just now\"\n    if mins < 60:\n        return f\"{mins} min ago\"\n    return f\"{mins // 60} h ago\"\n\nchecks = u.space().records(\"checks\", limit=10)\nlast = checks[0] if checks else None\nrecent = [{\"when\": time.strftime(\"%a %H:%M\", time.localtime(c[\"ts\"])),\n           \"summary\": c.get(\"summary\", \"\"), \"status\": c.get(\"status\", \"ok\")}\n          for c in checks]\nu.reply({\n    \"status\": last.get(\"status\", \"ok\") if last else \"unknown\",\n    \"status_label\": (last.get(\"status\", \"ok\").upper() if last else \"NOT CHECKED\"),\n    \"checked_ago\": ago(last[\"ts\"]) if last else \"never\",\n    \"disk_pct\": last.get(\"disk_pct\", 0) if last else 0,\n    \"disk_frac\": (last.get(\"disk_pct\", 0) / 100) if last else 0,\n    \"load\": last.get(\"load\", 0) if last else 0,\n    \"free_gb\": last.get(\"free_gb\", 0) if last else 0,\n    \"recent\": recent,\n})\n"
    },
    "refresh": {
      "label": "Check now",
      "code": "import os\nimport shutil\nfrom jarvis_registry import ui_script as u\n\ndisk = shutil.disk_usage(\"/\")\ndisk_pct = round(disk.used / disk.total * 100)\ntry:\n    load = round(os.getloadavg()[0], 2)\nexcept (AttributeError, OSError):\n    load = 0\nstatus = \"bad\" if disk_pct > 95 else \"warn\" if disk_pct > 85 or load > 4 else \"ok\"\nu.space().append(\"checks\", {\n    \"status\": status, \"disk_pct\": disk_pct, \"load\": load,\n    \"free_gb\": round(disk.free / 1e9, 1),\n    \"summary\": f\"disk {disk_pct}% · load {load}\",\n}, source=\"ui\")\nu.reply(toast=\"Checked\")\n"
    }
  }
}
```
