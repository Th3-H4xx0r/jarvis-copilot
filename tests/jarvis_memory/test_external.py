"""The way Live writes into the same long-term memory chat and voice recall from."""
import pytest

from plugins.memory.jarvis_memory import external


@pytest.fixture
def home(tmp_path, monkeypatch):
    monkeypatch.setattr(external, "_handles", {})
    monkeypatch.setattr(external, "load_config", lambda _home: {
        "embedder": "fake", "embed_dim": 64, "namespace": "global", "dedup_threshold": 0.92,
        "db_path": str(tmp_path / "memory.db"), "vault_dir": str(tmp_path / "vault")})
    return str(tmp_path)


def _rows(home):
    store = external._open(home)[0]
    return [dict(r) for r in store._conn.execute(
        "SELECT source, tags, created_at, body FROM chunks ORDER BY rowid")]


def test_a_memory_keeps_its_source_tags_and_when_it_happened(home):
    cid = external.remember("Brenda said the lesson is on Friday.", source="live:s1:4-9",
                            tags="live,conversation,speaker:v1", created_at=1790112660.0,
                            hermes_home=home)
    assert cid
    (row,) = _rows(home)
    assert row["source"] == "live:s1:4-9" and row["tags"] == "live,conversation,speaker:v1"
    assert row["created_at"] == 1790112660.0
    store = external._open(home)[0]
    assert store.keyword_search("global", "Brenda lesson"), "found by the recall chat uses"


def test_the_same_fact_twice_is_remembered_once(home):
    first = external.remember("Pranav lives in Houston.", source="live:s1:fact:1-2",
                              hermes_home=home)
    again = external.remember("Pranav lives in Houston.", source="live:s2:fact:5-6",
                              hermes_home=home)
    assert first and again is None


def test_forgetting_a_recording_or_a_voice_takes_only_theirs(home):
    external.remember("one", source="live:s1:1-2", tags="live,speaker:v1", dedup=False,
                      hermes_home=home)
    external.remember("two", source="live:s1:3-4", tags="live,speaker:v2", dedup=False,
                      hermes_home=home)
    external.remember("three", source="live:s2:1-2", tags="live,speaker:v3", dedup=False,
                      hermes_home=home)
    external.remember("four", source="chat", tags="fact", dedup=False, hermes_home=home)

    assert external.forget(source_prefix="live:s1:", hermes_home=home) == 2
    assert external.forget(tag="speaker:v3", hermes_home=home) == 1
    assert [r["body"] for r in _rows(home)] == ["four"]


def test_a_source_prefix_is_not_a_pattern(home):
    external.remember("a", source="live:s_1:1", dedup=False, hermes_home=home)
    external.remember("b", source="live:sX1:1", dedup=False, hermes_home=home)
    assert external.forget(source_prefix="live:s_1:", hermes_home=home) == 1


def test_nothing_is_written_when_another_provider_is_in_use(monkeypatch):
    import jarviscopilot_cli.config as main_config
    monkeypatch.setattr(main_config, "load_config",
                        lambda: {"memory": {"provider": "holographic"}})
    assert external.is_active() is False
    monkeypatch.setattr(main_config, "load_config",
                        lambda: {"memory": {"provider": "jarvis_memory"}})
    assert external.is_active() is True
