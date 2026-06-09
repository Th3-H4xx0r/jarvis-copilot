"""Unit tests for agent/coding_sync_safety.py (pure path + size guards)."""
import os

from agent.coding_sync_safety import (
    SyncSafetyConfig,
    is_home_like,
    is_dangerous_path,
    looks_like_local_path_on_server,
    under_allowed_root,
    validate_server_path,
    validate_local_path,
    validate_endpoints_for_server_gate,
    estimate_tree,
)


def _cfg(**kw):
    base = dict(allowed_local_roots=["/Users/me/code", "~/projects"],
                allowed_server_roots=["/root/codingprojects"])
    base.update(kw)
    return SyncSafetyConfig(**base)


def test_home_like_detects_mac_and_linux_homes():
    assert is_home_like("/Users/pranavkrishna")
    assert is_home_like("/home/alice")
    assert is_home_like("/root")
    assert is_home_like(os.path.expanduser("~"))
    # deeper paths are NOT home-like
    assert not is_home_like("/Users/pranavkrishna/PranavFiles/coding-projects/x")
    assert not is_home_like("/root/codingprojects/x")


def test_dangerous_paths():
    for p in ("/", "", "/Users/pranavkrishna", "/home/bob", "/root",
              "/etc", "/usr", "/var", "/Users/me/"):
        assert is_dangerous_path(p), p
    for p in ("/Users/me/code/proj", "/root/codingprojects/IntelliStock"):
        assert not is_dangerous_path(p), p


def test_looks_like_local_path_on_server():
    assert looks_like_local_path_on_server("/Users/pranavkrishna/PranavFiles/x")
    assert looks_like_local_path_on_server("/Users")
    assert not looks_like_local_path_on_server("/root/codingprojects/x")
    assert not looks_like_local_path_on_server("/home/u/x")  # real Linux path


def test_under_allowed_root():
    roots = ["/root/codingprojects"]
    assert under_allowed_root("/root/codingprojects", roots)
    assert under_allowed_root("/root/codingprojects/IntelliStock", roots)
    assert not under_allowed_root("/root/JarvisCopilot", roots)
    assert not under_allowed_root("/root/codingprojectsX", roots)  # prefix, not nested


def test_validate_server_path_rejects_the_real_incidents():
    cfg = _cfg()
    # the whole-home + the Mac-path-as-server cases we actually hit:
    ok, why = validate_server_path("/Users/pranavkrishna/PranavFiles/coding-projects/jarvis-copilot", cfg)
    assert not ok and "Mac path" in why
    ok, why = validate_server_path("/root", cfg)
    assert not ok
    ok, why = validate_server_path("/root/JarvisCopilot", cfg)  # outside allowed root
    assert not ok and "allowed roots" in why
    # the correct IntelliStock server path passes:
    ok, why = validate_server_path("/root/codingprojects/IntelliStock", cfg)
    assert ok and why == ""


def test_validate_local_path_allowlist():
    cfg = _cfg()
    ok, _ = validate_local_path("/Users/me/code/proj", cfg)
    assert ok
    ok, why = validate_local_path("/Users/pranavkrishna", cfg)  # home
    assert not ok
    ok, why = validate_local_path("/Users/me/Desktop/random", cfg)  # outside roots
    assert not ok and "allowed sync roots" in why


def test_server_gate_blocks_home_local_even_on_server():
    # The whole-home-dir runaway: local=$HOME. The server gate must reject it by
    # pattern even though Mac ~ doesn't resolve on the server.
    cfg = _cfg()
    ok, why = validate_endpoints_for_server_gate(
        "/Users/pranavkrishna", "/root/codingprojects/x", cfg)
    assert not ok and "home/system" in why
    # a good pair passes
    ok, why = validate_endpoints_for_server_gate(
        "/Users/me/code/proj", "/root/codingprojects/proj", cfg)
    assert ok


def test_estimate_tree_bounded_and_early_exit(tmp_path):
    # build a small tree with an ignored dir
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

    # tiny byte cap → early exit (exceeded True), doesn't need to finish the walk
    _b, _f, exceeded = estimate_tree(
        str(tmp_path), ["node_modules"], byte_cap=10, file_cap=10_000)
    assert exceeded

    # tiny file cap → early exit
    _b, _f, exceeded = estimate_tree(
        str(tmp_path), ["node_modules"], byte_cap=10_000, file_cap=1)
    assert exceeded


def test_config_from_env_overrides():
    env = {"JC_SYNC_ALLOWED_LOCAL_ROOTS": "/a/b:/c/d",
           "JC_SYNC_MAX_TREE_BYTES": "12345", "JC_SYNC_MAX_FILES": "7"}
    cfg = SyncSafetyConfig.from_env(env)
    assert cfg.allowed_local_roots == ["/a/b", "/c/d"]
    assert cfg.max_tree_bytes == 12345
    assert cfg.max_files == 7
    # default server roots when unset
    assert cfg.allowed_server_roots == ["~/codingprojects"]
