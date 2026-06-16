"""Unit tests for the desktop Mutagen driver (argv + status parsing + flow)."""
import json

from jc_client.coding_mutagen import (
    DEFAULT_IGNORES, MutagenDriver, MutagenError, create_sync_argv, merge_ignores,
    parse_status, session_name, status_argv, terminate_argv,
)


def test_session_name_sanitized():
    assert session_name("e6daf36111a9") == "jc-e6daf36111a9"
    assert session_name("a b/c:d") == "jc-a-b-c-d"
    assert session_name("") == "jc-session"


def test_create_sync_argv_shape():
    argv = create_sync_argv("mutagen", name="jc-x", local_path="/Users/me/p",
                            remote_host="jc-hermes", remote_path="/root/p",
                            ignore=["node_modules", "build", "custompat"])
    assert argv[:6] == ["mutagen", "sync", "create", "--name", "jc-x", "--sync-mode"]
    assert "two-way-safe" in argv
    assert "--ignore-vcs" in argv
    # staging is bounded so one huge file can't fill the server disk
    assert "--max-staging-file-size" in argv
    # user ignores are MERGED with DEFAULT_IGNORES (never replace), deduped — so a
    # custom rule can't strip the baseline node_modules/.venv/... protection.
    expected = merge_ignores(["node_modules", "build", "custompat"])
    assert argv.count("--ignore") == len(expected)
    assert "node_modules" in argv  # from defaults (also passed by user, deduped)
    assert "custompat" in argv     # user-added
    assert ".cache" in argv        # a default the user did NOT pass
    # local then remote host:path last
    assert argv[-2:] == ["/Users/me/p", "jc-hermes:/root/p"]


def test_merge_ignores_dedups_and_appends():
    out = merge_ignores(["node_modules", "myrule"])
    assert out[:len(DEFAULT_IGNORES)] == DEFAULT_IGNORES  # defaults first, intact
    assert out.count("node_modules") == 1                  # deduped
    assert out[-1] == "myrule"                             # user rule appended
    assert merge_ignores(None) == DEFAULT_IGNORES
    assert merge_ignores([]) == DEFAULT_IGNORES


def test_default_ignores_excludes_flutter_machine_specific():
    # A Flutter repo's ios/Flutter/ephemeral tree (absolute symlinks) plus the
    # machine-specific generated files (.dart_tool / .packages / .flutter-plugins* /
    # Generated.xcconfig / flutter_export_environment.sh) DIFFER on every machine and
    # Flutter regenerates them constantly — so bidi-syncing a live Flutter checkout
    # creates permanent, ever-regenerating conflicts that wedge the sync in
    # "auto-resolving…" forever (the healer also can't resolve the absolute
    # symlinks). They must be ignored — the same class as the already-ignored
    # ".symlinks".
    for pat in ("ephemeral", ".dart_tool", ".packages",
                ".flutter-plugins", ".flutter-plugins-dependencies",
                "Generated.xcconfig", "flutter_export_environment.sh"):
        assert pat in DEFAULT_IGNORES, f"{pat!r} missing from DEFAULT_IGNORES"


def test_status_argv_and_terminate_argv():
    assert status_argv("mutagen", "jc-x") == [
        "mutagen", "sync", "list", "--template", "{{json .}}", "jc-x"]
    assert terminate_argv("mutagen", "jc-x") == ["mutagen", "sync", "terminate", "jc-x"]


def test_parse_status_synced():
    # {{json .}} emits an ARRAY; status is the machine token "watching".
    out = parse_status(json.dumps([{"status": "watching", "conflicts": []}]))
    assert out["status"] == "synced"
    assert out["conflicts"] == 0


def test_parse_status_syncing_with_nested_staging_progress():
    out = parse_status(json.dumps([{
        "status": "staging-beta",
        "beta": {"stagingProgress": {"receivedFiles": 17, "expectedFiles": 483}},
        "conflicts": []}]))
    assert out["status"] == "syncing"
    assert out["done"] == 17 and out["total"] == 483


def test_parse_status_conflicts():
    out = parse_status(json.dumps([{
        "status": "watching",
        "conflicts": [{"root": "a.py"}, {"root": "b.py"}]}]))
    assert out["status"] == "conflicts"
    assert out["conflicts"] == 2


def test_parse_status_error_from_last_error():
    out = parse_status(json.dumps([{"status": "connecting-alpha",
                                    "lastError": "ssh: connect refused"}]))
    assert out["status"] == "error"
    assert "connect refused" in out["error"]


def test_parse_status_halted_is_error():
    out = parse_status(json.dumps([{"status": "halted-on-root-deletion"}]))
    assert out["status"] == "error"


def test_parse_status_connecting_token():
    out = parse_status(json.dumps([{"status": "connecting-beta"}]))
    assert out["status"] == "connecting"


def test_parse_status_empty_or_garbage():
    assert parse_status("")["status"] == "unknown"
    assert parse_status("not json")["status"] == "unknown"
    assert parse_status("[]")["status"] == "unknown"


# ── driver flow with a fake runner ────────────────────────────────────────────


class FakeRunner:
    def __init__(self, status_json=None, create_rc=0):
        self.calls = []
        self._status_json = status_json or json.dumps([{"status": "watching"}])
        self._create_rc = create_rc

    def __call__(self, argv, env=None, timeout=None):
        self.calls.append(argv)
        if argv[1:3] == ["sync", "list"]:
            return 0, self._status_json, ""
        if argv[1:3] == ["sync", "create"]:
            return self._create_rc, "", ("boom" if self._create_rc else "")
        return 0, "", ""


def test_driver_start_then_status():
    fr = FakeRunner()
    d = MutagenDriver(mutagen_path="mutagen", runner=fr)
    name = d.start_sync(session_id="cs1", local_path="/l", remote_host="jc-hermes",
                        remote_path="/r")
    assert name == "jc-cs1"
    # start terminates any prior session, then creates
    kinds = [c[1:3] for c in fr.calls]
    assert ["sync", "terminate"] in kinds and ["sync", "create"] in kinds
    st = d.status("cs1")
    assert st["status"] == "synced"


def test_driver_create_failure_raises():
    d = MutagenDriver(mutagen_path="mutagen", runner=FakeRunner(create_rc=1))
    try:
        d.start_sync(session_id="cs1", local_path="/l", remote_host="jc-hermes",
                     remote_path="/r")
        assert False, "expected MutagenError"
    except MutagenError as e:
        assert "create failed" in str(e)


def test_driver_missing_binary_raises():
    d = MutagenDriver(mutagen_path="x", runner=FakeRunner())
    d.set_path("")  # force "no engine" (find_mutagen may resolve a real binary)
    assert d.has_engine() is False
    try:
        d.status("cs1")
        assert False
    except MutagenError as e:
        assert "not found" in str(e)


# ── reconcile (orphan cleanup) ────────────────────────────────────────────────


class _FakeReconcileDriver:
    """Records terminate_by_name; lists a fixed set of Mutagen session names."""

    def __init__(self, names):
        self._names = list(names)
        self.terminated = []

    def name_for(self, sid):
        return "jc-" + sid

    def list_session_names(self):
        return list(self._names)

    def terminate_by_name(self, name):
        self.terminated.append(name)

    def stop_sync(self, sid):
        pass

    # the orphan-prune now ensures the engine + daemon before listing sessions
    def has_engine(self):
        return True

    def ensure_daemon(self):
        pass


def test_agent_reconcile_terminates_only_orphans():
    from jc_client.coding_sync_mutagen import CodingMutagenAgent
    import tempfile

    drv = _FakeReconcileDriver(
        ["jc-sync-a", "jc-sync-b", "jc-sync-orphan", "jc-other-tool"])
    with tempfile.TemporaryDirectory() as td:
        agent = CodingMutagenAgent(send=lambda f: None, state_dir=td, driver=drv)
        agent.handle_frame({"type": "coding_sync_reconcile",
                            "active": ["sync-a"]})
    # jc-sync-b and jc-sync-orphan are ours but not active -> terminated.
    # jc-sync-a is active -> kept. jc-other-tool isn't ours -> untouched.
    assert set(drv.terminated) == {"jc-sync-b", "jc-sync-orphan"}


def test_agent_reconcile_ignores_bad_payload():
    from jc_client.coding_sync_mutagen import CodingMutagenAgent
    import tempfile

    drv = _FakeReconcileDriver(["jc-sync-a"])
    with tempfile.TemporaryDirectory() as td:
        agent = CodingMutagenAgent(send=lambda f: None, state_dir=td, driver=drv)
        agent.handle_frame({"type": "coding_sync_reconcile"})  # no 'active'
    assert drv.terminated == []  # nothing terminated on a malformed frame
