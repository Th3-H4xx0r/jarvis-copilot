"""A schedule runs on exactly one of: Default, a model, or a harness."""
import json

import pytest

from cron import jobs as cj


@pytest.fixture()
def cron_home(tmp_path, monkeypatch):
    monkeypatch.setattr(cj, "CRON_DIR", tmp_path / "cron")
    monkeypatch.setattr(cj, "JOBS_FILE", tmp_path / "cron" / "jobs.json")
    monkeypatch.setattr(cj, "OUTPUT_DIR", tmp_path / "cron" / "output")
    monkeypatch.setenv("HERMES_WEBUI_STATE_DIR", str(tmp_path / "webui"))
    designs = tmp_path / "webui" / "harnesses" / "default" / "designs"
    designs.mkdir(parents=True)
    (designs / "mail.json").write_text(json.dumps({"id": "mail", "name": "Mail triage", "nodes": [], "edges": []}))
    return tmp_path


def test_provider_qualified_model_is_stored_split(cron_home):
    job = cj.create_job(prompt="p", schedule="every 1h", model="@anthropic-api:claude-haiku-5-5")
    stored = cj.get_job(job["id"])
    assert (stored["model"], stored["provider"], stored.get("harness_id")) == (
        "claude-haiku-5-5", "anthropic-api", None)
    assert cj.runs_on(stored) == {"kind": "model", "label": "claude-haiku-5-5",
                                  "value": "model:@anthropic-api:claude-haiku-5-5"}


def test_harness_job(cron_home):
    job = cj.create_job(prompt="p", schedule="every 1h", harness_id="mail")
    stored = cj.get_job(job["id"])
    assert stored["harness_id"] == "mail" and stored["model"] is None and stored["provider"] is None
    assert cj.runs_on(stored) == {"kind": "harness", "label": "Mail triage", "value": "harness:mail"}


def test_missing_harness_label_says_so(cron_home):
    job = cj.create_job(prompt="p", schedule="every 1h", harness_id="gone")
    ro = cj.runs_on(cj.get_job(job["id"]))
    assert ro["kind"] == "harness" and ro["value"] == "harness:gone" and ro.get("missing") is True


def test_default_job(cron_home):
    job = cj.create_job(prompt="p", schedule="every 1h")
    assert cj.runs_on(cj.get_job(job["id"])) == {"kind": "default", "label": "Default", "value": "default"}
    assert "profile" not in cj.get_job(job["id"])


def test_model_and_harness_together_is_refused(cron_home):
    with pytest.raises(ValueError):
        cj.create_job(prompt="p", schedule="every 1h", model="@x:y", harness_id="mail")


def test_setting_a_harness_clears_the_model(cron_home):
    job = cj.create_job(prompt="p", schedule="every 1h", model="@anthropic-api:claude-haiku-5-5",
                        base_url="https://example.test/v1")
    upd = cj.update_job(job["id"], {"harness_id": "mail"})
    assert upd["harness_id"] == "mail"
    assert upd["model"] is None and upd["provider"] is None and upd["base_url"] is None


def test_setting_a_model_clears_the_harness(cron_home):
    job = cj.create_job(prompt="p", schedule="every 1h", harness_id="mail")
    upd = cj.update_job(job["id"], {"model": "@ollama-cloud:gemma4:31b"})
    assert (upd["model"], upd["provider"], upd["harness_id"]) == ("gemma4:31b", "ollama-cloud", None)


def test_default_clears_both(cron_home):
    job = cj.create_job(prompt="p", schedule="every 1h", model="@anthropic-api:claude-haiku-5-5")
    upd = cj.update_job(job["id"], {"model": "", "provider": "", "harness_id": ""})
    assert (upd["model"], upd["provider"], upd["harness_id"]) == (None, None, None)
    assert cj.runs_on(upd)["kind"] == "default"
    job = cj.create_job(prompt="p", schedule="every 1h", harness_id="mail")
    upd = cj.update_job(job["id"], {"model": None, "provider": None, "harness_id": None})
    assert cj.runs_on(upd)["kind"] == "default"


def test_migration_clears_job_profiles_once(cron_home, monkeypatch):
    cj.ensure_dirs()
    cj.JOBS_FILE.write_text(json.dumps({"jobs": [
        {"id": "a", "prompt": "p", "profile": "default", "schedule": {"kind": "interval", "minutes": 60}},
        {"id": "b", "prompt": "p", "profile": None, "schedule": {"kind": "interval", "minutes": 60}},
    ]}))
    saves = []
    real_save = cj.save_jobs
    monkeypatch.setattr(cj, "save_jobs", lambda jobs: saves.append(1) or real_save(jobs))
    assert all("profile" not in j for j in cj.load_jobs())
    assert all("profile" not in j for j in json.loads(cj.JOBS_FILE.read_text())["jobs"])
    cj.load_jobs()
    assert len(saves) == 1


def test_changing_what_a_job_runs_on_clears_a_stale_base_url(cron_home):
    job = cj.create_job(prompt="p", schedule="every 1h", model="@custom:box:llama3",
                        base_url="https://box.test/v1")
    assert cj.update_job(job["id"], {"model": "@ollama-cloud:gemma4:31b"})["base_url"] is None
    job = cj.create_job(prompt="p", schedule="every 1h", model="@custom:box:llama3",
                        base_url="https://box.test/v1")
    assert cj.update_job(job["id"], {"model": "", "provider": "", "harness_id": ""})["base_url"] is None


def test_a_base_url_sent_with_the_change_is_kept(cron_home):
    job = cj.create_job(prompt="p", schedule="every 1h", model="@a:m1", base_url="https://old.test")
    upd = cj.update_job(job["id"], {"model": "@b:m2", "base_url": "https://new.test"})
    assert upd["base_url"] == "https://new.test"


def test_resending_the_same_bare_model_keeps_provider_and_base_url(cron_home):
    job = cj.create_job(prompt="p", schedule="every 1h", model="@custom:box:llama3",
                        base_url="https://box.test/v1")
    upd = cj.update_job(job["id"], {"model": "llama3", "name": "renamed"})
    assert (upd["model"], upd["provider"], upd["base_url"]) == ("llama3", "custom:box", "https://box.test/v1")


def test_migration_does_not_save_while_another_writer_holds_the_lock(cron_home):
    cj.ensure_dirs()
    cj.JOBS_FILE.write_text(json.dumps({"jobs": [
        {"id": "a", "prompt": "p", "profile": "default", "schedule": {"kind": "interval", "minutes": 60}}]}))
    with cj._jobs_file_lock:
        assert "profile" not in cj.load_jobs()[0]          # migrated in memory
        assert "profile" in json.loads(cj.JOBS_FILE.read_text())["jobs"][0]   # the lock holder saves
    cj.load_jobs()
    assert "profile" not in json.loads(cj.JOBS_FILE.read_text())["jobs"][0]


def test_migration_saves_the_latest_file_not_a_stale_copy(cron_home, monkeypatch):
    cj.ensure_dirs()
    cj.JOBS_FILE.write_text(json.dumps({"jobs": [
        {"id": "a", "prompt": "p", "profile": "default", "next_run_at": "old"}]}))
    real_drop = cj._drop_job_profiles
    first = {"done": False}

    def drop_then_concurrent_write(jobs):
        changed = real_drop(jobs)
        if not first["done"]:
            # Another writer advances the job between our read and our save.
            first["done"] = True
            cj.JOBS_FILE.write_text(json.dumps({"jobs": [
                {"id": "a", "prompt": "p", "profile": "default", "next_run_at": "new"}]}))
        return changed

    monkeypatch.setattr(cj, "_drop_job_profiles", drop_then_concurrent_write)
    cj.load_jobs()
    saved = json.loads(cj.JOBS_FILE.read_text())["jobs"][0]
    assert saved["next_run_at"] == "new" and "profile" not in saved
