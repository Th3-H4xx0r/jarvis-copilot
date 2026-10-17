"""The server's live copy of a Mac session's transcript (append-only, offset-checked)."""
from pathlib import Path

import pytest

from agent import transcript_mirror as tm


@pytest.fixture
def home(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("CLAUDE_CONFIG_DIR", raising=False)
    monkeypatch.setenv("JC_CODING_PROJECTS_ROOT", str(tmp_path / "codingprojects"))
    return tmp_path


def _conv(home):
    return {"agent": "claude", "session_id": "s1",
            "server_cwd": str(home / "codingprojects" / "app")}


def test_server_cwd_for_uses_basename(home):
    assert tm.server_cwd_for("/Users/p/code/app") == str(home / "codingprojects" / "app")


def test_paths_use_encoded_cwd(home):
    p = tm.transcript_path("claude", "s1", "/srv/my.proj")
    assert p == home / ".claude" / "projects" / "-srv-my-proj" / "s1.jsonl"
    c = tm.transcript_path("codex", "x", "/srv/a", codex_rel="2026/10/17/rollout-x.jsonl")
    assert c == home / ".codex" / "sessions" / "2026" / "10" / "17" / "rollout-x.jsonl"


def test_append_at_size_ok(home):
    conv = _conv(home)
    assert tm.append_chunk(conv, 0, b'{"uuid":"a"}\n') == (True, 13)
    assert tm.append_chunk(conv, 13, b'{"uuid":"b"}\n') == (True, 26)
    assert tm.size(conv) == 26
    assert tm.read_from(conv, 13) == b'{"uuid":"b"}\n'


def test_append_wrong_offset_rejected_returns_current_size(home):
    conv = _conv(home)
    tm.append_chunk(conv, 0, b"abc\n")
    assert tm.append_chunk(conv, 99, b"zzz\n") == (False, 4)
    assert tm.append_chunk(conv, 0, b"dup\n") == (False, 4)
    assert tm.read_from(conv, 0) == b"abc\n"


def test_partial_last_line_completed_by_next_chunk(home):
    conv = _conv(home)
    tm.append_chunk(conv, 0, b'{"uuid":"a"')
    tm.append_chunk(conv, 11, b'}\n')
    assert tm.read_from(conv, 0) == b'{"uuid":"a"}\n'


def test_replace_writes_whole_file_atomically(home):
    conv = _conv(home)
    tm.append_chunk(conv, 0, b"old\n")
    tm.replace(conv, b"new\nlines\n")
    assert tm.read_from(conv, 0) == b"new\nlines\n"
