"""Tests for the Mutagen conflict self-healer (newest-edit-wins + backups)."""
import os
import tempfile

from jc_client.coding_sync_heal import (
    ConflictHealer, extract_conflict_paths, parse_endpoint_urls, safe_relpath,
)


def _session(alpha_root, paths, host="jc-hermes", beta_root="/root/proj"):
    return {
        "alpha": {"url": alpha_root},
        "beta": {"url": f"{host}:{beta_root}"},
        "conflicts": [
            {"alphaChanges": [{"path": p}], "betaChanges": [{"path": p}]}
            for p in paths
        ],
    }


class FakeRunner:
    """Routes ssh commands: scripted stat output; records mv/backup calls."""

    def __init__(self, stat_out=""):
        self.stat_out = stat_out
        self.calls = []

    def __call__(self, argv, timeout=30.0):
        cmd = argv[-1]
        self.calls.append(cmd)
        if cmd.startswith("stat "):
            return 0, self.stat_out, ""
        if "mv -- " in cmd:
            return 0, "HEALED\n", ""
        return 0, "", ""


def _mk(alpha_root, rel, mtime):
    p = os.path.join(alpha_root, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        f.write("local")
    os.utime(p, (mtime, mtime))
    return p


def _healer(state, runner):
    return ConflictHealer(state, runner=runner, now=lambda: 2_000_000.0)


def test_extract_and_url_parsing():
    s = _session("/a", ["x.py", "b/y.py"])
    assert extract_conflict_paths(s) == ["b/y.py", "x.py"]
    assert parse_endpoint_urls(s) == ("/a", "jc-hermes", "/root/proj")
    assert parse_endpoint_urls({"alpha": {"url": "rel"}, "beta": {}}) is None


def test_safe_relpath():
    assert safe_relpath("a/b.py")
    assert not safe_relpath("../etc/passwd")
    assert not safe_relpath("/abs")
    assert not safe_relpath("a/../b")
    assert not safe_relpath("")


def test_newer_alpha_wins_beta_backed_up():
    with tempfile.TemporaryDirectory() as alpha, \
            tempfile.TemporaryDirectory() as state:
        _mk(alpha, "a.py", 1_500_000)
        runner = FakeRunner(
            stat_out="1400000|regular file|/root/proj/a.py\n")
        res = _healer(state, runner).heal(_session(alpha, ["a.py"]), "s1")
        assert res == {"healed": 1, "skipped": 0}
        # local copy untouched; the BETA copy was moved to the remote backup
        assert os.path.exists(os.path.join(alpha, "a.py"))
        assert any("mv -- /root/proj/a.py" in c for c in runner.calls)


def test_newer_beta_wins_alpha_backed_up():
    with tempfile.TemporaryDirectory() as alpha, \
            tempfile.TemporaryDirectory() as state:
        _mk(alpha, "a.py", 1_300_000)
        runner = FakeRunner(
            stat_out="1400000|regular file|/root/proj/a.py\n")
        res = _healer(state, runner).heal(_session(alpha, ["a.py"]), "s1")
        assert res == {"healed": 1, "skipped": 0}
        # local copy MOVED into the backup tree; no remote mv issued
        assert not os.path.exists(os.path.join(alpha, "a.py"))
        backups = []
        for root, _d, files in os.walk(os.path.join(state, "sync-conflicts")):
            backups += [os.path.join(root, f) for f in files]
        assert len(backups) == 1 and backups[0].endswith("/a.py")
        assert not any("mv -- /root/proj" in c for c in runner.calls)


def test_tie_prefers_alpha():
    with tempfile.TemporaryDirectory() as alpha, \
            tempfile.TemporaryDirectory() as state:
        _mk(alpha, "a.py", 1_400_000)
        runner = FakeRunner(
            stat_out="1400000|regular file|/root/proj/a.py\n")
        res = _healer(state, runner).heal(_session(alpha, ["a.py"]), "s1")
        assert res["healed"] == 1
        assert os.path.exists(os.path.join(alpha, "a.py"))  # alpha kept


def test_delete_vs_modify_is_skipped():
    # alpha has no copy: deleting beta's surviving file would honor a deletion
    # automatically — exactly the data-loss class we refuse to auto-resolve.
    with tempfile.TemporaryDirectory() as alpha, \
            tempfile.TemporaryDirectory() as state:
        runner = FakeRunner(
            stat_out="1400000|regular file|/root/proj/a.py\n")
        res = _healer(state, runner).heal(_session(alpha, ["a.py"]), "s1")
        assert res == {"healed": 0, "skipped": 1}
        assert not any("mv" in c for c in runner.calls if "stat" not in c)


def test_non_regular_beta_skipped():
    with tempfile.TemporaryDirectory() as alpha, \
            tempfile.TemporaryDirectory() as state:
        _mk(alpha, "a.py", 1_500_000)
        runner = FakeRunner(stat_out="1400000|directory|/root/proj/a.py\n")
        res = _healer(state, runner).heal(_session(alpha, ["a.py"]), "s1")
        assert res == {"healed": 0, "skipped": 1}


def test_path_escape_never_touched():
    with tempfile.TemporaryDirectory() as alpha, \
            tempfile.TemporaryDirectory() as state:
        runner = FakeRunner()
        s = _session(alpha, ["../outside.py", "/etc/passwd"])
        res = _healer(state, runner).heal(s, "s1")
        assert res == {"healed": 0, "skipped": 0}
        assert not any("mv" in c for c in runner.calls if "stat" not in c)


def test_spaced_and_metachar_filenames_are_quoted():
    # rel comes from Mutagen JSON: spaces must heal, and shell metachars must
    # NEVER reach the server unquoted (RCE). The remote command must shlex-quote
    # both src and the rel-bearing dst while leaving $HOME expandable.
    with tempfile.TemporaryDirectory() as alpha, \
            tempfile.TemporaryDirectory() as state:
        # alpha newer → server copy loses and gets backed up via the REMOTE mv;
        # assert the generated remote command is safe for a nasty name.
        rel = "my dir/x$(touch HACKED).py"
        _mk(alpha, rel, 1_500_000)
        captured = []

        class Cap(FakeRunner):
            def __call__(self, argv, timeout=30.0):
                captured.append(argv[-1])
                return super().__call__(argv, timeout)

        runner = Cap(stat_out=f"1400000|regular file|/root/proj/{rel}\n")
        ConflictHealer(state, runner=runner, now=lambda: 2_000_000.0).heal(
            _session(alpha, [rel]), "s1")
        mv_cmd = next(c for c in captured if "mv -- " in c)
        # src single-quoted; the rel-bearing dst tail single-quoted; $HOME left
        # expandable. Both occurrences of the nasty rel are inside single quotes,
        # so the $(touch) payload is inert (shlex.quote wraps the whole token).
        assert "'/root/proj/my dir/x$(touch HACKED).py'" in mv_cmd
        assert "'.jc-sync-conflicts/s1/" in mv_cmd  # dst tail is quoted
        assert '"$HOME"/' in mv_cmd                  # …with $HOME expandable
        # No bare (unquoted) $( anywhere — every metachar token is quoted.
        for unq in ('-- $(', ' $(touch', '/$(touch'):
            assert unq not in mv_cmd


def test_rate_limit_due():
    t = {"v": 1000.0}
    h = ConflictHealer("/tmp/x", runner=FakeRunner(), now=lambda: t["v"])
    assert h.due("s1")
    h.heal({"alpha": {"url": "/nope"}, "beta": {}}, "s1")  # records the pass
    assert not h.due("s1")
    t["v"] += 31
    assert h.due("s1")
