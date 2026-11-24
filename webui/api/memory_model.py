"""Every memory model call, guarded: a model at its usage limit is benched until it resets.

Live 2026-11-22..24: the memory model (a ChatGPT Plus model) hit its weekly limit. iMessage threw ~40 conversations
away, chat turns lost their memories and the map pass made ~11,000 failed calls in two days. Now:

- a usage / rate limit benches that model until the reset time it gives (else LIMIT_BENCH_S); any other failure
  benches it for ERROR_BENCH_S
- while benched, his backup model (Long-term Memory → "While it's at its limit, use") takes the call; with none
  set, the call fails at once with ModelPaused (no network) and callers keep their work for later
- ``paused()`` says what's happening for the Long-term Memory page and the iMessage card
"""
from __future__ import annotations

import logging
import re
import threading
import time
from typing import Optional

logger = logging.getLogger(__name__)

LIMIT_BENCH_S = 900.0   # a limit that names no reset time
ERROR_BENCH_S = 120.0   # any other failure (a 5xx, a timeout, a bad key)
_LIMIT = re.compile(r"\b429\b|usage[_ ]limit|rate[_ ]?limit|too many requests|quota|overloaded", re.I)
_RESETS_IN = re.compile(r"resets_in_seconds['\"]?\s*[:=]\s*(\d+)")
_RESETS_AT = re.compile(r"resets_at['\"]?\s*[:=]\s*(\d{9,})")

_lock = threading.Lock()
_bench: dict = {}   # model ref → {"until", "reason", "label"}


def _now() -> float:
    return time.time()


class ModelPaused(RuntimeError):
    """The memory model can't be used right now (and no backup can): try again after ``until``."""

    memory_paused = True   # plugins check this attribute, not the class (they don't import the web server)

    def __init__(self, reason: str, until: Optional[float] = None, model: str = ""):
        self.reason, self.until, self.model = reason, until, model
        when = time.strftime("%H:%M", time.localtime(until)) if until else "later"
        super().__init__(f"memory model {model or ''} {'at its usage limit' if reason == 'limit' else 'failing'}; "
                         f"retrying after {when}".replace("  ", " "))


def reset_for_tests() -> None:
    with _lock:
        _bench.clear()


def _one_shot(ref: str, prompt: str, max_tokens: int, thinking: bool) -> str:
    from api.imessage_memory_writer import _one_shot as shot
    return shot(ref, prompt, max_tokens, thinking=thinking)


def _resolve(agent):
    from api.imessage_memory_writer import resolve_extraction_model
    return resolve_extraction_model(agent)


def _models() -> list:
    """[(ref, label)] — his memory model, then his backup (when set and different)."""
    from api import memory_map
    out = []
    ref, label = _resolve(memory_map.get_agent())
    if ref:
        out.append((ref, label))
    backup = memory_map.get_backup()
    if backup is not None:
        bref, blabel = _resolve(backup)
        if bref and bref != ref:
            out.append((bref, blabel))
    return out


def _bench_for(exc: Exception) -> tuple:
    """(reason, until) for a failed call."""
    text = str(exc)
    status = getattr(exc, "status_code", None) or getattr(getattr(exc, "response", None), "status_code", None)
    now = _now()
    if status == 429 or _LIMIT.search(text):
        m = _RESETS_IN.search(text)
        if m:
            return "limit", now + int(m.group(1))
        m = _RESETS_AT.search(text)
        if m and int(m.group(1)) > now:
            return "limit", float(m.group(1))
        try:
            after = float(getattr(getattr(exc, "response", None), "headers", {}).get("retry-after"))
            return "limit", now + after
        except (TypeError, ValueError):
            pass
        return "limit", now + LIMIT_BENCH_S
    return "error", now + ERROR_BENCH_S


def _benched(ref: str) -> Optional[dict]:
    with _lock:
        entry = _bench.get(ref)
        if entry and entry["until"] <= _now():
            _bench.pop(ref, None)
            entry = None
        return dict(entry) if entry else None


def call(prompt: str, max_tokens: int = 1500, thinking: bool = False) -> str:
    """One memory model call: his memory model, else his backup while it's benched. Raises ModelPaused when neither
    can be used now; RuntimeError when no memory model is set."""
    models = _models()
    if not models:
        raise RuntimeError("no memory model set")
    soonest = None
    for ref, label in models:
        bench = _benched(ref)
        if bench is None:
            try:
                return _one_shot(ref, prompt, max_tokens, thinking)
            except Exception as exc:  # noqa: BLE001 — every failure benches; the next model may answer
                reason, until = _bench_for(exc)
                with _lock:
                    _bench[ref] = {"until": until, "reason": reason, "label": label}
                logger.warning("memory model %s %s; benched until %s (%s)", label,
                               "is at its usage limit" if reason == "limit" else "failed",
                               time.strftime("%Y-%m-%d %H:%M", time.localtime(until)), str(exc)[:160])
                bench = {"until": until, "reason": reason, "label": label}
        if soonest is None or bench["until"] < soonest["until"]:
            soonest = bench
    raise ModelPaused(soonest["reason"], soonest["until"], soonest["label"])


def paused() -> Optional[dict]:
    """None while his memory model is usable; else what's happening: {model, until, reason, using, backup}."""
    try:
        models = _models()
    except Exception:  # noqa: BLE001
        return None
    if not models:
        return None
    bench = _benched(models[0][0])
    if bench is None:
        return None
    backup = models[1] if len(models) > 1 else None
    covering = backup is not None and _benched(backup[0]) is None
    return {"model": models[0][1], "until": bench["until"], "reason": bench["reason"],
            "using": "backup" if covering else "waiting", "backup": backup[1] if backup else ""}
