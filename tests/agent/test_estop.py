"""The global emergency stop holds NEW work without killing what is running."""

import json
import logging
import os
from pathlib import Path
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

    def test_unreadable_home_is_treated_as_engaged(self, home):
        """Path.exists() swallows OSError and answers False, which would fail
        OPEN. Probe with stat() so an unreadable home reads as paused."""
        estop.engage("x")
        real_stat = Path.stat

        def boom(self, *a, **kw):
            if self.name == estop.SENTINEL_NAME:
                raise PermissionError(13, "Permission denied")
            return real_stat(self, *a, **kw)

        with patch.object(Path, "stat", boom):
            assert estop.is_engaged() is True

    def test_missing_parent_directory_is_not_engaged(self, home):
        """A home that does not exist is "no pause", not a fail-safe trip."""
        assert estop.is_engaged() is False


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
    def test_cron_tick_returns_before_taking_its_lock(self, home, monkeypatch):
        """tick() returns 0 on an empty store too, so assert it never reaches
        the lock -- otherwise deleting the guard would not fail this test."""
        from cron import scheduler

        reached = []
        monkeypatch.setattr(scheduler, "_get_lock_paths",
                            lambda: reached.append(1) or (home, home / "l"))
        estop.engage("holding")
        assert scheduler.tick(verbose=False) == 0
        assert reached == [], "tick() proceeded past the estop guard"

        estop.disengage()
        scheduler.tick(verbose=False)
        assert reached, "guard did not lift -- tick never reached the lock"

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


class TestProfileCannotLiftTheFleetStop:
    """A worker profile must not be able to resume the whole fleet."""

    def test_profile_unpause_leaves_the_root_sentinel(self, tmp_path, monkeypatch):
        root = tmp_path / ".jarviscopilot"
        profile = root / "profiles" / "coder"
        profile.mkdir(parents=True)
        monkeypatch.setattr(os.path, "expanduser", lambda p: p.replace("~", str(tmp_path)))
        estop._logged_components.clear()

        (root / estop.SENTINEL_NAME).write_text('{"reason": "operator"}')
        monkeypatch.setenv("HERMES_HOME", str(profile))

        assert estop.is_engaged() is True
        estop.disengage()
        assert (root / estop.SENTINEL_NAME).exists(), "profile deleted the fleet stop"
        assert estop.is_engaged() is True, "profile resumed a fleet-wide pause"

    def test_fleet_flag_lifts_it(self, tmp_path, monkeypatch):
        root = tmp_path / ".jarviscopilot"
        root.mkdir(parents=True)
        monkeypatch.setattr(os.path, "expanduser", lambda p: p.replace("~", str(tmp_path)))
        monkeypatch.setenv("HERMES_HOME", str(root))
        estop._logged_components.clear()
        estop.engage("operator")
        assert estop.disengage(fleet=True) is True
        assert estop.is_engaged() is False


class TestOutageLogging:
    def test_a_second_outage_logs_again(self, home, caplog):
        """Lift + re-engage between two ticks is a NEW outage."""
        with caplog.at_level(logging.INFO, logger="test.estop"):
            estop.engage("first")
            estop.check_paused("cron", LOG)
            estop.disengage()
            estop.engage("second")
            estop.check_paused("cron", LOG)
        assert len(caplog.records) == 2
