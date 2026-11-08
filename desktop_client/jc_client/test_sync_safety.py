"""Unit tests for jc_client/sync_safety.py (the client gate + bounded tree walk)."""
from jc_client.sync_safety import (
    LocalSyncSafetyConfig,
    check_local_sync,
    estimate_tree,
    roots_from_env,
)


def _cfg(**kw):
    base = dict(allowed_local_roots=["/Users/me/code", "~/projects"])
    base.update(kw)
    return LocalSyncSafetyConfig(**base)


def test_check_local_sync_allowlist():
    ok, _ = check_local_sync("/Users/me/code/proj", [], _cfg())
    assert ok
    ok, why = check_local_sync("/Users/pranavkrishna", [], _cfg())  # home
    assert not ok and "home/system" in why
    ok, why = check_local_sync("/Users/me/Desktop/random", [], _cfg())  # outside roots
    assert not ok and "allowed sync roots" in why


def test_check_local_sync_refuses_a_tree_over_the_cap(tmp_path):
    (tmp_path / "a.bin").write_bytes(b"x" * 100)
    ok, why = check_local_sync(str(tmp_path), [],
                               _cfg(allowed_local_roots=[str(tmp_path)], max_tree_bytes=10))
    assert not ok and "too large" in why


def test_estimate_tree_bounded_and_early_exit(tmp_path):
    (tmp_path / "a.txt").write_bytes(b"x" * 100)
    (tmp_path / "node_modules").mkdir()
    (tmp_path / "node_modules" / "big.bin").write_bytes(b"y" * 10_000)
    (tmp_path / ".git").mkdir()
    (tmp_path / ".git" / "obj").write_bytes(b"z" * 10_000)
    sub = tmp_path / "src"
    sub.mkdir()
    (sub / "b.txt").write_bytes(b"q" * 50)

    # node_modules + .git pruned → only a.txt + src/b.txt counted (150 bytes, 2 files)
    total_bytes, total_files, exceeded = estimate_tree(
        str(tmp_path), ["node_modules"], byte_cap=10_000, file_cap=10_000)
    assert not exceeded
    assert total_files == 2
    assert total_bytes == 150

    _b, _f, exceeded = estimate_tree(
        str(tmp_path), ["node_modules"], byte_cap=10, file_cap=10_000)
    assert exceeded
    _b, _f, exceeded = estimate_tree(
        str(tmp_path), ["node_modules"], byte_cap=10_000, file_cap=1)
    assert exceeded


def test_config_from_env_overrides():
    env = {"JC_SYNC_ALLOWED_LOCAL_ROOTS": "/a/b:/c/d",
           "JC_SYNC_MAX_TREE_BYTES": "12345", "JC_SYNC_MAX_FILES": "7"}
    cfg = LocalSyncSafetyConfig.from_env(env)
    assert cfg.allowed_local_roots == ["/a/b", "/c/d"]
    assert cfg.max_tree_bytes == 12345
    assert cfg.max_files == 7


def test_roots_from_env_falls_back_to_the_default():
    assert roots_from_env({}, "K", ["~/x"]) == ["~/x"]
    assert roots_from_env({"K": " , : "}, "K", ["~/x"]) == ["~/x"]
    assert roots_from_env({"K": "/a,/b"}, "K", ["~/x"]) == ["/a", "/b"]
