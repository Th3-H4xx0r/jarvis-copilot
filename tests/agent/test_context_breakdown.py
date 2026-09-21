"""`/context` answers "what is my floor made of" without an investigation.

The composition was already computed for the webui, but only for a completed
API call -- so from inside a session the only way to learn which section owned
the token floor was to instrument a run by hand.
"""

import types

from agent.context_breakdown import compute, render


def _agent(**kw):
    base = dict(
        _prompt_sections={"system_prompt": 18000, "skills": 11600},
        tools=[{"function": {"name": "terminal", "description": "x" * 400}}],
        messages=[{"role": "user", "content": "hello"}],
        model="",
    )
    base.update(kw)
    return types.SimpleNamespace(**base)


class TestCompute:
    def test_sections_come_from_the_prompt_labels(self):
        out = compute(_agent())
        assert set(out["sections"]) >= {"system_prompt", "skills"}
        assert out["sections"]["system_prompt"] > out["sections"]["skills"]

    def test_total_is_the_sum_of_sections(self):
        out = compute(_agent())
        assert out["total"] == sum(out["sections"].values())

    def test_tool_schemas_are_counted(self):
        assert compute(_agent())["sections"]["tool_schemas"] > 0

    def test_conversation_history_excludes_the_system_message(self):
        """The system prompt is already accounted for by its sub-sections."""
        agent = _agent(messages=[
            {"role": "system", "content": "x" * 40000},
            {"role": "user", "content": "hi"},
        ])
        assert compute(agent)["sections"]["conversation_history"] < 100

    def test_falls_back_to_the_cached_prompt_when_unlabelled(self):
        """An old resumed session has no sub-section labels; the bulk of the
        input must still be visible rather than silently missing."""
        agent = _agent(_prompt_sections={}, _cached_system_prompt="x" * 4000)
        assert compute(agent)["sections"]["system_prompt"] > 0

    def test_empty_agent_produces_no_sections(self):
        agent = types.SimpleNamespace(_prompt_sections={}, tools=None, messages=[], model="")
        out = compute(agent)
        assert out["sections"] == {}
        assert out["total"] == 0

    def test_malformed_section_values_are_skipped(self):
        agent = _agent(_prompt_sections={"good": 400, "bad": "not a number"})
        sections = compute(agent)["sections"]
        assert "bad" not in sections
        assert "good" in sections

    def test_unknown_model_has_no_limit(self):
        out = compute(_agent(model="totally-made-up-model"))
        assert out["limit"] is None
        assert out["pct"] is None


class TestRender:
    def test_names_the_biggest_section(self):
        text = render(compute(_agent()))
        biggest_line = next(ln for ln in text.splitlines() if "<- biggest" in ln)
        assert "system prompt" in biggest_line

    def test_percentages_total_about_a_hundred(self):
        out = compute(_agent())
        shares = [v / out["total"] for v in out["sections"].values()]
        assert abs(sum(shares) - 1.0) < 0.001

    def test_renders_without_a_known_limit(self):
        assert "Context:" in render(compute(_agent(model="")))

    def test_empty_breakdown_says_so_rather_than_crashing(self):
        agent = types.SimpleNamespace(_prompt_sections={}, tools=None, messages=[], model="")
        assert "No context composition" in render(compute(agent))

    def test_output_is_labelled_as_an_estimate(self):
        """Proportions are the point; claiming exactness would be a lie."""
        assert "Estimated" in render(compute(_agent()))
