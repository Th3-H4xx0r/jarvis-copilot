"""The 'left for later' follow-ups: time budget, settings in version, Health schedule, kanban daemon."""
from __future__ import annotations

import time

from jarvis_power import api, discovery, state, switch

from .conftest import simple

SLOW = '''
import time
from jarvis_power import PowerIntegration

class Slow(PowerIntegration):
    id = "{id}"
    name = "{name}"
    icon = "bolt"
    summary = "Answers slowly."
    calls = 0

    def status_line(self):
        type(self).calls += 1
        time.sleep(4)
        return "late"
'''


def test_rows_answer_within_the_budget_and_reuse_a_stuck_call(fake_pkg, reg):
    fake_pkg({f"s{i}": SLOW.format(id=f"s{i}", name=f"S{i}") for i in range(4)})
    state.ensure_all()
    t = time.monotonic()
    body = api.rows(budget=1.0)
    assert time.monotonic() - t < 2.0
    assert len(body["integrations"]) == 4
    api.rows(budget=0.5)                       # the first calls are still running…
    for p in discovery.integrations().values():
        assert type(p).calls == 1              # …so no second call piles up


def test_settings_change_changes_version(fake_pkg, reg):
    fake_pkg({"alpha": simple(extra='''
    from jarvis_power import Setting as _S
    settings = (_S("mode", "Mode", "toggle", default=False),)
    stored = {}

    def read_settings(self):
        return dict(type(self).stored)

    def write_settings(self, changes):
        type(self).stored.update(changes)
''')})
    state.ensure_all()
    before = state.version()
    switch.request_settings("alpha", {"mode": True}, by="app")
    assert state.version() != before


def test_health_on_rechecks_its_schedule(reg, monkeypatch):
    import cron.jobs as jobs
    from jarvis_health.bootstrap import ensure_schedule
    discovery.reset()
    state.ensure_all()
    p = discovery.get("jarvis-health")
    assert "webui" in p.processes
    ensure_schedule({"enabled": True, "frequency": "manual"})
    switch.request_enabled("jarvis-health", False, by="app")
    # Edited while off: from "manual" to every 6 hours.
    reg.open("jarvis-health").put("settings", {"enabled": True, "frequency": "every 6 hours"})
    switch.request_enabled("jarvis-health", True, by="app")
    p.start("webui")
    [job] = [j for j in jobs.load_jobs() if j.get("integration") == "jarvis-health"]
    assert job["enabled"] is True


def test_kanban_daemon_skips_ticks_while_off(reg, monkeypatch):
    import threading
    from jarviscopilot_cli import kanban_db as kb
    discovery.reset()
    state.ensure_all()
    state.write_enabled("kanban", False, by="app")
    ticks = []
    monkeypatch.setattr(kb, "dispatch_once", lambda *a, **k: ticks.append(1))
    stop = threading.Event()
    t = threading.Thread(target=kb.run_daemon, kwargs={"interval": 0.05, "stop_event": stop}, daemon=True)
    t.start()
    time.sleep(0.3)
    stop.set()
    t.join(2)
    assert ticks == []
