"""The global emergency stop holds NEW work without killing what is running."""

import json
import logging
import os
from unittest.mock import patch

import pytest

from agent import estop

LOG = logging.getLogger("test.estop")


@pytest.fixture
def home(tmp_path, monkeypatch):
    """An isolated HERMES_HOME, with the per-engagement log flags reset."""
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    estop._logged_components.clear()
    yield tmp_path
    estop._logged_components.clear()


class TestEngageAndLift:
    def test_starts_clear(self, home):
        assert estop.is_engaged() is False
        assert estop.get_state() is None
        assert estop.paused_reply() is None

    def test_engage_records_reason_and_timestamp(self, home):
        path = estop.engage("deploying")
        assert path.exists()
        body = json.loads(path.read_text())
        assert body["reason"] == "deploying"
        assert body["engaged_at"]
        assert estop.is_engaged() is True
        assert estop.get_state()["reason"] == "deploying"

    def test_engage_without_reason(self, home):
        estop.engage()
        assert estop.is_engaged() is True
        assert estop.get_state()["reason"] is None

    def test_engage_is_idempotent(self, home):
        estop.engage("first")
        estop.engage("second")
        assert estop.get_state()["reason"] == "second"

    def test_disengage_lifts_and_is_idempotent(self, home):
        estop.engage("x")
        assert estop.disengage() is True
        assert estop.is_engaged() is False
        assert estop.disengage() is False


class TestFailSafe:
    """Anything ambiguous must resolve to "paused", never to "keep working"."""

    def test_empty_sentinel_still_pauses(self, home):
        """`touch ~/.jarviscopilot/ESTOP` has to work as a panic button."""
        (home / estop.SENTINEL_NAME).write_text("")
        assert estop.is_engaged() is True
        assert estop.get_state() == {"reason": None, "engaged_at": None}

    def test_corrupt_sentinel_still_pauses(self, home):
        (home / estop.SENTINEL_NAME).write_text("{not json at all")
        assert estop.is_engaged() is True
        assert estop.get_state() == {"reason": None, "engaged_at": None}

    def test_non_dict_body_still_pauses(self, home):
        (home / estop.SENTINEL_NAME).write_text('["a list"]')
        assert estop.is_engaged() is True

    def test_stat_error_is_treated_as_engaged(self, home):
        with patch("pathlib.Path.exists", side_effect=OSError("stat failed")):
            assert estop.is_engaged() is True


class TestLoggingOncePerEngagement:
    def test_logs_once_then_stays_quiet(self, home, caplog):
        estop.engage("noisy")
        with caplog.at_level(logging.INFO, logger="test.estop"):
            assert estop.check_paused("cron", LOG) is True
            assert estop.check_paused("cron", LOG) is True
            assert estop.check_paused("cron", LOG) is True
        assert len(caplog.records) == 1

    def test_each_component_logs_for_itself(self, home, caplog):
        estop.engage(None)
        with caplog.at_level(logging.INFO, logger="test.estop"):
            estop.check_paused("cron", LOG)
            estop.check_paused("kanban", LOG)
        assert len(caplog.records) == 2

    def test_flag_rearms_after_a_lift(self, home, caplog):
        estop.engage(None)
        with caplog.at_level(logging.INFO, logger="test.estop"):
            estop.check_paused("cron", LOG)
            estop.disengage()
            assert estop.check_paused("cron", LOG) is False
            estop.engage(None)
            estop.check_paused("cron", LOG)
        assert len(caplog.records) == 2

    def test_check_paused_is_false_when_clear(self, home):
        assert estop.check_paused("cron", LOG) is False


class TestProfilesHonourTheFleetRoot:
    def test_profile_home_sees_an_operator_stop_at_the_root(self, tmp_path, monkeypatch):
        """A profile gateway must not ignore ~/.jarviscopilot/ESTOP."""
        root = tmp_path / ".jarviscopilot"
        profile = root / "profiles" / "coder"
        profile.mkdir(parents=True)
        monkeypatch.setattr(os.path, "expanduser", lambda p: p.replace("~", str(tmp_path)))
        monkeypatch.setenv("HERMES_HOME", str(profile))
        estop._logged_components.clear()

        assert estop.is_engaged() is False
        (root / estop.SENTINEL_NAME).write_text("{}")
        assert estop.is_engaged() is True, "profile ignored the fleet-root stop"


class TestCallersRefuseWork:
    def test_cron_tick_runs_no_jobs_while_paused(self, home):
        from cron import scheduler

        estop.engage("holding")
        assert scheduler.tick(verbose=False) == 0

    def test_kanban_dispatch_is_a_no_op_while_paused(self, home):
        from jarviscopilot_cli import kanban_db

        estop.engage("holding")
        result = kanban_db.dispatch_once(conn=None)
        assert result.reclaimed == 0
        assert result.promoted == 0
        assert result.spawned == []

    def test_paused_reply_names_the_reason(self, home):
        estop.engage("deploying")
        reply = estop.paused_reply()
        assert "deploying" in reply
        assert "unpause" in reply
