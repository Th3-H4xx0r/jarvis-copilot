"""Tests for jarviscopilot_cli.cron command handling."""

from argparse import Namespace

import pytest

from cron.jobs import create_job, get_job, list_jobs
from jarviscopilot_cli.cron import cron_command


@pytest.fixture()
def tmp_cron_dir(tmp_path, monkeypatch):
    monkeypatch.setattr("cron.jobs.CRON_DIR", tmp_path / "cron")
    monkeypatch.setattr("cron.jobs.JOBS_FILE", tmp_path / "cron" / "jobs.json")
    monkeypatch.setattr("cron.jobs.OUTPUT_DIR", tmp_path / "cron" / "output")
    monkeypatch.setenv("HERMES_WEBUI_STATE_DIR", str(tmp_path / "webui"))
    designs = tmp_path / "webui" / "harnesses" / "default" / "designs"
    designs.mkdir(parents=True)
    (designs / "mail.json").write_text('{"id": "mail", "name": "Mail triage", "nodes": [], "edges": []}')
    return tmp_path


class TestCronCommandLifecycle:
    def test_pause_resume_run(self, tmp_cron_dir, capsys):
        job = create_job(prompt="Check server status", schedule="every 1h")

        cron_command(Namespace(cron_command="pause", job_id=job["id"]))
        paused = get_job(job["id"])
        assert paused["state"] == "paused"

        cron_command(Namespace(cron_command="resume", job_id=job["id"]))
        resumed = get_job(job["id"])
        assert resumed["state"] == "scheduled"

        cron_command(Namespace(cron_command="run", job_id=job["id"]))
        triggered = get_job(job["id"])
        assert triggered["state"] == "scheduled"

        out = capsys.readouterr().out
        assert "Paused job" in out
        assert "Resumed job" in out
        assert "Triggered job" in out

    def test_edit_can_replace_and_clear_skills(self, tmp_cron_dir, capsys):
        job = create_job(
            prompt="Combine skill outputs",
            schedule="every 1h",
            skill="blogwatcher",
        )

        cron_command(
            Namespace(
                cron_command="edit",
                job_id=job["id"],
                schedule="every 2h",
                prompt="Revised prompt",
                name="Edited Job",
                deliver=None,
                repeat=None,
                skill=None,
                skills=["maps", "blogwatcher"],
                model="@anthropic-api:claude-haiku-5-5",
                clear_skills=False,
            )
        )
        updated = get_job(job["id"])
        assert updated["skills"] == ["maps", "blogwatcher"]
        assert updated["name"] == "Edited Job"
        assert updated["prompt"] == "Revised prompt"
        assert updated["schedule_display"] == "every 120m"
        assert (updated["model"], updated["provider"]) == ("claude-haiku-5-5", "anthropic-api")

        cron_command(
            Namespace(
                cron_command="edit",
                job_id=job["id"],
                schedule=None,
                prompt=None,
                name=None,
                deliver=None,
                repeat=None,
                skill=None,
                skills=None,
                model="",
                clear_skills=True,
            )
        )
        cleared = get_job(job["id"])
        assert cleared["skills"] == []
        assert cleared["skill"] is None
        assert (cleared["model"], cleared["provider"]) == (None, None)

        out = capsys.readouterr().out
        assert "Updated job" in out

    def test_create_with_multiple_skills(self, tmp_cron_dir, capsys):
        cron_command(
            Namespace(
                cron_command="create",
                schedule="every 1h",
                prompt="Use both skills",
                name="Skill combo",
                deliver=None,
                repeat=None,
                skill=None,
                skills=["blogwatcher", "maps"],
                harness="mail",
            )
        )
        out = capsys.readouterr().out
        assert "Created job" in out

        jobs = list_jobs()
        assert len(jobs) == 1
        assert jobs[0]["skills"] == ["blogwatcher", "maps"]
        assert jobs[0]["name"] == "Skill combo"
        assert jobs[0]["harness_id"] == "mail" and jobs[0]["model"] is None
        assert "profile" not in jobs[0]


def test_cli_parser_has_model_and_harness_flags_not_profile():
    import contextlib
    import io
    import sys

    from jarviscopilot_cli import main as cli_main

    argv = ["jarviscopilot", "cron", "create", "every 1h", "hi", "--harness", "mail", "--model", "@a:b"]
    seen = {}

    def fake_cron_command(args):
        seen.update(vars(args))
        return 0

    with pytest.MonkeyPatch.context() as mp:
        mp.setattr(sys, "argv", argv)
        mp.setattr("jarviscopilot_cli.cron.cron_command", fake_cron_command)
        with contextlib.suppress(SystemExit), contextlib.redirect_stdout(io.StringIO()):
            cli_main.main()
    assert seen.get("harness") == "mail" and seen.get("model") == "@a:b"
    assert "profile" not in seen
