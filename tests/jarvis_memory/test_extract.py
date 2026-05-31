from plugins.memory.jarvis_memory import JarvisMemoryProvider
from plugins.memory.jarvis_memory.extract import (
    FakeExtractor,
    OllamaFactExtractor,
    _parse_facts,
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


def test_extraction_failure_falls_back_to_raw_capture(tmp_path):
    p = _prov(tmp_path, FakeExtractor(raises=True))
    p.sync_turn("the watch app deploys via deploy_both.sh from mobile_client", "ok")
    p._flush()
    assert p._store.count_chunks(p._namespace) == 1   # raw user turn captured as fallback
    assert "deploy_both.sh" in p._store.recent_chunks(p._namespace, 5)[0].body
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
