"""Tests for the desktop Mutagen sync agent (frame handling + status emit)."""
import time

from jc_client.coding_sync_mutagen import CodingMutagenAgent
from jc_client.coding_mutagen import MutagenDriver, MutagenError


class FakeRunner:
    """Records argv; returns a configurable status JSON for `sync list`."""

    def __init__(self, status='[{"status": "watching"}]', create_rc=0):
        self.calls = []
        self.status = status
        self.create_rc = create_rc

    def __call__(self, argv, env=None, timeout=None):
        self.calls.append(argv)
        if argv[1:3] == ["sync", "list"]:
            return 0, self.status, ""
        if argv[1:3] == ["sync", "create"]:
            return self.create_rc, "", ("boom" if self.create_rc else "")
        return 0, "", ""


import tempfile as _tempfile


def _agent(runner, sent):
    driver = MutagenDriver(mutagen_path="mutagen", runner=runner)
    return CodingMutagenAgent(send=sent.append, driver=driver,
                              state_dir=_tempfile.mkdtemp(prefix="jc-sync-test-"),
                              proxy_command='"jc" tcp-relay', poll_interval=0.05)


def test_start_runs_mutagen_and_emits_status(tmp_path, monkeypatch):
    # avoid real ssh-keygen / ~/.ssh writes
    a = None
    sent = []
    runner = FakeRunner()
    a = _agent(runner, sent)
    monkeypatch.setattr(a, "pubkey", lambda: "ssh-ed25519 AAAA jc")
    a.handle_frame({"type": "coding_sync_start", "sync_id": "sync-1",
                    "local_path": "/Users/me/p", "remote_path": "/root/p",
                    "ignore": ["build"]})
    # a sync create happened to the jc-hermes alias
    creates = [c for c in runner.calls if c[1:3] == ["sync", "create"]]
    assert creates and "jc-hermes:/root/p" in creates[0]
    assert "/Users/me/p" in creates[0]
    # an immediate status was emitted
    assert any(f["type"] == "coding_sync_status" and f["sync_id"] == "sync-1"
               for f in sent)
    s = [f for f in sent if f["type"] == "coding_sync_status"][-1]
    assert s["status"] == "synced"
    a.close()


def test_start_failure_emits_error(monkeypatch):
    sent = []
    a = _agent(FakeRunner(create_rc=1), sent)
    monkeypatch.setattr(a, "pubkey", lambda: "k")
    a.handle_frame({"type": "coding_sync_start", "sync_id": "sync-x",
                    "local_path": "/l", "remote_path": "/r"})
    errs = [f for f in sent if f["type"] == "coding_sync_error"]
    assert errs and errs[0]["sync_id"] == "sync-x"
    a.close()


def test_stop_terminates(monkeypatch):
    sent = []
    runner = FakeRunner()
    a = _agent(runner, sent)
    monkeypatch.setattr(a, "pubkey", lambda: "k")
    a.handle_frame({"type": "coding_sync_start", "sync_id": "sync-1",
                    "local_path": "/l", "remote_path": "/r"})
    assert a.active_count() == 1
    a.handle_frame({"type": "coding_sync_stop", "sync_id": "sync-1"})
    assert a.active_count() == 0
    assert any(c[1:3] == ["sync", "terminate"] for c in runner.calls)


def test_status_poller_pushes_updates(monkeypatch):
    sent = []
    runner = FakeRunner(status='[{"status": "staging-beta", "beta": {"stagingProgress": {"receivedFiles": 3, "expectedFiles": 9}}}]')
    a = _agent(runner, sent)
    monkeypatch.setattr(a, "pubkey", lambda: "k")
    a.handle_frame({"type": "coding_sync_start", "sync_id": "sync-1",
                    "local_path": "/l", "remote_path": "/r"})
    time.sleep(0.2)  # let the poller tick a few times
    a.close()
    statuses = [f for f in sent if f["type"] == "coding_sync_status"]
    assert len(statuses) >= 2
    assert statuses[-1]["status"] == "syncing"
    assert statuses[-1]["done"] == 3 and statuses[-1]["total"] == 9


def test_sync_state_file_tracks_active_count(tmp_path, monkeypatch):
    import json as _json
    from jc_client.coding_mutagen import MutagenDriver
    sent = []
    driver = MutagenDriver(mutagen_path="mutagen", runner=FakeRunner())
    a = CodingMutagenAgent(send=sent.append, driver=driver,
                           state_dir=str(tmp_path), proxy_command='"jc" tcp-relay',
                           poll_interval=0.05)
    monkeypatch.setattr(a, "pubkey", lambda: "k")
    sf = tmp_path / "sync_state.json"
    # constructed -> stale cleared to 0
    assert _json.loads(sf.read_text())["active"] == 0
    a.handle_frame({"type": "coding_sync_start", "sync_id": "sync-1",
                    "local_path": "/l", "remote_path": "/r"})
    assert _json.loads(sf.read_text())["active"] == 1
    a.handle_frame({"type": "coding_sync_stop", "sync_id": "sync-1"})
    assert _json.loads(sf.read_text())["active"] == 0
    a.close()


def test_transcript_start_resolves_local_and_scopes_to_csid(tmp_path, monkeypatch):
    # A scoped transcript sync: the agent IGNORES the frame's local_path/ignore
    # and resolves its OWN ~/.claude/projects/<encode(device_cwd)> + scopes the
    # sync to just <csid>.jsonl (server can't compute the Mac's realpath).
    from jc_client.coding_discover import _encode_project_dir
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path))  # projects under tmp
    sent = []
    runner = FakeRunner()
    a = _agent(runner, sent)
    monkeypatch.setattr(a, "pubkey", lambda: "ssh-ed25519 AAAA jc")
    device_cwd = str(tmp_path / "proj")
    a.handle_frame({"type": "coding_sync_start", "sync_id": "sync-tx-1",
                    "local_path": "~/.claude/projects/WRONG",  # must be overridden
                    "remote_path": "/root/.claude/projects/enc",
                    "ignore": ["build"],                       # must be overridden
                    "transcript": {"csid": "abc-123", "device_cwd": device_cwd}})
    creates = [c for c in runner.calls if c[1:3] == ["sync", "create"]]
    assert creates, "no sync create issued"
    argv = creates[0]
    expected_local = str(tmp_path / "projects" / _encode_project_dir(device_cwd))
    assert expected_local in argv               # resolved on-device, not the frame's
    assert "WRONG" not in " ".join(argv)
    assert "jc-hermes:/root/.claude/projects/enc" in argv
    # scoped to just the one transcript file
    assert "*" in argv and "!abc-123.jsonl" in argv
    assert "build" not in argv                  # frame ignore overridden
    a.close()


def test_normal_start_expands_tilde_local(monkeypatch):
    # A non-transcript sync just expanduser-s the local path (no scoping).
    import os
    sent = []
    runner = FakeRunner()
    a = _agent(runner, sent)
    monkeypatch.setattr(a, "pubkey", lambda: "ssh-ed25519 AAAA jc")
    a.handle_frame({"type": "coding_sync_start", "sync_id": "sync-2",
                    "local_path": "~/myproj", "remote_path": "/root/p",
                    "ignore": ["build"]})
    creates = [c for c in runner.calls if c[1:3] == ["sync", "create"]]
    assert creates and os.path.expanduser("~/myproj") in creates[0]
    a.close()
