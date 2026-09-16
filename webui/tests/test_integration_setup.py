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
    def __init__(self, profile=None):
        self.session_id = "abc123"
        self.profile = profile
        self.saved = False

    def save(self):
        self.saved = True


def test_the_session_is_pinned_to_the_tools_this_job_needs(monkeypatch):
    made: dict = {}
    monkeypatch.setattr("api.models.new_session",
                        lambda profile=None: made.setdefault("s", FakeSession(profile)))

    out = setup.start("Gym Sessions", profile="work")
    session = made["s"]
    assert out["session_id"] == "abc123"
    assert session.enabled_toolsets == ["registry", "cronjob", "skills", "forms"]
    assert session.integration_setup is True
    assert session.title == "Setting up Gym Sessions"
    # The client's profile, or the sheet builds the integration in another home.
    assert session.profile == "work"
    # Not saved: an abandoned + tap must not leave a session behind.
    assert session.saved is False


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
    monkeypatch.setattr("api.models.new_session", lambda profile=None: FakeSession(profile))

    assert setup.handle_post(object(), urlparse("/api/integrations/setup/start"),
                             {"name": "Gym"}) is True
    assert sent["status"] == 201 and sent["body"]["session_id"] == "abc123"
    assert setup.handle_post(object(), urlparse("/api/integrations"), {}) is False


def test_every_toolset_it_asks_for_actually_exists():
    """A name that is not a key in TOOLSETS is dropped without a word — the session
    would quietly have no way to make a schedule."""
    import toolsets

    for name in setup.SETUP_TOOLSETS:
        assert name in toolsets.TOOLSETS, f"{name!r} is not a real toolset"


def test_the_web_plus_button_starts_the_same_conversation():
    """No name prompt: the + opens a scoped session and hands it to the chat panel."""
    js = (Path(__file__).resolve().parents[1] / "static" / "integrations.js").read_text()
    assert "/api/integrations/setup/start" in js
    assert "showPromptDialog" not in js, "the + must not fall back to asking for a name"
    assert "loadSession(setup.session_id)" in js


def test_the_directive_rules_out_the_plan_card():
    """The plan tool is in the same toolset and invites proposing instead of building."""
    scoped = FakeSession()
    scoped.integration_setup = True
    directive = setup.directive_for(scoped)
    assert "Do NOT call `integration_plan_propose`" in directive


def test_the_directive_sends_it_to_make_a_space_first():
    """Without this it writes into `general` — there is no other way to make one."""
    scoped = FakeSession()
    scoped.integration_setup = True
    directive = setup.directive_for(scoped)
    assert "`integration_create` FIRST" in directive
    assert 'Never \ncall it for "general"' in directive or "general" in directive


def test_a_reloaded_setup_session_is_still_a_setup_session():
    """__init__ swallows unknown kwargs, so a flag set only on the object is lost
    on the first reload — and the next save() then strips it from disk."""
    from api.models import Session

    made = Session(session_id="x", integration_setup=True)
    assert setup.directive_for(made)

    reloaded = Session(**{"session_id": "x", "integration_setup": True})
    assert reloaded.integration_setup is True
    assert setup.directive_for(reloaded)
    assert made.compact().get("integration_setup") is True


def test_the_directive_says_an_integration_has_to_actually_run():
    """It built a name, a description and a settings document, then declared it
    ready — an empty shell the user has to work out for themselves."""
    scoped = FakeSession()
    scoped.integration_setup = True
    directive = setup.directive_for(scoped)
    assert "something RUNS in it" in directive
    # Watching something means a schedule, not a skill describing the watching.
    assert "that means a SCHEDULE" in directive
    assert "instructions nobody is following" in directive
