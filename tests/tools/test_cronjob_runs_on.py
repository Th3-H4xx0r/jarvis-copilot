"""The cronjob tool sets what a schedule runs on: a model, a harness, or Default."""
import json

import pytest

from cron import jobs as cj
from tools import cronjob_tools as ct


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


def _handler():
    from tools.registry import registry
    return registry.get_entry("cronjob").handler


def _call(**args):
    return json.loads(_handler()(args))


def test_create_on_a_harness_by_name(cron_home):
    out = _call(action="create", schedule="every 1h", prompt="check mail", harness="Mail triage")
    assert out["success"], out
    job = cj.get_job(out["job_id"])
    assert job["harness_id"] == "mail" and job["model"] is None
    assert out["job"]["runs_on"] == {"kind": "harness", "label": "Mail triage", "value": "harness:mail"}


def test_unknown_harness_is_an_error_that_names_the_choices(cron_home):
    out = _call(action="create", schedule="every 1h", prompt="x", harness="nope")
    assert out["success"] is False and "Mail triage" in out["error"]


def test_create_on_a_qualified_model(cron_home):
    out = _call(action="create", schedule="every 1h", prompt="x",
                model={"model": "@anthropic-api:claude-haiku-5-5"})
    job = cj.get_job(out["job_id"])
    assert (job["model"], job["provider"]) == ("claude-haiku-5-5", "anthropic-api")


def test_update_switches_between_model_harness_and_default(cron_home):
    jid = _call(action="create", schedule="every 1h", prompt="x",
                model={"provider": "ollama-cloud", "model": "gemma4:31b"})["job_id"]
    out = _call(action="update", job_id=jid, harness="mail")
    assert out["job"]["runs_on"]["kind"] == "harness" and cj.get_job(jid)["model"] is None
    out = _call(action="update", job_id=jid, model={"provider": "ollama-cloud", "model": "gemma4:31b"})
    assert out["job"]["runs_on"]["kind"] == "model" and cj.get_job(jid)["harness_id"] is None
    out = _call(action="update", job_id=jid, model={"model": ""}, harness="")
    assert out["job"]["runs_on"]["kind"] == "default"
    job = cj.get_job(jid)
    assert (job["model"], job["provider"], job["harness_id"]) == (None, None, None)


def test_schema_has_harness_and_no_profile():
    props = ct.CRONJOB_SCHEMA["parameters"]["properties"]
    assert "harness" in props and "profile" not in props
