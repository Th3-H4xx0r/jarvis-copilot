"""Every eligible wearable joins Jarvis Health, which has one schedule."""
import pytest

from jarvis_health.bootstrap import ensure_health_integration, ensure_schedule
from jarvis_health.store import SHARED_SPACE, HealthStore

RING = {"kind": "ring", "device_id": "B6CE93C4-5680-B0C5-A3AA-32D3DD349E20", "name": "R12_7E04",
        "bridge_device_id": "phone-1"}


@pytest.fixture
def tmp_jobs(tmp_path, monkeypatch):
    import cron.jobs as jobs

    monkeypatch.setattr(jobs, "CRON_DIR", tmp_path / "cron")
    monkeypatch.setattr(jobs, "JOBS_FILE", tmp_path / "cron" / "jobs.json")
    (tmp_path / "cron").mkdir(parents=True, exist_ok=True)
    return jobs


def _owned(jobs):
    return [j for j in jobs.load_jobs() if j.get("integration") == SHARED_SPACE]


def test_wearables_join_the_one_shared_integration(tmp_registry, tmp_jobs):
    out = ensure_health_integration([RING, {"kind": "bottle", "device_id": "cccc0000"}])
    assert out["space"] == SHARED_SPACE
    assert [d["key"] for d in HealthStore().roster()] == ["ring-b6ce93c4"]
    assert HealthStore().settings()["protected"] is True
    assert not any(s["id"].startswith("wearable-") for s in tmp_registry.spaces())


def test_the_schedule_runs_a_real_script_file_with_no_arguments(tmp_registry, tmp_jobs, tmp_path, monkeypatch):
    """The scheduler execs a file inside HERMES_HOME/scripts with no shell.

    A command line with flags is resolved as a filename, never runs, and turns
    every tick into a failure push.
    """
    import cron.scheduler as scheduler

    monkeypatch.setattr(scheduler, "_get_hermes_home", lambda: tmp_path)
    ensure_health_integration([RING])
    (job,) = _owned(tmp_jobs)
    script = job.get("script") or ""
    assert " " not in script, "a cron script is a filename, not a command line"
    body = (tmp_path / "scripts" / script).read_text()
    assert "jarvis_health.runner" in body

    ok, out = scheduler._run_job_script(script)
    assert "not found" not in out.lower(), out


def test_an_ineligible_wearable_is_not_added(tmp_registry, tmp_jobs):
    ensure_health_integration([{"kind": "bottle", "device_id": "abc"}])
    assert HealthStore().roster() == []


def test_one_schedule_for_all_wearables(tmp_registry, tmp_jobs):
    ensure_health_integration([RING])
    ensure_health_integration([{**RING, "device_id": "C0FFEE00-1"}])
    assert len(_owned(tmp_jobs)) == 1
    assert len(HealthStore().roster()) == 2


def test_changing_the_frequency_rewrites_the_existing_job(tmp_registry, tmp_jobs):
    ensure_health_integration([RING])
    store = HealthStore()
    store.put_settings({"frequency": "hourly"})
    ensure_schedule(store.settings())
    (job,) = _owned(tmp_jobs)
    # The scheduler normalises "every 1h" to minutes when it stores the job.
    assert job["schedule"]["minutes"] == 60


def test_a_disabled_integration_has_its_schedule_disabled(tmp_registry, tmp_jobs):
    ensure_health_integration([RING])
    store = HealthStore()
    store.put_settings({"enabled": False})
    ensure_schedule(store.settings())
    (job,) = _owned(tmp_jobs)
    assert job.get("enabled") is False
