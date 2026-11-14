"""Kanban as a Power integration: off stops the dispatcher and puts running tasks back."""
from __future__ import annotations

from jarvis_power import discovery, state


def _board_with_running_task():
    from jarviscopilot_cli import kanban_db as kb
    conn = kb.connect()
    task_id = kb.create_task(conn, title="Write the report", assignee="default")
    conn.execute("UPDATE tasks SET status='ready' WHERE id=?", (task_id,))
    conn.commit()
    assert kb.claim_task(conn, task_id, claimer="test") is not None
    return conn, task_id


def test_kanban_off_kills_running_and_requeues(reg):
    discovery.reset()
    state.ensure_all()
    conn, task_id = _board_with_running_task()
    p = discovery.get("kanban")
    p.stop("gateway")
    row = conn.execute("SELECT status, claim_lock FROM tasks WHERE id=?", (task_id,)).fetchone()
    assert row["status"] == "ready" and row["claim_lock"] is None


def test_kanban_declares_its_surfaces_and_tools():
    discovery.reset()
    p = discovery.get("kanban")
    assert "kanban" in p.toolsets and "/api/kanban" in p.route_prefixes
    assert discovery.validate(p) == []


def test_kanban_status_line_counts(reg):
    discovery.reset()
    state.ensure_all()
    _board_with_running_task()
    assert "1 running" in discovery.get("kanban").status_line()
