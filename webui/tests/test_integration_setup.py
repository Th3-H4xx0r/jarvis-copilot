"""The setup sheet's session: scoped to one job, and only that job."""
from __future__ import annotations

import sys
from pathlib import Path
from urllib.parse import urlparse

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import api.helpers as helpers  # noqa: E402
import api.integration_setup as setup  # noqa: E402


@pytest.fixture()
def sent(monkeypatch):
    box: dict = {}

    def fake_j(handler, body, status=200):
        box["body"] = body
        box["status"] = status
        return True

    monkeypatch.setattr(helpers, "j", fake_j)
    return box


class FakeSession:
    def __init__(self):
        self.session_id = "abc123"
        self.saved = False

    def save(self):
        self.saved = True


def test_the_session_is_pinned_to_the_tools_this_job_needs(monkeypatch):
    made = FakeSession()
    monkeypatch.setattr("api.models.new_session", lambda: made)

    out = setup.start("Gym Sessions")
    assert out["session_id"] == "abc123"
    assert made.enabled_toolsets == ["registry", "cron", "skills"]
    assert made.integration_setup is True
    assert made.title == "Setting up Gym Sessions"
    assert made.saved is True


def test_only_a_setup_session_gets_the_directive():
    ordinary = FakeSession()
    assert setup.directive_for(ordinary) == ""

    scoped = FakeSession()
    scoped.integration_setup = True
    directive = setup.directive_for(scoped)
    assert "ONE new Jarvis integration" in directive
    # The two rules that make the sheet behave the way it was designed to.
    assert "as soon as it is settled" in directive
    assert "integration_ready" in directive


def test_the_http_surface(monkeypatch, sent):
    monkeypatch.setattr("api.models.new_session", lambda: FakeSession())

    assert setup.handle_post(object(), urlparse("/api/integrations/setup/start"),
                             {"name": "Gym"}) is True
    assert sent["status"] == 201 and sent["body"]["session_id"] == "abc123"
    assert setup.handle_post(object(), urlparse("/api/integrations"), {}) is False
