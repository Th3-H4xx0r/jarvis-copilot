"""Every eligible wearable gets an integration it cannot delete, and a schedule."""
import pytest

from jarvis_health.bootstrap import ensure_schedule, ensure_wearable_integrations
from jarvis_health.store import HealthStore

RING = {"kind": "ring", "device_id": "B6CE93C4-5680-B0C5-A3AA-32D3DD349E20", "name": "R12_7E04"}


@pytest.fixture
def tmp_jobs(tmp_path, monkeypatch):
    import cron.jobs as jobs

    monkeypatch.setattr(jobs, "CRON_DIR", tmp_path / "cron")
    monkeypatch.setattr(jobs, "JOBS_FILE", tmp_path / "cron" / "jobs.json")
    (tmp_path / "cron").mkdir(parents=True, exist_ok=True)
    return jobs


def test_an_eligible_wearable_gets_a_protected_space(tmp_registry, tmp_jobs):
    ids = ensure_wearable_integrations([RING])
    assert ids == ["wearable-ring-b6ce93c4"]
    assert HealthStore(ids[0]).settings()["protected"] is True


def test_the_space_gets_a_schedule_owned_by_the_integration(tmp_registry, tmp_jobs):
    ids = ensure_wearable_integrations([RING])
    owned = [j for j in tmp_jobs.load_jobs() if j.get("integration") == ids[0]]
    assert len(owned) == 1
    assert "jarvis_health.runner" in (owned[0].get("script") or "")


def test_an_ineligible_wearable_gets_nothing(tmp_registry, tmp_jobs):
    assert ensure_wearable_integrations([{"kind": "bottle", "device_id": "abc"}]) == []


def test_running_twice_does_not_duplicate_the_schedule(tmp_registry, tmp_jobs):
    ensure_wearable_integrations([RING])
    ensure_wearable_integrations([RING])
    owned = [j for j in tmp_jobs.load_jobs() if str(j.get("integration", "")).startswith("wearable-")]
    assert len(owned) == 1


def test_changing_the_frequency_rewrites_the_existing_job(tmp_registry, tmp_jobs):
    space_id = ensure_wearable_integrations([RING])[0]
    store = HealthStore(space_id)
    store.put_settings({"frequency": "hourly"})
    ensure_schedule(space_id, store.settings(), device_id=RING["device_id"], kind="ring")
    owned = [j for j in tmp_jobs.load_jobs() if j.get("integration") == space_id]
    assert len(owned) == 1
    # The scheduler normalises "every 1h" to minutes when it stores the job.
    assert owned[0]["schedule"]["minutes"] == 60


def test_a_disabled_integration_has_its_schedule_disabled(tmp_registry, tmp_jobs):
    space_id = ensure_wearable_integrations([RING])[0]
    store = HealthStore(space_id)
    store.put_settings({"enabled": False})
    ensure_schedule(space_id, store.settings(), device_id=RING["device_id"], kind="ring")
    owned = [j for j in tmp_jobs.load_jobs() if j.get("integration") == space_id]
    assert owned[0].get("enabled") is False
