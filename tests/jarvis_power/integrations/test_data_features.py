"""iMessage memory, Jarvis Health, Dashcam, Widgets and Island designs as Power integrations."""
from __future__ import annotations

import sys
from pathlib import Path

from jarvis_power import discovery, gate, state

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "webui"))


# ── iMessage memory ──────────────────────────────────────────────────────────
def test_imessage_seed_follows_settings(reg):
    from api import imessage_memory
    discovery.reset()
    p = discovery.get("imessage-memory")
    assert p.seed_enabled() is False                      # off by default, as before
    imessage_memory.store().update_settings(enabled=True)
    assert p.seed_enabled() is True


def test_imessage_config_reports_off(reg):
    from api import imessage_memory
    from api.imessage_memory_routes import mac_config
    discovery.reset()
    st = imessage_memory.store()
    st.update_settings(enabled=True)
    state.ensure_all()
    p = discovery.get("imessage-memory")
    p.stop("webui")
    assert mac_config(st)["enabled"] is False
    p.start("webui")
    assert mac_config(st)["enabled"] is True
    state.write_enabled("imessage-memory", False, by="app")
    assert gate.route_block("/api/imessage-memory/chats")["power_off"] == "imessage-memory"
    assert gate.route_block("/api/imessage-memory/config") is None


# ── Jarvis Health ───────────────────────────────────────────────────────────
def test_health_seed_on_even_if_analysis_off(reg):
    reg.space("jarvis-health", name="Jarvis Health").put("settings", {"enabled": False})
    discovery.reset()
    state.ensure_all()
    assert state.space_id_for("jarvis-health") == "jarvis-health"
    assert state.is_on("jarvis-health") is True
    assert discovery.get("jarvis-health").read_settings()["analysis"] is False


def test_health_uploads_land_while_off(reg):
    discovery.reset()
    state.ensure_all()
    state.write_enabled("jarvis-health", False, by="app")
    base = "/api/integrations/jarvis-health/health"
    for tail in ("day", "workouts", "workouts/route", "weights", "habits/relapse", "training/x"):
        assert gate.route_block(f"{base}/{tail}") is None, tail
    assert gate.route_block(f"{base}/run")["power_off"] == "jarvis-health"


def test_health_off_keeps_schedule_off(reg):
    import cron.jobs as jobs
    from jarvis_health.bootstrap import ensure_schedule
    discovery.reset()
    state.ensure_all()
    state.write_enabled("jarvis-health", False, by="app")
    job = ensure_schedule({"enabled": True, "frequency": "every 6 hours"})
    assert job is not None and job["enabled"] is False
    state.write_enabled("jarvis-health", True, by="app")
    job = ensure_schedule({"enabled": True, "frequency": "every 6 hours"})
    assert job["enabled"] is True
    assert len([j for j in jobs.load_jobs() if j.get("integration") == "jarvis-health"]) == 1


# ── Dashcam ─────────────────────────────────────────────────────────────────
def test_dashcam_off_stops_worker(reg, monkeypatch):
    from api import dashcam_relay
    discovery.reset()
    state.ensure_all()
    started = []

    class FakeWorker:
        def __init__(self, factory):
            self.alive = False

        def start(self):
            self.alive = True
            started.append(self)

        def is_alive(self):
            return self.alive

        def stop(self):
            self.alive = False

    monkeypatch.setattr(dashcam_relay, "RelayWorker", FakeWorker)
    monkeypatch.setattr(dashcam_relay, "_worker", None)
    state.write_enabled("dashcam", False, by="app")
    dashcam_relay.ensure_worker(lambda: None)
    assert started == []
    state.write_enabled("dashcam", True, by="app")
    dashcam_relay.ensure_worker(lambda: None)
    assert len(started) == 1
    discovery.get("dashcam").stop("webui")
    assert started[0].alive is False


# ── Island designs ──────────────────────────────────────────────────────────
def test_island_off_pushes_no_custom_design(reg):
    from api import island_la_push
    discovery.reset()
    state.ensure_all()
    state.write_enabled("island-designs", False, by="app")
    assert island_la_push.push_design_update(None, None, "my-design", force=True) == 0


def test_widgets_off_blocks_routes(reg):
    discovery.reset()
    state.ensure_all()
    state.write_enabled("widgets", False, by="app")
    assert gate.route_block("/api/widgets/designs")["power_off"] == "widgets"
