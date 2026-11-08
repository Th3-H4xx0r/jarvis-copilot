"""Unit tests for agent/coding_sync_safety.py (pure server-side path guards)."""
import os
import pathlib

from agent.coding_sync_safety import (
    SyncSafetyConfig,
    is_home_like,
    is_dangerous_path,
    looks_like_local_path_on_server,
    under_allowed_root,
    validate_server_path,
    validate_endpoints_for_server_gate,
)


def _cfg(**kw):
    base = dict(allowed_server_roots=["/root/codingprojects"])
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


def test_config_from_env_overrides():
    cfg = SyncSafetyConfig.from_env({"JC_SYNC_ALLOWED_SERVER_ROOTS": "/a/b:/c/d"})
    assert cfg.allowed_server_roots == ["/a/b", "/c/d"]
    # default server roots when unset
    assert SyncSafetyConfig.from_env({}).allowed_server_roots == ["~/codingprojects"]


def test_shared_predicates_are_the_jc_client_definitions():
    """The server and the Mac decide which folders are safe with ONE definition:
    jc-client's sync_safety.py, loaded by path."""
    import agent.coding_sync_safety as server

    jc_file = (pathlib.Path(__file__).resolve().parents[1]
               / "desktop_client" / "jc_client" / "sync_safety.py")
    assert pathlib.Path(server.shared.__file__).resolve() == jc_file
    for name in ("is_home_like", "is_dangerous_path", "under_allowed_root"):
        assert getattr(server, name) is getattr(server.shared, name), name
