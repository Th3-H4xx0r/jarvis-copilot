"""Tests for the pure-filesystem core of the bidirectional Coding-Session sync.

Strict TDD: these are written before the implementation. They exercise the
filesystem + diff + conflict LOGIC only (no networking).
"""

import hashlib
import os

import pytest

from agent import coding_sync as cs


# --------------------------------------------------------------------------- #
# is_ignored
# --------------------------------------------------------------------------- #
def test_is_ignored_default_dirs_and_globs():
    ig = cs.DEFAULT_IGNORES
    assert cs.is_ignored("node_modules/x.js", ig)
    assert cs.is_ignored(".git/config", ig)
    assert cs.is_ignored("a/__pycache__/b.pyc", ig)
    assert cs.is_ignored("a/b/c.pyc", ig)  # *.pyc glob anywhere
    assert cs.is_ignored(".DS_Store", ig)
    assert cs.is_ignored("sub/.DS_Store", ig)


def test_is_ignored_normal_files_not_ignored():
    ig = cs.DEFAULT_IGNORES
    assert not cs.is_ignored("src/app.py", ig)
    assert not cs.is_ignored("README.md", ig)
    assert not cs.is_ignored("a/b/c.txt", ig)


def test_is_ignored_matches_full_relpath_glob():
    # A glob that targets a full relative path should also match.
    assert cs.is_ignored("build/output.log", ["build/*.log"])
    assert not cs.is_ignored("build/output.txt", ["build/*.log"])


def test_is_ignored_empty_ignores_matches_nothing():
    assert not cs.is_ignored("node_modules/x.js", [])


# --------------------------------------------------------------------------- #
# build_manifest
# --------------------------------------------------------------------------- #
def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def test_build_manifest_basic(tmp_path):
    (tmp_path / "src").mkdir()
    (tmp_path / "src" / "app.py").write_bytes(b"print('hi')\n")
    (tmp_path / "README.md").write_bytes(b"# hi\n")

    man = cs.build_manifest(str(tmp_path))

    assert set(man.keys()) == {"src/app.py", "README.md"}
    size, mtime, h = man["src/app.py"]
    assert size == len(b"print('hi')\n")
    assert isinstance(mtime, float)
    assert h == _sha(b"print('hi')\n")


def test_build_manifest_skips_ignored(tmp_path):
    (tmp_path / "src").mkdir()
    (tmp_path / "src" / "app.py").write_bytes(b"x")
    (tmp_path / ".git").mkdir()
    (tmp_path / ".git" / "config").write_bytes(b"secret")
    (tmp_path / "node_modules").mkdir()
    (tmp_path / "node_modules" / "lib.js").write_bytes(b"y")
    (tmp_path / "mod.pyc").write_bytes(b"z")
    (tmp_path / ".DS_Store").write_bytes(b"")

    man = cs.build_manifest(str(tmp_path))

    assert set(man.keys()) == {"src/app.py"}


def test_build_manifest_uses_forward_slashes(tmp_path):
    (tmp_path / "a" / "b").mkdir(parents=True)
    (tmp_path / "a" / "b" / "c.txt").write_bytes(b"hello")

    man = cs.build_manifest(str(tmp_path))

    assert "a/b/c.txt" in man
    assert all("\\" not in k for k in man)


def test_build_manifest_custom_ignores(tmp_path):
    (tmp_path / "keep.txt").write_bytes(b"a")
    (tmp_path / "drop.log").write_bytes(b"b")

    man = cs.build_manifest(str(tmp_path), ignores=["*.log"])

    assert set(man.keys()) == {"keep.txt"}


def test_build_manifest_empty_dir(tmp_path):
    assert cs.build_manifest(str(tmp_path)) == {}


# --------------------------------------------------------------------------- #
# diff_manifests
# --------------------------------------------------------------------------- #
def _entry(data: bytes):
    return (len(data), 0.0, _sha(data))


def test_diff_local_only_to_send():
    local = {"a.txt": _entry(b"a")}
    remote = {}
    d = cs.diff_manifests(local, remote)
    assert d["to_send"] == ["a.txt"]
    assert d["to_receive"] == []
    assert d["to_delete_remote"] == []
    assert d["conflicts"] == []


def test_diff_remote_only_to_receive():
    local = {}
    remote = {"b.txt": _entry(b"b")}
    d = cs.diff_manifests(local, remote)
    assert d["to_receive"] == ["b.txt"]
    assert d["to_send"] == []


def test_diff_same_hash_no_op():
    e = _entry(b"same")
    d = cs.diff_manifests({"f": e}, {"f": e})
    assert d["to_send"] == []
    assert d["to_receive"] == []
    assert d["to_delete_remote"] == []
    assert d["conflicts"] == []


def test_diff_changed_no_base_is_conflict():
    local = {"f": _entry(b"local-version")}
    remote = {"f": _entry(b"remote-version")}
    d = cs.diff_manifests(local, remote)
    assert d["conflicts"] == ["f"]
    assert d["to_send"] == []
    assert d["to_receive"] == []


def test_diff_with_base_changed_on_both_is_conflict():
    base = {"f": _entry(b"orig")}
    local = {"f": _entry(b"local-change")}
    remote = {"f": _entry(b"remote-change")}
    d = cs.diff_manifests(local, remote, base=base)
    assert d["conflicts"] == ["f"]


def test_diff_with_base_changed_local_only_to_send():
    base = {"f": _entry(b"orig")}
    local = {"f": _entry(b"local-change")}
    remote = {"f": _entry(b"orig")}
    d = cs.diff_manifests(local, remote, base=base)
    assert d["to_send"] == ["f"]
    assert d["conflicts"] == []


def test_diff_with_base_changed_remote_only_to_receive():
    base = {"f": _entry(b"orig")}
    local = {"f": _entry(b"orig")}
    remote = {"f": _entry(b"remote-change")}
    d = cs.diff_manifests(local, remote, base=base)
    assert d["to_receive"] == ["f"]
    assert d["conflicts"] == []


def test_diff_deleted_local_present_in_base_deletes_remote():
    # File existed at last sync (base), local deleted it, remote unchanged.
    base = {"f": _entry(b"orig")}
    local = {}
    remote = {"f": _entry(b"orig")}
    d = cs.diff_manifests(local, remote, base=base)
    assert d["to_delete_remote"] == ["f"]
    assert d["to_receive"] == []


def test_diff_deleted_remote_present_in_base_receives_delete_via_receive_absent():
    # File existed at last sync, remote deleted it, local unchanged -> local
    # should delete it (it appears in to_receive-as-delete? No: we model the
    # remote deletion as "not to_send"). We assert it is NOT re-sent.
    base = {"f": _entry(b"orig")}
    local = {"f": _entry(b"orig")}
    remote = {}
    d = cs.diff_manifests(local, remote, base=base)
    # Remote deleted a file that is unchanged locally -> local should delete it.
    assert d["to_delete_local"] == ["f"]
    assert d["to_send"] == []


def test_diff_remote_only_with_base_absent_is_receive():
    # remote has a brand-new file not in base, not in local -> receive it.
    base = {}
    local = {}
    remote = {"new": _entry(b"x")}
    d = cs.diff_manifests(local, remote, base=base)
    assert d["to_receive"] == ["new"]


def test_diff_results_are_sorted():
    local = {"z.txt": _entry(b"1"), "a.txt": _entry(b"2")}
    remote = {}
    d = cs.diff_manifests(local, remote)
    assert d["to_send"] == ["a.txt", "z.txt"]


# --------------------------------------------------------------------------- #
# safe_join
# --------------------------------------------------------------------------- #
def test_safe_join_normal_nested(tmp_path):
    p = cs.safe_join(str(tmp_path), "a/b/c.txt")
    assert p == os.path.join(str(tmp_path), "a", "b", "c.txt")


def test_safe_join_rejects_parent_traversal(tmp_path):
    with pytest.raises(ValueError):
        cs.safe_join(str(tmp_path), "../escape")


def test_safe_join_rejects_absolute(tmp_path):
    with pytest.raises(ValueError):
        cs.safe_join(str(tmp_path), "/etc/passwd")


def test_safe_join_rejects_deep_traversal(tmp_path):
    with pytest.raises(ValueError):
        cs.safe_join(str(tmp_path), "a/b/../../../etc/passwd")


def test_safe_join_rejects_symlink_escape(tmp_path):
    # Create a symlink inside root pointing OUTSIDE root, then try to write
    # through it. realpath of the joined path escapes root -> reject.
    outside = tmp_path.parent / "outside_target"
    outside.mkdir()
    root = tmp_path / "root"
    root.mkdir()
    link = root / "link"
    os.symlink(str(outside), str(link))
    with pytest.raises(ValueError):
        cs.safe_join(str(root), "link/file.txt")


def test_safe_join_allows_nonexistent_path(tmp_path):
    # Should not require the file to exist yet.
    p = cs.safe_join(str(tmp_path), "does/not/exist/yet.txt")
    assert p.endswith(os.path.join("exist", "yet.txt"))


# --------------------------------------------------------------------------- #
# apply_write / apply_delete
# --------------------------------------------------------------------------- #
def test_apply_write_read_back(tmp_path):
    cs.apply_write(str(tmp_path), "x/y/z.txt", b"hello world")
    assert (tmp_path / "x" / "y" / "z.txt").read_bytes() == b"hello world"


def test_apply_write_creates_dirs(tmp_path):
    cs.apply_write(str(tmp_path), "deep/nested/dir/file.bin", b"\x00\x01\x02")
    assert (tmp_path / "deep" / "nested" / "dir" / "file.bin").exists()


def test_apply_write_overwrites_atomically(tmp_path):
    cs.apply_write(str(tmp_path), "f.txt", b"v1")
    cs.apply_write(str(tmp_path), "f.txt", b"v2-longer")
    assert (tmp_path / "f.txt").read_bytes() == b"v2-longer"
    # No leftover atomic-write temp files (".sync-tmp-*") in the target dir.
    # (Other entries may exist from shared conftest fixtures; we only assert
    # that our own temp file was consumed by os.replace.)
    leftovers = [p.name for p in tmp_path.iterdir() if p.name.startswith(".sync-tmp-")]
    assert leftovers == []


def test_apply_write_rejects_traversal(tmp_path):
    with pytest.raises(ValueError):
        cs.apply_write(str(tmp_path), "../evil.txt", b"x")


def test_apply_delete_removes_file(tmp_path):
    (tmp_path / "gone.txt").write_bytes(b"bye")
    cs.apply_delete(str(tmp_path), "gone.txt")
    assert not (tmp_path / "gone.txt").exists()


def test_apply_delete_noop_when_absent(tmp_path):
    # Must not raise.
    cs.apply_delete(str(tmp_path), "never/existed.txt")


def test_apply_delete_rejects_traversal(tmp_path):
    with pytest.raises(ValueError):
        cs.apply_delete(str(tmp_path), "../../etc/passwd")


# --------------------------------------------------------------------------- #
# conflict_copy_name
# --------------------------------------------------------------------------- #
def test_conflict_copy_name_format():
    assert (
        cs.conflict_copy_name("path/to/file.txt", "laptop", 1700000000)
        == "path/to/file.txt.conflict-laptop-1700000000"
    )


def test_conflict_copy_name_root_file():
    assert cs.conflict_copy_name("f.py", "host", 42) == "f.py.conflict-host-42"


# --------------------------------------------------------------------------- #
# iter_chunks
# --------------------------------------------------------------------------- #
def test_iter_chunks_reconstructs(tmp_path):
    data = os.urandom(5 * (1 << 20) + 123)  # > 5 chunks at 1 MiB
    f = tmp_path / "big.bin"
    f.write_bytes(data)

    chunks = list(cs.iter_chunks(str(f)))
    assert len(chunks) > 1
    assert b"".join(chunks) == data


def test_iter_chunks_custom_size(tmp_path):
    data = b"abcdefghij"
    f = tmp_path / "small.bin"
    f.write_bytes(data)

    chunks = list(cs.iter_chunks(str(f), chunk_size=3))
    assert chunks == [b"abc", b"def", b"ghi", b"j"]


def test_iter_chunks_empty_file(tmp_path):
    f = tmp_path / "empty.bin"
    f.write_bytes(b"")
    assert list(cs.iter_chunks(str(f))) == []


def test_decide_initial_direction():
    from agent.coding_sync import decide_initial_direction, is_manifest_empty
    assert decide_initial_direction(remote_is_empty=True) == "push"
    assert decide_initial_direction(remote_is_empty=False) == "pull"
    assert is_manifest_empty({}) is True
    assert is_manifest_empty({"a.py": (1, 2.0, "h")}) is False


def test_plan_initial_sync_push_when_remote_empty():
    from agent.coding_sync import plan_initial_sync
    server = {"a.py": (1, 2.0, "h1"), "b.py": (1, 2.0, "h2")}
    plan = plan_initial_sync(server, {})
    assert plan["direction"] == "push"
    assert plan["files"] == ["a.py", "b.py"]


def test_plan_initial_sync_pull_when_remote_has_files():
    from agent.coding_sync import plan_initial_sync
    server = {"a.py": (1, 2.0, "h1")}
    remote = {"x.py": (1, 2.0, "rh"), "y.py": (1, 2.0, "rh2")}
    plan = plan_initial_sync(server, remote)
    assert plan["direction"] == "pull"
    assert plan["files"] == ["x.py", "y.py"]


def test_plan_initial_sync_pull_resumes_skips_matching_hashes():
    """Resume: pull only the remote files the server is missing or differs on,
    so a reconnect continues instead of re-pulling the whole tree."""
    from agent.coding_sync import plan_initial_sync
    remote = {"a.py": (1, 2.0, "h1"), "b.py": (1, 2.0, "h2"),
              "c.py": (1, 2.0, "h3")}
    # server already has a.py (same hash) and b.py (DIFFERENT hash)
    server = {"a.py": (1, 9.0, "h1"), "b.py": (1, 9.0, "OTHER")}
    plan = plan_initial_sync(server, remote)
    assert plan["direction"] == "pull"
    # a.py matches → skipped; b.py differs → re-pull; c.py missing → pull
    assert plan["files"] == ["b.py", "c.py"]


def test_plan_initial_sync_push_diff_only_changed():
    from agent.coding_sync import plan_initial_sync
    server = {"a.py": (1, 2.0, "h1"), "b.py": (1, 2.0, "h2")}
    plan = plan_initial_sync(server, {})  # empty remote -> push everything
    assert plan["direction"] == "push"
    assert plan["files"] == ["a.py", "b.py"]
