"""The health endpoints the phone reads, and the one rule about who may write.

Settings belong to the Health tab: a write that does not come from there is
refused, so the Integrations page can show them without owning them.
"""
import json
import sys
from pathlib import Path
from urllib.parse import urlparse

import pytest

ROOT = Path(__file__).resolve().parents[2]
for path in (str(ROOT), str(ROOT / "webui"), str(ROOT / "webui" / "api")):
    if path not in sys.path:
        sys.path.insert(0, path)


class FakeHandler:
    def __init__(self):
        self.status = None
        self.payload = None
        self.wfile = self
        self.headers = {}

    def send_response(self, status):
        self.status = status

    def send_header(self, *args):
        pass

    def end_headers(self):
        pass

    def write(self, data):
        try:
            self.payload = json.loads(bytes(data).decode())
        except Exception:
            self.payload = None

    def flush(self):
        pass


@pytest.fixture
def health(tmp_path, monkeypatch):
    import jarvis_registry.store as store_module

    registry = store_module.Registry(tmp_path / "registry.db")
    monkeypatch.setattr(store_module, "shared", lambda: registry)

    import cron.jobs as jobs

    monkeypatch.setattr(jobs, "CRON_DIR", tmp_path / "cron")
    monkeypatch.setattr(jobs, "JOBS_FILE", tmp_path / "cron" / "jobs.json")
    (tmp_path / "cron").mkdir(parents=True, exist_ok=True)

    from jarvis_health.bootstrap import ensure_health_integration

    return ensure_health_integration([{
        "kind": "ring",
        "device_id": "B6CE93C4-5680",
        "name": "R12_7E04",
        "bridge_device_id": "iphone-1",
        "timezone": "America/Chicago",
    }])["space"]


def get(path):
    from api import health_routes

    handler = FakeHandler()
    claimed = health_routes.handle_get(handler, urlparse(path))
    return claimed, handler


def post(path, body):
    from api import health_routes

    handler = FakeHandler()
    claimed = health_routes.handle_post(handler, urlparse(path), body)
    return claimed, handler


def test_a_run_with_no_reachable_wearable_says_so_rather_than_guessing(tmp_path, monkeypatch):
    import jarvis_registry.store as store_module

    monkeypatch.setattr(store_module, "shared", lambda: store_module.Registry(tmp_path / "r.db"))
    from jarvis_health.store import HealthStore

    HealthStore().upsert_device({"kind": "ring", "device_id": "aaaa0000"})  # no phone to reach it
    claimed, handler = post("/api/integrations/jarvis-health/health/run", {})
    assert claimed and handler.status == 200
    assert handler.payload["run"]["skipped"] == "unreachable"


def test_the_phone_can_register_its_wearables_and_repeats_are_idempotent(tmp_path, monkeypatch):
    import jarvis_registry.store as store_module

    registry = store_module.Registry(tmp_path / "registry.db")
    monkeypatch.setattr(store_module, "shared", lambda: registry)
    import cron.jobs as jobs

    monkeypatch.setattr(jobs, "CRON_DIR", tmp_path / "cron")
    monkeypatch.setattr(jobs, "JOBS_FILE", tmp_path / "cron" / "jobs.json")
    (tmp_path / "cron").mkdir(parents=True, exist_ok=True)

    roster = [
        {"kind": "ring", "device_id": "B6CE93C4-5680", "name": "R12_7E04"},
        {"kind": "bottle", "device_id": "other", "name": "Bottle"},
    ]
    claimed, handler = post("/api/health/devices", {"devices": roster})
    assert claimed and handler.status == 200
    assert handler.payload["space"] == "jarvis-health"

    claimed, again = post("/api/health/devices", {"devices": roster})
    assert again.payload["space"] == "jarvis-health"
    assert len(again.payload["devices"]) == 1, "the bottle reports nothing worth scoring"


def test_a_roster_that_is_not_a_list_is_refused(health):
    claimed, handler = post("/api/health/devices", {"devices": "ring"})
    assert claimed and handler.status == 400


def test_paths_that_are_not_ours_are_left_alone(health):
    assert get("/api/integrations")[0] is False
    assert get(f"/api/integrations/{health}")[0] is False
    assert post("/api/integrations", {})[0] is False


def test_wearables_are_listed_from_the_shared_roster(health):
    claimed, handler = get("/api/health/devices")
    assert claimed and handler.status == 200
    devices = handler.payload["devices"]
    assert devices[0]["key"] == "ring-b6ce93c4"
    assert devices[0]["kind"] == "ring" and devices[0]["linked"] is True


def test_settings_are_readable_and_say_where_they_are_edited(health):
    claimed, handler = get(f"/api/integrations/{health}/health/settings")
    assert claimed and handler.status == 200
    assert handler.payload["settings"]["enabled"] is True
    assert "Health tab" in handler.payload["edited_in"]


def test_only_the_health_tab_may_write_settings(health):
    claimed, handler = post(
        f"/api/integrations/{health}/health/settings",
        {"source": "health-settings", "model": "claude-opus-5"},
    )
    assert claimed and handler.status == 200
    assert handler.payload["settings"]["model"] == "claude-opus-5"

    claimed, refused = post(f"/api/integrations/{health}/health/settings", {"model": "sneaky"})
    assert claimed and refused.status == 403
    assert "Health tab" in refused.payload["error"]

    claimed, handler = get(f"/api/integrations/{health}/health/settings")
    assert handler.payload["settings"]["model"] == "claude-opus-5"


def test_a_settings_change_rewrites_the_schedule(health):
    import cron.jobs as jobs

    post(
        f"/api/integrations/{health}/health/settings",
        {"source": "health-settings", "frequency": "hourly"},
    )
    owned = [j for j in jobs.load_jobs() if j.get("integration") == health]
    assert owned and owned[0]["schedule"]["minutes"] == 60


def test_a_rule_threshold_can_be_edited_alone(health):
    claimed, handler = post(
        f"/api/integrations/{health}/health/settings",
        {"source": "health-settings", "rules": {"short_sleep": {"threshold": 4}}},
    )
    rules = handler.payload["settings"]["rules"]
    assert rules["short_sleep"]["threshold"] == 4
    assert rules["spo2_low"]["enabled"] is True


def test_pushing_a_day_stores_it_and_a_second_push_replaces_it(health):
    day = {
        "date": "2026-09-17",
        "timezone": "America/Chicago",
        "activity": {"steps": 100},
        "heart_rate": {"interval_minutes": 5, "values": [0, 70, 72]},
        "source": "ring",
        "device_id": "B6CE93C4-5680",
    }
    claimed, handler = post(f"/api/integrations/{health}/health/day", {"day": day})
    assert claimed and handler.status == 200
    assert handler.payload["date"] == "2026-09-17"

    day["activity"]["steps"] = 900
    post(f"/api/integrations/{health}/health/day", {"day": day})

    from jarvis_health.store import HealthStore

    store = HealthStore(health)
    assert store.day("2026-09-17", "ring-b6ce93c4").activity["steps"] == 900
    assert store.dates(10) == ["2026-09-17"]


def test_a_day_without_a_date_is_refused(health):
    claimed, handler = post(f"/api/integrations/{health}/health/day", {"day": {"activity": {}}})
    assert claimed and handler.status == 400


def test_scores_for_a_day_come_back_with_their_analysis(health):
    from jarvis_health.store import HealthStore

    HealthStore(health).put_scores("2026-09-17", {"health": {"value": 78}, "analysis": "Short night."})
    claimed, handler = get(f"/api/integrations/{health}/health/day/2026-09-17")
    assert claimed and handler.status == 200
    assert handler.payload["scores"]["health"]["value"] == 78
    assert handler.payload["scores"]["analysis"] == "Short night."


def test_a_day_with_no_scores_yet_says_so_rather_than_failing(health):
    claimed, handler = get(f"/api/integrations/{health}/health/day/2026-01-01")
    assert claimed and handler.status == 200
    assert handler.payload["scores"] is None


def test_run_now_reports_what_the_run_did(health, monkeypatch):
    import jarvis_health.runner as runner

    monkeypatch.setattr(runner, "run", lambda *a, **k: {"scored_date": "2026-09-17", "stale": False})
    # The run needs both identities; the roster supplied them.
    claimed, handler = post(f"/api/integrations/{health}/health/run", {"source": "health-settings"})
    assert claimed and handler.status == 200
    assert handler.payload["run"]["scored_date"] == "2026-09-17"


def test_an_unknown_space_is_a_404_not_a_crash(health):
    claimed, handler = get("/api/integrations/wearable-ring-nope/health/settings")
    assert claimed and handler.status == 404


def test_a_protected_wearable_integration_cannot_be_deleted(health):
    from api import integrations_routes

    handler = FakeHandler()
    claimed = integrations_routes.handle_delete(handler, urlparse(f"/api/integrations/{health}"), {})
    assert claimed
    assert handler.status == 409
    assert handler.payload["protected"] is True

    from jarvis_registry.store import shared

    assert shared().exists(health), "the space and its history survive"


def test_the_integration_list_says_which_ones_are_protected(health):
    from api import integrations_routes

    handler = FakeHandler()
    integrations_routes.handle_get(handler, urlparse("/api/integrations"))
    rows = {row["id"]: row for row in handler.payload["integrations"]}
    assert rows[health]["protected"] is True
    assert rows.get("general", {}).get("protected") in (False, None)


def test_health_writes_are_refused_for_a_space_that_is_not_a_wearables(health):
    from jarvis_registry.store import shared

    shared().space("general", name="General", description="not a wearable")

    claimed, handler = post("/api/integrations/general/health/settings",
                            {"source": "health-settings", "device_id": "PWN", "kind": "ring"})
    assert claimed and handler.status == 404

    claimed, day = post("/api/integrations/general/health/day", {"day": {"date": "2026-09-17"}})
    assert claimed and day.status == 404

    claimed, run = post("/api/integrations/general/health/run", {})
    assert claimed and run.status == 404

    import cron.jobs as jobs

    assert not [j for j in jobs.load_jobs() if j.get("integration") == "general"]
