"""The written part: two or three sentences over numbers already computed.

The model is given the scores, their contributions and the baseline deltas —
never the raw series, and never the job of deciding a number. Research on LLM
anomaly detection over wearable data finds those judgements unstable, so the
only thing generated here is prose.
"""
from __future__ import annotations

import json
from typing import Callable, Optional

from .metrics import Baseline, HealthDay

PROMPT_RULES = """You write two or three plain sentences about someone's day of wearable data.

Rules:
- Use only the numbers given to you. Do not invent, estimate or recompute any figure.
- Cite the two or three figures that most explain the scores, with their units.
- Say what stood out and what held the score down. No advice, no diagnosis, no
  medical claims, no suggestions to see a doctor.
- No greeting, no sign-off, no lists, no markdown. Plain sentences.
"""


def _payload(day: HealthDay, scores: dict, baseline: Baseline) -> dict:
    out: dict = {
        "date": day.date,
        "scores": {name: score.to_json() for name, score in scores.items()},
        "contributions": {
            name: [
                {"name": c.name, "earned": round(c.earned, 1), "possible": c.possible, "detail": c.detail}
                for c in score.points
            ]
            for name, score in scores.items()
            if name != "health" and score.points
        },
        "baseline": {
            "hrv": baseline.hrv,
            "resting_hr": baseline.resting_hr,
            "sleep_minutes": baseline.sleep_minutes,
            "days_used": baseline.days_used,
        },
    }

    night = day.main_sleep
    if night:
        out["sleep"] = {
            "asleep_minutes": night.asleep_minutes,
            "efficiency_percent": round(night.efficiency * 100),
            "awakenings": night.awakenings,
        }
    if day.hrv and day.hrv.nonzero():
        hrv = sum(day.hrv.nonzero()) / len(day.hrv.nonzero())
        out["hrv_ms"] = round(hrv)
        if baseline.hrv:
            out["hrv_vs_baseline_percent"] = round((hrv - baseline.hrv) / baseline.hrv * 100)
    if day.activity:
        out["activity"] = {k: v for k, v in day.activity.items() if isinstance(v, (int, float))}
    return out


def build_prompt(day: HealthDay, scores: dict, baseline: Baseline) -> list[dict]:
    return [
        {"role": "system", "content": PROMPT_RULES},
        {"role": "user", "content": json.dumps(_payload(day, scores, baseline), separators=(",", ":"))},
    ]


def fallback_analysis(day: HealthDay, scores: dict) -> str:
    """What to say when no model answered: the same facts, plainly."""
    parts = []
    health = scores.get("health")
    if health is not None and health.value is not None:
        parts.append(f"Health {round(health.value)}")
    for name in ("sleep", "recovery", "body", "activity"):
        score = scores.get(name)
        if score is not None and score.value is not None:
            parts.append(f"{name.title()} {round(score.value)}")
    headline = ", ".join(parts) if parts else "No scores could be computed for this day"

    worst = None
    for name, score in scores.items():
        if name == "health":
            continue
        for contribution in score.points:
            lost = contribution.possible - contribution.earned
            if lost > 0 and (worst is None or lost > worst[0]):
                worst = (lost, contribution)
    if worst:
        contribution = worst[1]
        return f"{headline}. {contribution.name} cost the most, at {contribution.detail or 'below target'}."
    return f"{headline}."


def write_analysis(
    day: HealthDay,
    scores: dict,
    baseline: Baseline,
    settings: dict,
    call: Optional[Callable[..., object]] = None,
) -> str:
    """Prose for this day. Never raises: a missing model falls back to facts."""
    if call is None:
        from agent.auxiliary_client import call_llm

        call = call_llm

    kwargs = {
        "messages": build_prompt(day, scores, baseline),
        "max_tokens": 220,
        "temperature": 0.3,
    }
    if (settings or {}).get("model"):
        kwargs["model"] = settings["model"]
    if (settings or {}).get("provider"):
        kwargs["provider"] = settings["provider"]

    try:
        reply = call(**kwargs)
    except Exception:
        return fallback_analysis(day, scores)

    text = _text_of(reply)
    return text or fallback_analysis(day, scores)


def _text_of(reply: object) -> str:
    if isinstance(reply, str):
        return reply.strip()
    try:
        from agent.auxiliary_client import extract_content_or_reasoning

        return (extract_content_or_reasoning(reply) or "").strip()
    except Exception:
        return ""
