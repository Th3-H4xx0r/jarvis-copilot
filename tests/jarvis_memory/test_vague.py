"""Vague references ("the venue", "text him") resolved only when nothing else did."""
import json
import time

from plugins.memory.jarvis_memory import vague
from plugins.memory.jarvis_memory.recall import Hit
from plugins.memory.jarvis_memory.store import Chunk


def _hit(body, slots=""):
    return Hit(chunk=Chunk(id="c1", namespace="global", body=body, source="x", created_at=0.0,
                           score=1.0, slots=slots), score=1.0)


def test_venue_needs_resolution_when_nothing_names_it():
    assert vague.needs_resolution("Can you open navigation to the venue", "", "", []) == "the venue"


def test_not_triggered_when_a_hit_fills_the_role():
    hits = [_hit("Pranav is going to the F1 race", slots="venue: Circuit of the Americas")]
    assert vague.needs_resolution("open navigation to the venue", "", "", hits) is None


def test_not_triggered_when_the_noun_is_in_context_or_brief():
    assert vague.needs_resolution("where's the race", "", "going to the F1 race Saturday", []) is None
    assert vague.needs_resolution("where's the race", "- Sat: F1 race @ COTA", "", []) is None


def test_pronoun_with_send_verb_needs_context():
    assert vague.needs_resolution("text him that I'm late", "", "", []) == "him"
    assert vague.needs_resolution("text him that I'm late", "", "talking about Sid Patel", []) is None


def test_plain_questions_never_trigger():
    for text in ("what's the weather", "set a timer for 5 minutes", "who won the game last night?"):
        assert vague.needs_resolution(text, "", "", []) in (None, "the game")
    assert vague.needs_resolution("what's the weather", "", "", []) is None


def test_resolve_confident():
    reply = json.dumps({"referent": "Circuit of the Americas (F1 race)", "confident": True,
                        "alternatives": [], "memory_ids": ["c1"]})
    res = vague.resolve("the venue", "open navigation to the venue", "", "", [_hit("F1 at COTA")],
                        complete=lambda p, n: reply)
    assert res.confident and res.referent.startswith("Circuit") and res.memory_ids == ["c1"]
    assert "[Likely meaning]" in vague.note("the venue", res)


def test_unconfident_yields_ask_line():
    reply = json.dumps({"referent": "", "confident": False,
                        "alternatives": ["COTA (F1 race)", "Toyota Center (concert)"], "memory_ids": []})
    res = vague.resolve("the venue", "open navigation to the venue", "", "", [],
                        complete=lambda p, n: reply)
    line = vague.note("the venue", res)
    assert line.startswith("[Unclear]") and "COTA (F1 race)" in line and "either/or" in line


def test_timeout_returns_none_within_budget():
    def slow(p, n):
        time.sleep(3)
        return "{}"
    t0 = time.perf_counter()
    assert vague.resolve("the venue", "x", "", "", [], complete=slow, timeout_s=0.2) is None
    assert time.perf_counter() - t0 < 0.6


def test_prefetch_adds_likely_meaning(tmp_path):
    from plugins.memory.jarvis_memory import JarvisMemoryProvider, llm
    p = JarvisMemoryProvider()
    p.initialize("s", hermes_home=str(tmp_path), platform="cli",
                 _config_override={"embedder": "fake", "embed_dim": 64, "extract": "off",
                                   "proactive": "off", "migrate_builtin": False})
    cid = json.loads(p.handle_tool_call("memory_store",
                                        {"content": "Pranav is going to the F1 race at COTA"}))["id"]
    llm.set_completer(lambda prompt, n: json.dumps(
        {"referent": "Circuit of the Americas (F1 race)", "confident": True,
         "alternatives": [], "memory_ids": [cid]}))
    try:
        out = p.prefetch("can you open navigation to the venue")
    finally:
        llm.set_completer(None)
        p.shutdown()
    assert '[Likely meaning] "the venue" = Circuit of the Americas (F1 race)' in out
    assert "F1 race at COTA" in out
