"""/api/crons: a schedule runs on Default, a model or a harness (no per-job profile)."""
from __future__ import annotations

import io
import json

import pytest


class _Handler:
    def __init__(self):
        self.status = None
        self.headers = {}
        self.response_headers = []
        self.wfile = io.BytesIO()

    def send_response(self, status):
        self.status = status

    def send_header(self, key, value):
        self.response_headers.append((key, value))

    def end_headers(self):
        pass


def _body(h):
    return json.loads(h.wfile.getvalue().decode("utf-8"))


@pytest.fixture()
def cron_home(tmp_path, monkeypatch):
    import cron.jobs as cj
    monkeypatch.setattr(cj, "CRON_DIR", tmp_path / "cron")
    monkeypatch.setattr(cj, "JOBS_FILE", tmp_path / "cron" / "jobs.json")
    monkeypatch.setattr(cj, "OUTPUT_DIR", tmp_path / "cron" / "output")
    monkeypatch.setenv("HERMES_WEBUI_STATE_DIR", str(tmp_path / "webui"))
    from api.profiles import get_active_profile_name
    designs = tmp_path / "webui" / "harnesses" / (get_active_profile_name() or "default") / "designs"
    designs.mkdir(parents=True)
    (designs / "mail.json").write_text(json.dumps({"id": "mail", "name": "Mail triage", "nodes": [], "edges": []}))
    return cj


def _create(**body):
    import api.routes as routes
    h = _Handler()
    routes._handle_cron_create(h, {"prompt": "check mail", "schedule": "every 1h", **body})
    return h


def _update(**body):
    import api.routes as routes
    h = _Handler()
    routes._handle_cron_update(h, body)
    return h


def test_create_keeps_the_provider_of_a_qualified_model(cron_home):
    h = _create(model="@anthropic-api:claude-haiku-5-5")
    job = _body(h)["job"]
    assert h.status == 200
    stored = cron_home.get_job(job["id"])
    assert (stored["model"], stored["provider"]) == ("claude-haiku-5-5", "anthropic-api")
    assert job["runs_on"]["kind"] == "model" and "profile" not in job


def test_create_with_model_and_separate_provider(cron_home):
    job = _body(_create(model="gemma4:31b", provider="ollama-cloud"))["job"]
    assert cron_home.get_job(job["id"])["provider"] == "ollama-cloud"


def test_create_on_a_harness(cron_home):
    job = _body(_create(harness_id="mail"))["job"]
    assert job["runs_on"] == {"kind": "harness", "label": "Mail triage", "value": "harness:mail"}


def test_unknown_harness_is_refused(cron_home):
    h = _create(harness_id="nope")
    assert h.status == 400 and "nope" in _body(h)["error"]


def test_model_and_harness_together_is_refused(cron_home):
    assert _create(model="@a:b", harness_id="mail").status == 400


def test_profile_is_ignored(cron_home):
    job = _body(_create(profile="research"))["job"]
    assert "profile" not in cron_home.get_job(job["id"]) and job["runs_on"]["kind"] == "default"


def test_update_switches_and_clears_explicitly(cron_home):
    jid = _body(_create(model="@anthropic-api:claude-haiku-5-5"))["job"]["id"]
    job = _body(_update(job_id=jid, harness_id="mail", model="", provider=""))["job"]
    assert job["runs_on"]["kind"] == "harness" and job["model"] is None and job["provider"] is None
    job = _body(_update(job_id=jid, model="@ollama-cloud:gemma4:31b", provider="", harness_id=""))["job"]
    assert (job["model"], job["provider"], job["harness_id"]) == ("gemma4:31b", "ollama-cloud", None)
    job = _body(_update(job_id=jid, model=None, provider=None, harness_id=None))["job"]
    assert job["runs_on"] == {"kind": "default", "label": "Default", "value": "default"}
    assert (job["model"], job["provider"], job["harness_id"]) == (None, None, None)


def test_update_leaves_runs_on_alone_when_not_sent(cron_home):
    jid = _body(_create(harness_id="mail"))["job"]["id"]
    job = _body(_update(job_id=jid, name="Renamed"))["job"]
    assert job["harness_id"] == "mail" and job["name"] == "Renamed"


def test_update_with_unknown_harness_is_refused(cron_home):
    jid = _body(_create())["job"]["id"]
    assert _update(job_id=jid, harness_id="nope").status == 400


def test_list_payload_has_runs_on(cron_home):
    import api.routes as routes
    _create(harness_id="mail")
    payload = routes._cron_jobs_for_api(cron_home.list_jobs(include_disabled=True))
    assert payload and all("runs_on" in j and "profile" not in j for j in payload)


def test_manual_run_delivers_after_node_results_after_the_answer(monkeypatch):
    import api.routes as routes
    import cron.jobs as cj
    import cron.scheduler as sched

    sent, marks = [], []
    monkeypatch.setattr(sched, "_deliver_result",
                        lambda job, content, adapters=None, loop=None: sent.append(content))
    monkeypatch.setattr(cj, "save_job_output", lambda job_id, output: None)
    monkeypatch.setattr(cj, "mark_job_run", lambda job_id, ok, err=None, delivery_error=None: marks.append(ok))

    def fake_subprocess(job, cron_home):
        job["_after_deliveries"] = ["Review: corrected", "Background: done"]
        return True, "# out", "the answer", None

    monkeypatch.setattr(routes, "_run_cron_job_in_profile_subprocess", fake_subprocess)
    routes._mark_cron_running("after1")
    routes._run_cron_tracked({"id": "after1", "name": "after"})
    assert sent == ["the answer", "Review: corrected", "Background: done"] and marks == [True]


def test_editing_a_job_whose_harness_was_deleted_still_saves(cron_home, tmp_path):
    jid = _body(_create(harness_id="mail"))["job"]["id"]
    for f in (tmp_path / "webui").rglob("mail.json"):
        f.unlink()
    h = _update(job_id=jid, name="Renamed", harness_id="mail", model="", provider="")
    assert h.status == 200 and _body(h)["job"]["name"] == "Renamed"
    assert _body(h)["job"]["runs_on"].get("missing") is True
