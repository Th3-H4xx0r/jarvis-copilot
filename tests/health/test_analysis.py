"""The model writes prose about numbers it is handed, and nothing else."""
import json

from jarvis_health.analysis import build_prompt, write_analysis
from jarvis_health.scoring import activity_score, body_score, health_score, recovery_score, sleep_score

from .fixtures import day, ready_baseline


def parts(d=None, base=None):
    d = d or day(asleep=389, hrv=48)
    base = base or ready_baseline(hrv=43)
    sleep = sleep_score(d, base)
    recovery = recovery_score(d, base)
    body = body_score(d, base)
    activity = activity_score(d, {"steps": 10000, "active_minutes": 30})
    scores = {"sleep": sleep, "recovery": recovery, "body": body, "activity": activity}
    scores["health"] = health_score(scores)
    return d, base, scores


def test_the_prompt_carries_the_computed_numbers_and_forbids_diagnosis():
    d, base, scores = parts()
    msgs = build_prompt(d, scores, base)
    system = msgs[0]["content"].lower()
    payload = json.loads(msgs[1]["content"])

    assert "diagnos" in system
    assert "do not invent" in system or "only the numbers" in system
    assert payload["scores"]["health"]["value"] is not None
    assert payload["baseline"]["hrv"] == 43
    assert "sleep" in payload["contributions"]


def test_the_prompt_never_ships_raw_series():
    d, base, scores = parts()
    text = json.dumps(build_prompt(d, scores, base))
    assert "values" not in text


def test_a_model_failure_falls_back_to_a_written_summary():
    d, base, scores = parts()

    def boom(**kwargs):
        raise RuntimeError("no model configured")

    out = write_analysis(d, scores, base, {}, call=boom)
    assert out
    assert "Health" in out or "Sleep" in out
    assert out.endswith(".")


def test_a_models_reply_is_used_as_written():
    d, base, scores = parts()

    def reply(**kwargs):
        return "HRV ran high and sleep came up short."

    assert write_analysis(d, scores, base, {}, call=reply) == "HRV ran high and sleep came up short."


def test_the_chosen_model_is_passed_through():
    d, base, scores = parts()
    seen = {}

    def capture(**kwargs):
        seen.update(kwargs)
        return "ok."

    write_analysis(d, scores, base, {"model": "claude-opus-5", "provider": "anthropic"}, call=capture)
    assert seen["model"] == "claude-opus-5"
    assert seen["provider"] == "anthropic"
