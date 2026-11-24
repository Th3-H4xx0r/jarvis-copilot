#!/usr/bin/env python3
"""Todo due alerts — no model involved.

Run by the "Todo due alerts" cron job (no_agent). Reads registry space
`todo-list` / document `list`; every open item (done=false, notified=false)
whose due time has passed gets one phone push ("Todo due", title + notes), and
is marked notified=true only once that push went out. Prints nothing when all
is well; prints one line per failed push so the run shows the failure, and the
item is retried next run. The whole document is written back once, and only
when something changed.

Due times are ISO strings in US Central; a time without an offset is Central.
"""
from __future__ import annotations

import json
import sys
from datetime import datetime
from pathlib import Path
from typing import Callable, Optional, Tuple
from zoneinfo import ZoneInfo

_REPO = Path(__file__).resolve().parents[2]
if str(_REPO) not in sys.path:
    sys.path.insert(0, str(_REPO))

CT = ZoneInfo("America/Chicago")
SPACE, DOC = "todo-list", "list"

Notify = Callable[[str, str], Tuple[bool, str]]


def _phone_notify(title: str, body: str) -> Tuple[bool, str]:
    """The same push path the notify_phone tool uses."""
    from tools.notify_phone_tool import notify_phone_tool
    try:
        res = json.loads(notify_phone_tool({"title": title, "body": body}))
    except Exception as exc:  # noqa: BLE001 — any failure means "not sent"
        return False, str(exc)[:160] or type(exc).__name__
    if res.get("ok") and int(res.get("sent") or 0) > 0:
        return True, ""
    return False, str(res.get("error") or "not sent")


def _due_at(value) -> Optional[datetime]:
    if not value or not isinstance(value, str):
        return None
    try:
        dt = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=CT)


def run(now: Optional[datetime] = None, *, registry=None, notify: Optional[Notify] = None) -> list:
    """Send due alerts; return the lines to print (empty = silent run)."""
    now = now or datetime.now(CT)
    notify = notify or _phone_notify
    if registry is None:
        from jarvis_registry.store import shared
        registry = shared()
    if not registry.exists(SPACE):
        return []
    space = registry.open(SPACE)
    doc = space.get(DOC)
    if not isinstance(doc, dict) or not isinstance(doc.get("items"), list):
        return []

    out, changed = [], False
    for item in doc["items"]:
        if not isinstance(item, dict) or item.get("done") or item.get("notified"):
            continue
        due = _due_at(item.get("due"))
        if due is None or due > now:
            continue
        title = str(item.get("title") or "").strip() or "Todo"
        notes = str(item.get("notes") or "").strip()
        ok, err = notify("Todo due", f"{title} — {notes}" if notes else title)
        if ok:
            item["notified"] = True
            changed = True
        else:
            out.append(f"Todo due alert failed for: {title} ({err})")
    if changed:
        space.put(DOC, doc)
    return out


def main() -> int:
    lines = run()
    if lines:
        print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
