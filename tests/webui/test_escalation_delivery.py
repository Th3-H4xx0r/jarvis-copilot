"""Plan 2.5 — escalation results reach the client through the webui surfaces.

Covers the two delivery paths that matter for backward compatibility:
  * live SSE fan-out — a stream registers its ``put(event, data)`` as a sink
  * HTTP poll fallback — ``api.background`` exposes read-only views so a client
    that reconnected between turns can still collect a result
"""
from __future__ import annotations

import time

import pytest

from agent import escalation


@pytest.fixture(autouse=True)
def _clean():
    escalation.reset_for_tests()
    yield
    escalation.reset_for_tests()


def _wait_for(pred, timeout=5.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if pred():
            return True
        time.sleep(0.01)
    return False


class TestSseFanoutContract:
    def test_a_stream_put_function_works_as_a_sink(self):
        """The sink signature must match streaming.py's ``put(event, data)``."""
        emitted = []

        def put(event, data):
            emitted.append((event, data))

        escalation.register_stream_sink("sess", put)
        job_id = escalation.start_escalation(
            session_id="sess", reason="r", summary="s", runner=lambda job: "answer")
        assert _wait_for(lambda: emitted)
        event, data = emitted[0]
        assert event == "escalation_result"
        assert data["type"] == "escalation_result"
        assert data["job_id"] == job_id
        assert data["text"] == "answer"

    def test_result_from_a_closed_stream_reaches_the_next_one(self):
        """The realistic case: the fast turn's stream is already gone."""
        first = []
        escalation.register_stream_sink("sess", lambda e, d: first.append(d))
        escalation.unregister_stream_sink("sess", first.append)  # wrong fn: no-op

        # Simulate the stream closing properly.
        escalation.reset_for_tests()
        job_id = escalation.start_escalation(
            session_id="sess", reason="r", summary="s", runner=lambda job: "late answer")
        assert _wait_for(lambda: escalation.pending_count("sess") == 1)

        second = []
        escalation.register_stream_sink("sess", lambda e, d: second.append(d))
        assert [d["job_id"] for d in second] == [job_id]


class TestBackgroundPollFallback:
    def test_jobs_are_listed_with_the_background_task_shape(self):
        from webui.api import background as bg

        job_id = escalation.start_escalation(
            session_id="sess", reason="deep research", summary="find X",
            runner=lambda job: "found X")
        assert _wait_for(lambda: escalation.get_job(job_id)["status"] == "done")
        rows = bg.get_escalation_tasks("sess")
        assert len(rows) == 1
        assert rows[0]["task_id"] == job_id
        assert rows[0]["answer"] == "found X"
        assert rows[0]["status"] == "done"
        assert set(rows[0]) >= {"task_id", "prompt", "answer", "completed_at"}

    def test_drain_returns_undelivered_results_once(self):
        from webui.api import background as bg

        escalation.start_escalation(
            session_id="sess", reason="r", summary="s", runner=lambda job: "text")
        assert _wait_for(lambda: escalation.pending_count("sess") == 1)
        assert [r["text"] for r in bg.drain_escalation_results("sess")] == ["text"]
        assert bg.drain_escalation_results("sess") == []

    def test_existing_background_helpers_are_untouched(self):
        from webui.api import background as bg

        bg.track_background("p", "b", "stream", "task1", "prompt")
        assert [t["task_id"] for t in bg.get_background_tasks("p")] == ["task1"]
        bg.complete_background("p", "task1", "done")
        assert [r["answer"] for r in bg.get_results("p")] == ["done"]
