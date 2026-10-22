"""Auto-injection recalls for the CURRENT message, with recent turns as context."""
import json

from plugins.memory.jarvis_memory import JarvisMemoryProvider


def _provider(tmp_path):
    p = JarvisMemoryProvider()
    p.initialize("sess-1", hermes_home=str(tmp_path), platform="cli",
                 _config_override={"embedder": "fake", "embed_dim": 128, "extract": "off",
                                   "proactive": "off", "migrate_builtin": False})
    return p


def _store(p, text):
    assert json.loads(p.handle_tool_call("memory_store", {"content": text}))["ok"]


def test_first_turn_of_new_provider_injects_current_recall(tmp_path):
    p = _provider(tmp_path)
    _store(p, "Pranav is going to the F1 race at COTA in Austin this weekend")
    p.shutdown()
    fresh = _provider(tmp_path)  # agent rebuilt: nothing warmed, no history
    fresh.on_turn_start(1, "where is the race")
    assert "COTA" in fresh.prefetch("where is the race")
    fresh.shutdown()


def test_prefetch_uses_current_not_previous_message(tmp_path):
    p = _provider(tmp_path)
    _store(p, "his favorite lunch is a burrito from the taqueria")
    _store(p, "the watch app deploys via deploy_both.sh")
    p.queue_prefetch("favorite lunch")  # the old path warmed on the previous turn
    p._flush()
    block = p.prefetch("how do I deploy the watch app")
    assert "deploy_both.sh" in block and "burrito" not in block
    assert "burrito" in p.prefetch("what is my favorite lunch")
    p.shutdown()


def test_context_from_recent_messages_resolves_followup(tmp_path):
    p = _provider(tmp_path)
    _store(p, "Parking near COTA is about $50 a day")
    _store(p, "The office garage parking costs $12 a day")
    p.on_turn_start(2, "how much is parking there", recent_messages=[
        {"role": "user", "content": "I'm going to the F1 race at COTA on Saturday"},
        {"role": "assistant", "content": "Have fun at COTA!"},
    ])
    block = p.prefetch("how much is parking there")
    lines = [l for l in block.splitlines() if l.startswith("- ")]
    assert "COTA" in lines[0]
    p.shutdown()


def test_trace_row_written(tmp_path):
    p = _provider(tmp_path)
    _store(p, "the watch app deploys via deploy_both.sh")
    p.prefetch("deploy the watch app", session_id="sess-1")
    [trace] = p._store.recent_traces(1)
    assert trace["query"] == "deploy the watch app"
    assert "deploy_both.sh" in trace["injected"]
    assert trace["trace"]["ms"] >= 0
    p.shutdown()


def test_recent_messages_for_memory_shapes_history():
    from agent.conversation_loop import _recent_messages_for_memory
    msgs = [{"role": "system", "content": "sys"}]
    msgs += [{"role": "user", "content": f"u{i}"} for i in range(5)]
    msgs += [{"role": "assistant", "content": [{"type": "text", "text": "a-parts"}]},
             {"role": "tool", "content": "tool output"},
             {"role": "user", "content": "current " + "x" * 5000}]
    got = _recent_messages_for_memory(msgs)
    assert got[-1] == {"role": "assistant", "content": "a-parts"}
    assert all(m["role"] in ("user", "assistant") for m in got)
    assert len(got) == 6 and all(len(m["content"]) <= 2000 for m in got)
    assert "current" not in " ".join(m["content"] for m in got)


VOICE = ("[Voice mode — a small fast model's reply, read aloud by text-to-speech. Follow these rules exactly:\n"
         "1. Plain spoken language only — speak each part's result (date, weather, calendar, news) today.\n"
         "Answer with only the actual content — nothing else.]\n\n")


def test_injected_rules_block_is_not_part_of_the_query(tmp_path):
    from plugins.memory.jarvis_memory.textq import strip_injected
    assert strip_injected(VOICE + "where is the race") == "where is the race"
    assert strip_injected("[a note] about brackets in my own words") == "[a note] about brackets in my own words"
    p = _provider(tmp_path)
    _store(p, "Pranav is going to the F1 race at COTA in Austin this weekend")
    out = p.prefetch(VOICE + "where is the race")
    assert "COTA" in out
    [trace] = p._store.recent_traces(1)
    assert trace["query"] == "where is the race"
    p.shutdown()


def test_rules_block_with_inner_brackets_is_stripped():
    from plugins.memory.jarvis_memory.textq import strip_injected
    board = ('[JarvisWearables board programming. Board: "Jarvis-ESP32-33DA". Current script: - [no script]. '
             'Keep replies short.]\n\nflash pin 4 every second')
    assert strip_injected(board) == "flash pin 4 every second"
