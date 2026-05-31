from plugins.memory.jarvis_memory import JarvisMemoryProvider
from plugins.memory.jarvis_memory.extract import (
    FakeExtractor,
    OllamaFactExtractor,
    _parse_facts,
    is_transient_fact,
    make_extractor,
)


def test_parse_facts_from_messy_content():
    assert _parse_facts('Here you go: ["a fact", "another"] done') == ["a fact", "another"]
    assert _parse_facts("[]") == []
    assert _parse_facts("no json at all") == []
    big = "[" + ",".join('"f%d"' % i for i in range(10)) + "]"
    assert len(_parse_facts(big)) == 4  # capped at MAX_FACTS


def test_make_extractor_defaults():
    assert make_extractor({"embedder": "fake"}) is None          # off unless ollama
    assert isinstance(make_extractor({"embedder": "ollama"}), OllamaFactExtractor)
    assert make_extractor({"embedder": "ollama", "extract": "off"}) is None


def _prov(tmp_path, extractor, **over):
    p = JarvisMemoryProvider()
    cfg = {"embedder": "fake", "embed_dim": 64}
    cfg.update(over)
    p.initialize("s", hermes_home=str(tmp_path), platform="cli", _config_override=cfg)
    p._extractor = extractor  # inject (fake embedder => extractor defaults to None)
    return p


def test_extraction_stores_clean_distilled_fact(tmp_path):
    p = _prov(tmp_path, FakeExtractor(
        facts=["Pranav's home address is 498 E Marcello Ave, Mountain House, CA 95391"]))
    p.sync_turn("hello I live at 498 E Marcello Ave, Mountain House, CA 95391 USA",
                "Got it — your address is 498 E Marcello Ave.")
    p._flush()
    assert p._store.count_chunks(p._namespace) == 1   # one clean fact, not the raw turn
    body = p._store.recent_chunks(p._namespace, 5)[0].body
    assert "home address" in body and "Marcello" in body
    p.shutdown()


def test_extraction_empty_stores_nothing(tmp_path):
    p = _prov(tmp_path, FakeExtractor(facts=[]))   # nothing worth remembering
    p.sync_turn("hi", "Hi Pranav! How can I help?")
    p._flush()
    assert p._store.count_chunks(p._namespace) == 0
    p.shutdown()


def test_extraction_failure_skips_by_default(tmp_path):
    # Default: a failed extraction must NOT dump the raw user turn into memory.
    p = _prov(tmp_path, FakeExtractor(raises=True))
    p.sync_turn("the watch app deploys via deploy_both.sh from mobile_client", "ok")
    p._flush()
    assert p._store.count_chunks(p._namespace) == 0   # no raw chat stored
    p.shutdown()


def test_extraction_failure_raw_capture_when_configured(tmp_path):
    p = _prov(tmp_path, FakeExtractor(raises=True), extract_fallback_raw=True)
    p.sync_turn("the watch app deploys via deploy_both.sh from mobile_client", "ok")
    p._flush()
    assert p._store.count_chunks(p._namespace) == 1
    assert "deploy_both.sh" in p._store.recent_chunks(p._namespace, 5)[0].body
    p.shutdown()


def test_on_memory_write_mirrors_builtin_into_store(tmp_path):
    p = _prov(tmp_path, None)  # extractor irrelevant for this hook
    p.on_memory_write("add", "memory",
                      "When deploying the watch app, run deploy_both.sh from mobile_client",
                      metadata={"write_origin": "retrospective"})
    assert p._store.count_chunks(p._namespace) == 1
    assert "deploy_both" in p._store.recent_chunks(p._namespace, 5)[0].body
    p.on_memory_write("remove", "memory", "anything")  # ignored
    assert p._store.count_chunks(p._namespace) == 1
    p.shutdown()


def test_is_transient_fact():
    assert is_transient_fact("http://127.0.0.1:8765/healthz are reachable")
    assert is_transient_fact("On Telegram")
    assert is_transient_fact("The rating server stopped listening on port 8765")
    assert is_transient_fact("")
    assert not is_transient_fact("Pranav prefers a small set of 5-6 Spotify playlists")
    assert not is_transient_fact("Pranav lives in Mountain House, California")


def test_extraction_is_user_only_by_default(tmp_path):
    fe = FakeExtractor(facts=["Pranav prefers dark mode"])
    p = _prov(tmp_path, fe)  # capture_roles defaults to user-only
    p.sync_turn("I like dark mode", "Done — the server is now running on port 8765.")
    p._flush()
    # The assistant's transient narration must NOT be fed to the extractor.
    assert fe.calls[-1] == ("I like dark mode", "")
    p.shutdown()


def test_extraction_sees_assistant_when_configured(tmp_path):
    fe = FakeExtractor(facts=["some durable fact here"])
    p = _prov(tmp_path, fe, capture_roles=["user", "assistant"])
    p.sync_turn("hi there friend", "some assistant content here")
    p._flush()
    assert fe.calls[-1] == ("hi there friend", "some assistant content here")
    p.shutdown()


def test_store_facts_drops_transient_junk(tmp_path):
    fe = FakeExtractor(facts=[
        "http://127.0.0.1:8765/healthz is reachable",
        "On Telegram",
        "The rating server stopped listening on port 8765",
        "Pranav prefers a small set of 5-6 Spotify playlists",
    ])
    p = _prov(tmp_path, fe)
    p.sync_turn("set up my spotify automation the way I like it", "ok")
    p._flush()
    bodies = [c.body for c in p._store.recent_chunks(p._namespace, 10)]
    assert any("5-6 Spotify" in b for b in bodies)        # durable fact kept
    assert not any("healthz" in b for b in bodies)        # endpoint dropped
    assert not any(b == "On Telegram" for b in bodies)    # fragment dropped
    assert not any("stopped listening" in b for b in bodies)  # transient status dropped
    p.shutdown()


def test_migrate_builtin_memory(tmp_path):
    mem_dir = tmp_path / "memories"
    mem_dir.mkdir()
    (mem_dir / "MEMORY.md").write_text("First lesson prefer X\n§\nSecond note env uses Y")
    (mem_dir / "USER.md").write_text("Pranav prefers vim and dark mode")
    p = _prov(tmp_path, None, migrate_builtin=False)  # don't race the bg submit
    p._migrate_safe(str(tmp_path))
    assert p._store.count_chunks(p._namespace) == 3  # 2 from MEMORY.md + 1 from USER.md
    assert p._store.kv_get("__migrate__", "builtin_done") == "1"
    p._migrate_safe(str(tmp_path))  # idempotent — flag short-circuits
    assert p._store.count_chunks(p._namespace) == 3
    p.shutdown()


def test_extraction_dedup_skips_near_duplicate(tmp_path):
    # Force the dedup branch: any prior vector counts as a duplicate.
    p = _prov(tmp_path, FakeExtractor(facts=["fact one about alpha project"]), dedup_threshold=-1.0)
    p.sync_turn("alpha", "ok")
    p._flush()
    p._extractor = FakeExtractor(facts=["a totally different beta fact"])
    p.sync_turn("beta", "ok")
    p._flush()
    assert p._store.count_chunks(p._namespace) == 1   # second fact deduped
    p.shutdown()
