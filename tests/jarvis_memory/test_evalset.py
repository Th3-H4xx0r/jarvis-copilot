"""The personal eval: real misses mined from chat history, replayed old vs new."""
import json
import sqlite3

from plugins.memory.jarvis_memory import evalset
from plugins.memory.jarvis_memory.store import GLOBAL_NS

from tests.jarvis_memory.conftest_map import CT, NOW, build_venue_store


def _state_db(path, rows):
    db = sqlite3.connect(path)
    db.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, role TEXT, "
               "content TEXT, tool_call_id TEXT, tool_calls TEXT, tool_name TEXT, timestamp REAL)")
    for r in rows:
        db.execute("INSERT INTO messages(session_id, role, content, tool_calls, tool_name, timestamp) "
                   "VALUES (?,?,?,?,?,?)", r)
    db.commit()
    db.close()


def test_mines_recall_after_weak_first_answer(tmp_path):
    recall = json.dumps({"ok": True, "results": [
        {"id": "c_f1", "body": "Pranav is going to the F1 race at COTA in Austin"},
        {"id": "c_grad", "body": "Arnav suggested parking near the graduation venue"}]})
    _state_db(tmp_path / "state.db", [
        ("s1", "user", "Can you open navigation to the venue", None, None, NOW.timestamp()),
        ("s1", "assistant", "I can't tell which venue you mean.", None, None, NOW.timestamp() + 5),
        ("s1", "user", "Can you open to the venue for the race", None, None, NOW.timestamp() + 20),
        ("s1", "assistant", "", json.dumps([{"function": {"name": "memory_recall"}}]), None, NOW.timestamp() + 21),
        ("s1", "tool", recall, None, "memory_recall", NOW.timestamp() + 22),
        ("s1", "assistant", "The race is the F1 US Grand Prix at COTA in Austin; directions are open.",
         None, None, NOW.timestamp() + 25),
        ("s2", "user", "what's the weather", None, None, NOW.timestamp()),
        ("s2", "assistant", "Sunny.", None, None, NOW.timestamp() + 2),
    ])
    cases = evalset.mine_cases(tmp_path / "state.db", since=NOW.timestamp() - 86400)
    assert len(cases) == 1
    c = cases[0]
    assert c.question == "Can you open navigation to the venue" and c.as_of == NOW.timestamp()
    assert c.gold_ids == ["c_f1"]  # what the final answer actually used


def test_replay_legacy_misses_v2_hits_venue(tmp_path):
    s, e, ids = build_venue_store(tmp_path)
    case = evalset.Case(id="venue", as_of=NOW.timestamp(), question="Can you open navigation to the venue",
                        prior_turns=[], gold_ids=[ids["f1_trip"], ids["f1_held"]], category="implicit")
    legacy = evalset.replay(s, e, [case], mode="legacy", zone=CT, namespace=GLOBAL_NS)
    v2 = evalset.replay(s, e, [case], mode="v2", zone=CT, namespace=GLOBAL_NS)
    assert legacy["recall5_combined"] == 0.0
    assert v2["recall5_combined"] == 1.0 and v2["recall5_brief"] == 1.0
    assert v2["per_case"][0]["id"] == "venue" and v2["p95_ms"] >= 0


def test_replay_ignores_memories_from_after_the_question(tmp_path):
    s, e, ids = build_venue_store(tmp_path)
    case = evalset.Case(id="early", as_of=NOW.timestamp() - 30 * 86400, question="where is the race",
                        prior_turns=[], gold_ids=[ids["f1_trip"]], category="implicit")
    assert evalset.replay(s, e, [case], mode="v2", zone=CT, namespace=GLOBAL_NS)["recall5_retrieval"] == 0.0


def test_cases_round_trip(tmp_path):
    case = evalset.Case(id="x", as_of=1.0, question="q", prior_turns=[{"role": "user", "content": "p"}],
                        gold_ids=["a"], category="implicit")
    evalset.save_cases(tmp_path / "cases.jsonl", [case])
    assert evalset.load_cases(tmp_path / "cases.jsonl") == [case]
