"""`/refine` runs the memory/skill review on demand.

The background review fires on its own schedule, so there was no way to say
"you just learned something, write it down" at the moment it mattered -- the
engine existed, the trigger did not.
"""

import types
from unittest.mock import MagicMock

import pytest

import cli as climod
import gateway.run as gr
from jarviscopilot_cli.commands import GATEWAY_KNOWN_COMMANDS, resolve_command


@pytest.fixture
def spawned():
    return []


@pytest.fixture
def console_cli(spawned):
    c = object.__new__(climod.HermesCLI)
    c.console = MagicMock()
    c.agent = types.SimpleNamespace(
        messages=[{"role": "user", "content": "hi"}],
        _spawn_background_review=lambda m, **kw: spawned.append(kw),
    )
    return c


class TestRegistration:
    def test_resolves_and_reaches_the_gateway(self):
        assert resolve_command("refine").name == "refine"
        assert "refine" in GATEWAY_KNOWN_COMMANDS


class TestCliSurface:
    def test_default_reviews_both(self, console_cli, spawned):
        console_cli._handle_refine_command("/refine")
        assert spawned[-1] == {"review_memory": True, "review_skills": True}

    @pytest.mark.parametrize("arg,memory,skills", [
        ("memory", True, False),
        ("skills", False, True),
        ("both", True, True),
    ])
    def test_argument_selects_the_target(self, console_cli, spawned, arg, memory, skills):
        console_cli._handle_refine_command(f"/refine {arg}")
        assert spawned[-1] == {"review_memory": memory, "review_skills": skills}

    def test_an_unknown_argument_is_refused_without_spawning(self, console_cli, spawned):
        console_cli._handle_refine_command("/refine nonsense")
        assert spawned == []
        assert "Usage" in str(console_cli.console.print.call_args)

    def test_no_agent_says_so_instead_of_raising(self, spawned):
        c = object.__new__(climod.HermesCLI)
        c.console = MagicMock()
        c.agent = None
        c._handle_refine_command("/refine")
        assert spawned == []
        assert "Nothing to review" in str(c.console.print.call_args)

    def test_an_empty_conversation_is_not_reviewed(self, spawned):
        c = object.__new__(climod.HermesCLI)
        c.console = MagicMock()
        c.agent = types.SimpleNamespace(
            messages=[], _spawn_background_review=lambda m, **kw: spawned.append(kw))
        c._handle_refine_command("/refine")
        assert spawned == []

    def test_a_failing_spawn_is_reported_not_raised(self, spawned):
        def boom(*_a, **_k):
            raise RuntimeError("no thread")
        c = object.__new__(climod.HermesCLI)
        c.console = MagicMock()
        c.agent = types.SimpleNamespace(
            messages=[{"role": "user", "content": "x"}], _spawn_background_review=boom)
        c._handle_refine_command("/refine")
        assert "Could not start" in str(c.console.print.call_args)


class TestGatewaySurface:
    def _runner(self, agent):
        r = object.__new__(gr.GatewayRunner)
        r.session_store = MagicMock()
        r.session_store.get_or_create_session.return_value = types.SimpleNamespace(
            session_key="s1")
        r._running_agents = {"s1": agent} if agent is not None else {}
        return r

    def _event(self, text):
        return types.SimpleNamespace(text=text, source=types.SimpleNamespace())

    def test_reviews_the_running_session(self, spawned):
        agent = types.SimpleNamespace(
            messages=[{"role": "user", "content": "hi"}],
            _spawn_background_review=lambda m, **kw: spawned.append(kw))
        reply = self._runner(agent)._handle_refine_command(self._event("/refine memory"))
        assert spawned[-1] == {"review_memory": True, "review_skills": False}
        assert "memory" in reply

    def test_no_running_agent_is_explained(self):
        reply = self._runner(None)._handle_refine_command(self._event("/refine"))
        assert "nothing to review" in reply.lower()

    def test_bad_argument_is_refused(self, spawned):
        agent = types.SimpleNamespace(
            messages=[{"role": "user", "content": "hi"}],
            _spawn_background_review=lambda m, **kw: spawned.append(kw))
        reply = self._runner(agent)._handle_refine_command(self._event("/refine nope"))
        assert "Usage" in reply
        assert spawned == []
