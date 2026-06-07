"""Tests for the desktop coding-sync agent (jc_client.coding_sync_agent).

No networking: a fake ``send`` collects emitted frames into a list. The polling
watcher is ticked deterministically via the underscore-public ``_poll_once`` so
tests don't sleep on the real interval.

Run from the ``desktop_client`` directory:
    python3 -m pytest jc_client/test_coding_sync_agent.py -q
"""

import base64
import hashlib
import json

import pytest

from jc_client.coding_sync_agent import (
    CodingSyncAgent,
    build_manifest,
    safe_join,
)


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class FakeSender:
    """Collects emitted frames; lets tests query by type."""

    def __init__(self):
        self.frames = []

    def __call__(self, frame: dict) -> None:
        self.frames.append(frame)

    def of_type(self, t: str):
        return [f for f in self.frames if f.get("type") == t]

    def clear(self):
        self.frames.clear()


@pytest.fixture
def sender():
    return FakeSender()


@pytest.fixture
def agent(sender):
    # Long poll interval: tests tick _poll_once manually, so the background
    # thread effectively never fires on its own during the test.
    # state_path=None disables the cross-process sync state file so these
    # tests don't write to the real ~/.jarviscopilot-client/ dir. The
    # state-file behaviour is covered separately with an explicit tmp path.
    a = CodingSyncAgent(sender, poll_interval=3600, state_path=None)
    yield a
    a.close()


# --------------------------------------------------------------------------- #
# coding_sync_open
# --------------------------------------------------------------------------- #
def test_open_returns_manifest_for_dir_with_files(tmp_path, agent, sender):
    (tmp_path / "src").mkdir()
    (tmp_path / "src" / "app.py").write_bytes(b"print('hi')\n")
    (tmp_path / "README.md").write_bytes(b"# hi\n")

    agent.handle_frame({
        "type": "coding_sync_open",
        "sync_id": "s1",
        "path": str(tmp_path),
    })

    msgs = sender.of_type("coding_sync_manifest")
    assert len(msgs) == 1
    man = msgs[0]["manifest"]
    assert msgs[0]["sync_id"] == "s1"
    assert set(man.keys()) == {"src/app.py", "README.md"}
    # Manifest entry is [size, mtime, sha256_hex].
    size, mtime, h = man["README.md"]
    assert size == len(b"# hi\n")
    assert h == _sha(b"# hi\n")


def test_open_honors_ignore_rules(tmp_path, agent, sender):
    (tmp_path / ".git").mkdir()
    (tmp_path / ".git" / "config").write_bytes(b"x")
    (tmp_path / "keep.txt").write_bytes(b"y")

    agent.handle_frame({
        "type": "coding_sync_open",
        "sync_id": "s1",
        "path": str(tmp_path),
        "ignore": [".git"],
    })

    man = sender.of_type("coding_sync_manifest")[0]["manifest"]
    assert set(man.keys()) == {"keep.txt"}


def test_open_missing_dir_returns_empty_manifest(tmp_path, agent, sender):
    missing = tmp_path / "does-not-exist"
    agent.handle_frame({
        "type": "coding_sync_open",
        "sync_id": "s1",
        "path": str(missing),
    })

    msgs = sender.of_type("coding_sync_manifest")
    assert len(msgs) == 1
    assert msgs[0]["manifest"] == {}
    # The rule says: do NOT create the folder.
    assert not missing.exists()


def test_open_empty_dir_returns_empty_manifest(tmp_path, agent, sender):
    empty = tmp_path / "empty"
    empty.mkdir()
    agent.handle_frame({
        "type": "coding_sync_open",
        "sync_id": "s1",
        "path": str(empty),
    })
    assert sender.of_type("coding_sync_manifest")[0]["manifest"] == {}


# --------------------------------------------------------------------------- #
# coding_sync_get / coding_sync_file / coding_sync_rm
# --------------------------------------------------------------------------- #
def _open(agent, sync_id, path):
    agent.handle_frame({
        "type": "coding_sync_open", "sync_id": sync_id, "path": str(path),
    })


def test_get_returns_correct_base64(tmp_path, agent, sender):
    content = b"hello \x00 world\n\xff"
    (tmp_path / "f.bin").write_bytes(content)
    _open(agent, "s1", tmp_path)
    sender.clear()

    agent.handle_frame({
        "type": "coding_sync_get", "sync_id": "s1", "relpath": "f.bin",
    })

    msgs = sender.of_type("coding_sync_file")
    assert len(msgs) == 1
    assert msgs[0]["relpath"] == "f.bin"
    assert base64.b64decode(msgs[0]["b64"]) == content


def test_file_writes_decoded_bytes(tmp_path, agent, sender):
    _open(agent, "s1", tmp_path)
    content = b"written by server\n"
    agent.handle_frame({
        "type": "coding_sync_file",
        "sync_id": "s1",
        "relpath": "sub/new.txt",
        "b64": base64.b64encode(content).decode("ascii"),
    })
    assert (tmp_path / "sub" / "new.txt").read_bytes() == content


def test_rm_deletes_file(tmp_path, agent, sender):
    (tmp_path / "gone.txt").write_bytes(b"x")
    _open(agent, "s1", tmp_path)
    agent.handle_frame({
        "type": "coding_sync_rm", "sync_id": "s1", "relpath": "gone.txt",
    })
    assert not (tmp_path / "gone.txt").exists()


def test_rm_missing_file_is_noop(tmp_path, agent, sender):
    _open(agent, "s1", tmp_path)
    # Should not raise / emit no error.
    agent.handle_frame({
        "type": "coding_sync_rm", "sync_id": "s1", "relpath": "nope.txt",
    })
    assert sender.of_type("coding_sync_error") == []


def test_get_on_unknown_sync_is_noop(tmp_path, agent, sender):
    agent.handle_frame({
        "type": "coding_sync_get", "sync_id": "ghost", "relpath": "a.txt",
    })
    assert sender.frames == []


# --------------------------------------------------------------------------- #
# safe_join rejects traversal / escapes
# --------------------------------------------------------------------------- #
def test_safe_join_rejects_parent_escape(tmp_path):
    with pytest.raises(ValueError):
        safe_join(str(tmp_path), "../escape.txt")


def test_safe_join_rejects_absolute(tmp_path):
    with pytest.raises(ValueError):
        safe_join(str(tmp_path), "/etc/passwd")


def test_safe_join_rejects_nul(tmp_path):
    with pytest.raises(ValueError):
        safe_join(str(tmp_path), "a\x00b")


def test_get_with_traversal_emits_error_not_crash(tmp_path, agent, sender):
    _open(agent, "s1", tmp_path)
    sender.clear()
    agent.handle_frame({
        "type": "coding_sync_get", "sync_id": "s1", "relpath": "../../../etc/passwd",
    })
    # No file frame; a structured error instead, and definitely no crash.
    assert sender.of_type("coding_sync_file") == []
    errs = sender.of_type("coding_sync_error")
    assert len(errs) == 1
    assert errs[0]["op"] == "coding_sync_get"


def test_file_with_traversal_does_not_write_outside(tmp_path, agent, sender):
    _open(agent, "s1", tmp_path)
    agent.handle_frame({
        "type": "coding_sync_file",
        "sync_id": "s1",
        "relpath": "../evil.txt",
        "b64": base64.b64encode(b"pwned").decode("ascii"),
    })
    assert not (tmp_path.parent / "evil.txt").exists()
    assert sender.of_type("coding_sync_error")[0]["op"] == "coding_sync_file"


# --------------------------------------------------------------------------- #
# polling watcher: create / modify / delete events
# --------------------------------------------------------------------------- #
def test_watcher_detects_create(tmp_path, agent, sender):
    _open(agent, "s1", tmp_path)
    sender.clear()

    (tmp_path / "added.txt").write_bytes(b"new")
    agent._poll_once("s1")

    evts = sender.of_type("coding_sync_event")
    assert len(evts) == 1
    assert evts[0] == {
        "type": "coding_sync_event", "sync_id": "s1",
        "relpath": "added.txt", "kind": "create",
    }


def test_watcher_detects_modify(tmp_path, agent, sender):
    f = tmp_path / "m.txt"
    f.write_bytes(b"v1")
    _open(agent, "s1", tmp_path)
    sender.clear()

    f.write_bytes(b"v2-different-content")
    agent._poll_once("s1")

    evts = sender.of_type("coding_sync_event")
    assert len(evts) == 1
    assert evts[0]["relpath"] == "m.txt"
    assert evts[0]["kind"] == "modify"


def test_watcher_detects_delete(tmp_path, agent, sender):
    f = tmp_path / "d.txt"
    f.write_bytes(b"bye")
    _open(agent, "s1", tmp_path)
    sender.clear()

    f.unlink()
    agent._poll_once("s1")

    evts = sender.of_type("coding_sync_event")
    assert len(evts) == 1
    assert evts[0]["relpath"] == "d.txt"
    assert evts[0]["kind"] == "delete"


def test_watcher_honors_ignore_rules(tmp_path, agent, sender):
    _open(agent, "s1", tmp_path)  # default ignores include __pycache__/*.pyc
    sender.clear()

    (tmp_path / "__pycache__").mkdir()
    (tmp_path / "__pycache__" / "x.pyc").write_bytes(b"bytecode")
    (tmp_path / "real.py").write_bytes(b"code")
    agent._poll_once("s1")

    evts = sender.of_type("coding_sync_event")
    rels = {e["relpath"] for e in evts}
    assert rels == {"real.py"}


def test_watcher_no_events_when_unchanged(tmp_path, agent, sender):
    (tmp_path / "stable.txt").write_bytes(b"same")
    _open(agent, "s1", tmp_path)
    sender.clear()

    agent._poll_once("s1")
    assert sender.of_type("coding_sync_event") == []


def test_server_write_does_not_echo_as_event(tmp_path, agent, sender):
    """A server-driven coding_sync_file write must not bounce back as a
    create/modify event on the next poll (no feedback loop)."""
    _open(agent, "s1", tmp_path)
    agent.handle_frame({
        "type": "coding_sync_file",
        "sync_id": "s1",
        "relpath": "fromserver.txt",
        "b64": base64.b64encode(b"data").decode("ascii"),
    })
    sender.clear()

    agent._poll_once("s1")
    assert sender.of_type("coding_sync_event") == []


def test_server_delete_does_not_echo_as_event(tmp_path, agent, sender):
    (tmp_path / "x.txt").write_bytes(b"x")
    _open(agent, "s1", tmp_path)
    agent.handle_frame({
        "type": "coding_sync_rm", "sync_id": "s1", "relpath": "x.txt",
    })
    sender.clear()

    agent._poll_once("s1")
    assert sender.of_type("coding_sync_event") == []


def test_close_stops_watching(tmp_path, agent, sender):
    _open(agent, "s1", tmp_path)
    agent.handle_frame({"type": "coding_sync_close", "sync_id": "s1"})
    sender.clear()

    (tmp_path / "after-close.txt").write_bytes(b"z")
    # Sync is gone → poll is a no-op, emits nothing.
    agent._poll_once("s1")
    assert sender.frames == []


# --------------------------------------------------------------------------- #
# active_count / active_syncs (tray status surface)
# --------------------------------------------------------------------------- #
def test_active_count_zero_initially(agent):
    assert agent.active_count() == 0
    assert agent.active_syncs() == []


def test_active_count_tracks_open_syncs(tmp_path, agent):
    a = tmp_path / "a"
    b = tmp_path / "b"
    a.mkdir()
    b.mkdir()

    _open(agent, "s1", a)
    assert agent.active_count() == 1
    assert agent.active_syncs() == ["s1"]

    _open(agent, "s2", b)
    assert agent.active_count() == 2
    assert set(agent.active_syncs()) == {"s1", "s2"}


def test_active_count_drops_on_close(tmp_path, agent):
    _open(agent, "s1", tmp_path)
    assert agent.active_count() == 1
    agent.handle_frame({"type": "coding_sync_close", "sync_id": "s1"})
    assert agent.active_count() == 0
    assert agent.active_syncs() == []


def test_reopening_same_sync_id_counts_once(tmp_path, agent):
    _open(agent, "s1", tmp_path)
    _open(agent, "s1", tmp_path)  # re-open replaces, doesn't double-count
    assert agent.active_count() == 1


def test_active_syncs_returns_independent_copy(tmp_path, agent):
    _open(agent, "s1", tmp_path)
    snap = agent.active_syncs()
    snap.append("mutated")
    # mutating the returned list must not affect the agent's state
    assert agent.active_count() == 1
    assert agent.active_syncs() == ["s1"]


# --------------------------------------------------------------------------- #
# defensiveness
# --------------------------------------------------------------------------- #
def test_handle_frame_never_raises_on_garbage(agent, sender):
    for bad in [None, 42, "string", [], {"type": "coding_sync_open"},
                {"type": "unknown"}, {}]:
        agent.handle_frame(bad)  # must not raise


def test_send_failure_does_not_propagate(tmp_path):
    def boom(frame):
        raise RuntimeError("connection closed")

    a = CodingSyncAgent(boom, poll_interval=3600, state_path=None)
    try:
        # open builds a manifest then tries to send → send raises internally,
        # must be swallowed.
        a.handle_frame({
            "type": "coding_sync_open", "sync_id": "s1", "path": str(tmp_path),
        })
    finally:
        a.close()


# --------------------------------------------------------------------------- #
# cross-process "syncing" indicator: is_syncing() + sync_state.json
# --------------------------------------------------------------------------- #
@pytest.fixture
def state_file(tmp_path):
    return tmp_path / "sync_state.json"


@pytest.fixture
def state_agent(sender, state_file):
    """Agent that writes its sync-state file into a tmp path (not the real
    ~/.jarviscopilot-client/). Manual _poll_once ticking via poll_interval."""
    a = CodingSyncAgent(sender, poll_interval=3600, state_path=str(state_file))
    yield a
    a.close()


def test_is_syncing_false_before_any_transfer(state_agent):
    assert state_agent.is_syncing(now=1000.0) is False


def test_is_syncing_window_logic(state_agent):
    # Simulate a transfer at t=100.
    state_agent._last_transfer_at = 100.0
    # Inside the default 2.5s window → syncing.
    assert state_agent.is_syncing(now=100.0) is True
    assert state_agent.is_syncing(now=102.0) is True
    # On the boundary / past the window → not syncing.
    assert state_agent.is_syncing(now=102.5) is False
    assert state_agent.is_syncing(now=105.0) is False
    # Custom window is honoured.
    assert state_agent.is_syncing(now=104.0, window=5.0) is True


def test_state_file_written_on_transfer_with_shape(tmp_path, state_agent,
                                                   state_file):
    _open(state_agent, "s1", tmp_path)
    # A server-driven write is a transfer → must flush the state file.
    state_agent.handle_frame({
        "type": "coding_sync_file",
        "sync_id": "s1",
        "relpath": "a.txt",
        "b64": base64.b64encode(b"data").decode("ascii"),
    })

    assert state_file.exists()
    data = json.loads(state_file.read_text())
    # Exact schema: four keys, the right types/values.
    assert set(data.keys()) == {"last_transfer_at", "active", "done", "total"}
    assert isinstance(data["last_transfer_at"], (int, float))
    assert data["last_transfer_at"] > 0
    assert data["active"] == 1  # one open sync
    # No progress frame yet → aggregate done/total are zero.
    assert data["done"] == 0
    assert data["total"] == 0


def test_state_file_writes_are_throttled(tmp_path, state_agent, state_file):
    _open(state_agent, "s1", tmp_path)
    # First transfer flushes the file.
    state_agent._touch_sync_state()
    assert state_file.exists()
    first = json.loads(state_file.read_text())["last_transfer_at"]

    # A rapid burst within the throttle window must NOT rewrite the file, even
    # though _last_transfer_at advances in memory (is_syncing stays accurate).
    for _ in range(50):
        state_agent._touch_sync_state()
    second = json.loads(state_file.read_text())["last_transfer_at"]
    assert second == first  # disk value unchanged → throttled
    # In-memory transfer time still advanced past the on-disk value.
    assert state_agent._last_transfer_at >= first


def test_close_clears_state_file(tmp_path, sender, state_file):
    a = CodingSyncAgent(sender, poll_interval=3600, state_path=str(state_file))
    _open(a, "s1", tmp_path)
    a._touch_sync_state()
    assert json.loads(state_file.read_text())["last_transfer_at"] > 0

    a.close()
    cleared = json.loads(state_file.read_text())
    assert cleared == {"last_transfer_at": 0, "active": 0, "done": 0, "total": 0}


def test_state_file_disabled_when_path_none(tmp_path, sender):
    a = CodingSyncAgent(sender, poll_interval=3600, state_path=None)
    try:
        _open(a, "s1", tmp_path)
        a._touch_sync_state()  # must be a no-op, no crash, no file
    finally:
        a.close()


# --------------------------------------------------------------------------- #
# coding_sync_progress: server-pushed transfer progress (done/total) → state file
# --------------------------------------------------------------------------- #
def test_progress_frame_updates_done_total_and_state_file(tmp_path, state_agent,
                                                          state_file):
    _open(state_agent, "s1", tmp_path)
    state_agent.handle_frame({
        "type": "coding_sync_progress", "sync_id": "s1",
        "done": 3, "total": 10,
    })
    # In-memory per-sync progress recorded.
    assert state_agent._progress["s1"] == (3, 10)
    assert state_agent._aggregate_progress() == (3, 10)
    # ...and flushed to the state file (schema now has done/total).
    data = json.loads(state_file.read_text())
    assert set(data.keys()) == {"last_transfer_at", "active", "done", "total"}
    assert data["done"] == 3
    assert data["total"] == 10
    assert data["last_transfer_at"] > 0


def test_progress_latest_value_replaces_prior(tmp_path, state_agent, state_file):
    _open(state_agent, "s1", tmp_path)
    state_agent.handle_frame({
        "type": "coding_sync_progress", "sync_id": "s1", "done": 1, "total": 4,
    })
    # A later snapshot for the same sync replaces (does not accumulate).
    state_agent.handle_frame({
        "type": "coding_sync_progress", "sync_id": "s1", "done": 4, "total": 4,
    })
    assert state_agent._progress["s1"] == (4, 4)
    assert state_agent._aggregate_progress() == (4, 4)


def test_progress_aggregates_across_two_sync_ids(tmp_path, state_agent):
    a = tmp_path / "a"
    b = tmp_path / "b"
    a.mkdir()
    b.mkdir()
    _open(state_agent, "s1", a)
    _open(state_agent, "s2", b)

    state_agent.handle_frame({
        "type": "coding_sync_progress", "sync_id": "s1", "done": 2, "total": 5,
    })
    state_agent.handle_frame({
        "type": "coding_sync_progress", "sync_id": "s2", "done": 3, "total": 7,
    })
    # Aggregate = summed done / summed total across both syncs.
    assert state_agent._aggregate_progress() == (5, 12)


def test_progress_dropped_when_sync_closes(tmp_path, state_agent):
    a = tmp_path / "a"
    b = tmp_path / "b"
    a.mkdir()
    b.mkdir()
    _open(state_agent, "s1", a)
    _open(state_agent, "s2", b)
    state_agent.handle_frame({
        "type": "coding_sync_progress", "sync_id": "s1", "done": 2, "total": 5,
    })
    state_agent.handle_frame({
        "type": "coding_sync_progress", "sync_id": "s2", "done": 3, "total": 7,
    })
    # Closing s1 removes its contribution from the aggregate.
    state_agent.handle_frame({"type": "coding_sync_close", "sync_id": "s1"})
    assert "s1" not in state_agent._progress
    assert state_agent._aggregate_progress() == (3, 7)


def test_progress_ignored_without_sync_id(tmp_path, state_agent):
    state_agent.handle_frame({
        "type": "coding_sync_progress", "done": 1, "total": 2,
    })
    assert state_agent._progress == {}
    assert state_agent._aggregate_progress() == (0, 0)


def test_close_zeroes_done_total_in_state_file(tmp_path, sender, state_file):
    a = CodingSyncAgent(sender, poll_interval=3600, state_path=str(state_file))
    _open(a, "s1", tmp_path)
    a.handle_frame({
        "type": "coding_sync_progress", "sync_id": "s1", "done": 5, "total": 9,
    })
    assert json.loads(state_file.read_text())["total"] == 9

    a.close()
    cleared = json.loads(state_file.read_text())
    assert cleared == {"last_transfer_at": 0, "active": 0, "done": 0, "total": 0}
    # In-memory progress is cleared too.
    assert a._progress == {}
