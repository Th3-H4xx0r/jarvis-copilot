from plugins.memory.jarvis_memory.autofetch import (
    AutoFetchScheduler,
    FakeSyncSource,
    FolderSyncSource,
    SyncItem,
    build_sources,
)
from plugins.memory.jarvis_memory.embed import FakeEmbedder
from plugins.memory.jarvis_memory.store import GLOBAL_NS, MemoryStore


def _mem(tmp_path):
    return MemoryStore(tmp_path / "m.db", tmp_path / "v"), FakeEmbedder(dim=64)


def test_scheduler_ingests_and_tracks_cursor(tmp_path):
    mem, e = _mem(tmp_path)
    src = FakeSyncSource("s1", [([SyncItem("i1", "the auth migration ships friday", "note:1", 100.0)], 100.0)])
    sch = AutoFetchScheduler([src], mem, e, GLOBAL_NS)
    assert sch.run_once() >= 1
    assert mem.count_chunks(GLOBAL_NS) >= 1
    assert mem.kv_get("__autofetch__", "s1") == "100.0"
    assert sch.run_once() == 0  # no further batches -> nothing new
    mem.close()


def test_ingest_idempotent_on_same_content(tmp_path):
    mem, e = _mem(tmp_path)
    item = SyncItem("i1", "a durable note about the project deadline", "note:1", 100.0)
    AutoFetchScheduler([FakeSyncSource("sA", [([item], 100.0)])], mem, e).run_once()
    c1 = mem.count_chunks(GLOBAL_NS)
    AutoFetchScheduler([FakeSyncSource("sB", [([item], 100.0)])], mem, e).run_once()
    assert mem.count_chunks(GLOBAL_NS) == c1  # identical content -> no duplicate
    mem.close()


def test_folder_source_picks_up_text_files(tmp_path):
    mem, e = _mem(tmp_path)
    folder = tmp_path / "notes"
    folder.mkdir()
    (folder / "a.md").write_text("Pranav lives in Mountain House CA")
    (folder / "ignore.png").write_bytes(b"\x89PNG")
    sch = AutoFetchScheduler([FolderSyncSource(str(folder))], mem, e, GLOBAL_NS)
    assert sch.run_once() >= 1
    assert mem.keyword_search(GLOBAL_NS, "Mountain House", 10)
    assert sch.run_once() == 0  # unchanged files not re-ingested
    mem.close()


def test_build_sources_from_config(tmp_path):
    srcs = build_sources({"autofetch_folders": [str(tmp_path)]})
    assert len(srcs) == 1 and isinstance(srcs[0], FolderSyncSource)
    assert build_sources({}) == []
