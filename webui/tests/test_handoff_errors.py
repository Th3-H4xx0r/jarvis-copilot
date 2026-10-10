"""A failed hand-off (harness node / escalation) reports its error — never an old reply, never silence.

The hidden session starts as a copy of the parent chat, so "the newest assistant
reply" without a guard is the parent's previous answer; and an error-only run
used to come back as "" and be dropped.
"""

import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

ERR = "No Claude account connected. Sign in with `claude /login` on the server."


@pytest.fixture
def sessions(monkeypatch, tmp_path):
    import api.config as config
    import api.models as models
    import api.streaming as streaming

    parent = SimpleNamespace(
        session_id="s1", workspace=str(tmp_path), profile=None,
        messages=[{"role": "user", "content": "q"},
                  {"role": "assistant", "content": "OLD parent reply"}],
    )
    store = {"s1": parent}

    class _Hidden(SimpleNamespace):
        def save(self):
            store[self.session_id] = self

    def _new_session(**kw):
        return _Hidden(session_id="hidden1", messages=[], **kw)

    def _run(sid, prompt, *a, **k):
        s = store[sid]
        s.messages = list(s.messages) + [
            {"role": "user", "content": prompt},
            {"role": "assistant", "content": ERR, "_error": True},
        ]

    monkeypatch.setattr(models, "new_session", _new_session)
    monkeypatch.setattr(models.Session, "load", staticmethod(lambda sid: store.get(sid)))
    monkeypatch.setattr(streaming, "_run_agent_streaming", _run)
    monkeypatch.setattr(config, "SESSION_DIR", tmp_path)
    return store


def test_harness_hand_off_failure_raises_instead_of_returning_the_parents_reply(sessions):
    import api.harness_runner as hr

    with pytest.raises(RuntimeError, match="No Claude account connected"):
        hr._run_hidden_turn({"id": "claude", "model": "@claude-code:claude-opus-5-5"}, "s1", "note")


def test_escalation_failure_raises_instead_of_returning_nothing(sessions):
    from agent.escalation import default_runner

    with pytest.raises(RuntimeError, match="No Claude account connected"):
        default_runner({"session_id": "s1", "model": "claude-opus-5-5", "provider": "claude-code",
                        "summary": "finish it", "reason": "slow"})
