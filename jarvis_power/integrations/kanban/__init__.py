"""Kanban: the multi-agent task board Jarvis's workers pick up and run.

Off: the gateway's dispatcher and notifier skip every tick, running workers are
stopped and their tasks go back to ready (resumed when it's back on), the kanban_*
tools are refused and /api/kanban answers 409.
"""
from __future__ import annotations

import logging

from jarvis_power import Link, PowerIntegration, Setting

logger = logging.getLogger(__name__)


def _boards() -> list[str]:
    from jarviscopilot_cli import kanban_db as kb
    try:
        return [b.get("slug") or kb.DEFAULT_BOARD for b in kb.list_boards(include_archived=False)]
    except Exception:
        return [kb.DEFAULT_BOARD]


def _counts() -> dict:
    from jarviscopilot_cli import kanban_db as kb
    totals = {"running": 0, "ready": 0, "open": 0}
    for slug in _boards():
        conn = kb.connect(board=slug)
        try:
            for status, n in conn.execute("SELECT status, COUNT(*) FROM tasks GROUP BY status"):
                if status in ("running", "ready"):
                    totals[status] += n
                if status not in ("done", "archived"):
                    totals["open"] += n
        finally:
            conn.close()
    return totals


class Kanban(PowerIntegration):
    id = "kanban"
    name = "Kanban"
    icon = "rectangle.split.3x1"
    summary = "A task board Jarvis's workers pick up and finish on their own."
    processes = ("gateway", "webui")
    toolsets = ("kanban",)
    route_prefixes = ("/api/kanban",)
    surfaces = ("ios.more.kanban", "web.rail.kanban")
    links = (Link("ios", "kanban", "Open the board"), Link("web", "kanban", "Open the board"))
    settings = (
        Setting("dispatch", "Run ready tasks automatically", "toggle", default=True,
                help="Off: tasks wait for a worker or terminal to claim them. Off applies at "
                     "once; back on after the gateway restarts."),
        Setting("failure_limit", "Block a task after failures", "number", default=2, min=1, max=10),
    )

    def stop(self, process: str) -> None:
        """Stop every running worker now and put its task back to ready."""
        from jarviscopilot_cli import kanban_db as kb
        for slug in _boards():
            conn = kb.connect(board=slug)
            try:
                rows = conn.execute("SELECT id FROM tasks WHERE status = 'running'").fetchall()
                for row in rows:
                    try:
                        kb.reclaim_task(conn, row["id"], reason="Kanban was switched off")
                    except Exception:
                        logger.exception("power: could not requeue kanban task %s", row["id"])
            finally:
                conn.close()

    def read_settings(self) -> dict:
        from jarvis_power.stores import config_get
        return {"dispatch": bool(config_get("kanban.dispatch_in_gateway", True)),
                "failure_limit": config_get("kanban.failure_limit", 2)}

    def write_settings(self, changes: dict) -> None:
        from jarvis_power.stores import config_set
        if "dispatch" in changes:
            config_set("kanban.dispatch_in_gateway", bool(changes["dispatch"]))
        if "failure_limit" in changes:
            config_set("kanban.failure_limit", int(changes["failure_limit"]))

    def status_line(self) -> str:
        c = _counts()
        return f"{c['running']} running · {c['ready']} ready"

    def state(self) -> dict:
        return _counts()
