"""Recall must not sit on the embedder: cached / prewarmed vectors, no embed for small talk."""
import threading

import pytest

from plugins.memory.jarvis_memory import embed as embed_mod
from plugins.memory.jarvis_memory.embed import FakeEmbedder
from plugins.memory.jarvis_memory.entities import EntityIndex
from plugins.memory.jarvis_memory.recall import RecallQuery, recall
from plugins.memory.jarvis_memory.store import GLOBAL_NS
from plugins.memory.jarvis_memory.textq import is_small_talk, strip_injected

from tests.jarvis_memory.conftest_map import CT, NOW, ContentEmbedder, build_venue_store


@pytest.fixture(autouse=True)
def _fresh_cache():
    embed_mod.clear_cache()
    yield
    embed_mod.clear_cache()


class Counting(FakeEmbedder):
    def __init__(self, dim=64, fail_once=False, gate=None):
        super().__init__(dim)
        self.calls = []
        self._fail_once = fail_once
        self._gate = gate

    def embed(self, texts):
        self.calls.append(list(texts))
        if self._gate is not None:
            self._gate.wait(2)
        if self._fail_once:
            self._fail_once = False
            raise RuntimeError("ollama down")
        return super().embed(texts)


def test_embed_cached_reuses_vectors():
    e = Counting()
    a = e.embed_cached(["parking at cota"])
    b = e.embed_cached(["parking at cota"])
    assert a == b and e.calls == [["parking at cota"]]


def test_embed_cached_batches_only_the_misses():
    e = Counting()
    e.embed_cached(["one", "two"])
    e.embed_cached(["two", "three"])
    assert e.calls == [["one", "two"], ["three"]]


def test_prewarm_then_cached_waits_for_the_same_request():
    gate = threading.Event()
    e = Counting(gate=gate)
    e.prewarm("where is the venue")
    assert _wait_for(lambda: len(e.calls) == 1)  # the prewarm request is in flight
    threading.Timer(0.05, gate.set).start()
    vec = e.embed_cached(["where is the venue"])[0]
    assert len(vec) == 64 and e.calls == [["where is the venue"]]


def test_failed_embed_is_not_cached():
    e = Counting(fail_once=True)
    with pytest.raises(RuntimeError):
        e.embed_cached(["x y"])
    assert e.embed_cached(["x y"])
    assert len(e.calls) == 2


@pytest.mark.parametrize("text", ["Hello", "Yooo", "What's up", "What’s up", "thanks!",
                                  "Good morning Jarvis", "hey how are you", "ok cool", "lol"])
def test_small_talk(text):
    assert is_small_talk(text)


@pytest.mark.parametrize("text", ["What's up with Sreeja", "hello where is the venue",
                                  "Remind me at 2:45", "Open directions to the venue", "Who is my dog", "",
                                  "Who is he?", "Where is it?", "What about her?", "Is she there?",
                                  "How is he doing", "Tell me more", "Open it", "yes do it", "Is it at 5?"])
def test_not_small_talk(text):
    assert not is_small_talk(text)


def test_workspace_tag_is_not_his_words():
    assert strip_injected("[Workspace::v1: /root/workspace] Hello") == "Hello"
    assert strip_injected("[Workspace::v1: /root/workspace]\nwhere is the venue") == "where is the venue"
    assert strip_injected("[Workspace::v1: /root/ws]\nI'm going to F1 [COTA]\n\nwhat about parking") \
        == "I'm going to F1 [COTA]\n\nwhat about parking"


class CountingContent(ContentEmbedder):
    def __init__(self, dim=128):
        super().__init__(dim)
        self.calls = []

    def embed(self, texts):
        self.calls.append(list(texts))
        return super().embed(texts)


def _recall(s, e, text, prior=""):
    q = RecallQuery(text=text, context=prior, prior=prior, now=NOW.timestamp(), zone=CT)
    return recall(s, e, q, entity_index=EntityIndex(s, GLOBAL_NS), namespace=GLOBAL_NS)


def _provider(tmp_path):
    from plugins.memory.jarvis_memory import JarvisMemoryProvider
    p = JarvisMemoryProvider()
    p.initialize("sess-1", hermes_home=str(tmp_path), platform="cli",
                 _config_override={"embedder": "fake", "embed_dim": 128, "extract": "off",
                                   "proactive": "off", "migrate_builtin": False})
    p._embedder = CountingContent()
    return p


def test_small_talk_turn_skips_the_embedder_and_injects_nothing(tmp_path):
    p = _provider(tmp_path)
    assert p.handle_tool_call("memory_store", {"content": "Pranav is going to the F1 race at COTA"})
    p._embedder.calls.clear()
    block = p.prefetch("Yooo")
    assert p._embedder.calls == [] and "COTA" not in block
    p.shutdown()


def test_recall_itself_still_searches_greeting_words(tmp_path):
    # memory_recall(query="morning", when="yesterday") is a real search; only the
    # per-turn injection skips small talk.
    s, _, _ = build_venue_store(tmp_path)
    e = CountingContent()
    _recall(s, e, "good morning")
    assert e.calls == [["good morning"]]


def test_prior_is_last_turns_query_not_the_voice_rules(tmp_path):
    p = _provider(tmp_path)
    rules = "[Voice mode — your reply is read aloud. " + "Keep it short. " * 150 + "]\n\n"
    p.on_turn_start(1, rules + "I'm going to the Grand Prix at COTA")
    p.prefetch(rules + "I'm going to the Grand Prix at COTA")
    p.on_turn_start(2, rules + "how much is parking there", recent_messages=[
        {"role": "user", "content": (rules + "I'm going to the Grand Prix at COTA")[:2000]},
        {"role": "assistant", "content": "Have fun!"}])
    p._embedder.calls.clear()
    p.prefetch(rules + "how much is parking there")
    assert p._embedder.calls == [["how much is parking there"]]
    p.shutdown()


def test_uncached_prior_never_holds_up_the_message(tmp_path):
    s, _, ids = build_venue_store(tmp_path)
    e = CountingContent()
    res = _recall(s, e, "how much is parking at COTA", prior="something never embedded before")
    assert e.calls == [["how much is parking at COTA"]]
    assert ids["f1_parking"] in [h.chunk.id for h in res.hits[:3]]


def test_prior_message_vector_comes_from_cache(tmp_path):
    s, _, ids = build_venue_store(tmp_path)
    e = CountingContent()
    _recall(s, e, "I'm going to the Grand Prix at COTA")
    e.calls.clear()
    res = _recall(s, e, "how much is parking there", prior="I'm going to the Grand Prix at COTA")
    assert e.calls == [["how much is parking there"]]
    assert res.hits[0].chunk.id == ids["f1_parking"]


def _wait_for(pred, timeout=2.0):
    import time
    end = time.time() + timeout
    while time.time() < end and not pred():
        time.sleep(0.01)
    return pred()


def test_warm_query_embeds_his_words_as_the_message_arrives(monkeypatch):
    from plugins.memory.jarvis_memory import external
    e = Counting()
    monkeypatch.setattr(external, "is_active", lambda: True)
    monkeypatch.setattr(external, "_open", lambda home=None: (None, e, GLOBAL_NS, 0.92))
    external.warm_query("[Workspace::v1: /root/workspace] where is the venue")
    assert _wait_for(lambda: e.calls == [["where is the venue"]])
    e.embed_cached(["where is the venue"])
    assert len(e.calls) == 1


def test_warm_query_skips_small_talk_and_inactive_memory(monkeypatch):
    import time
    from plugins.memory.jarvis_memory import external
    e = Counting()
    monkeypatch.setattr(external, "_open", lambda home=None: (None, e, GLOBAL_NS, 0.92))
    monkeypatch.setattr(external, "is_active", lambda: True)
    external.warm_query("Yooo")
    monkeypatch.setattr(external, "is_active", lambda: False)
    external.warm_query("where is the venue")
    time.sleep(0.2)
    assert e.calls == []


def test_small_talk_prior_adds_nothing_to_embed(tmp_path):
    s, _, _ = build_venue_store(tmp_path)
    e = CountingContent()
    _recall(s, e, "where is the race", prior="What's up")
    assert e.calls == [["where is the race"]]
