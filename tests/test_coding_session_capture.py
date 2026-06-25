"""TDD tests for agent.coding_session_capture.

Captures the Claude Code session UUID by locating the newest transcript
*.jsonl that appears under ~/.claude/projects/<encoded cwd>/ after a launch.

Encoding rule under test: replace every "/" with "-" AND every "." with "-".
"""

import os

import pytest

from agent import coding_session_capture as csc


# --------------------------------------------------------------------------- #
# encode_project_dir
# --------------------------------------------------------------------------- #
def test_encode_project_dir_simple():
    assert csc.encode_project_dir("/Users/jane/my-project") == "-Users-jane-my-project"


def test_encode_project_dir_leading_dot_dir():
    # A leading-dot dir like ".config": the "/." run becomes "--".
    # Use a non-existent root so realpath() is identity on every platform
    # (encode_project_dir realpaths first; /home is a firmlink on macOS).
    assert csc.encode_project_dir("/jcroot/x/.config/app") == "-jcroot-x--config-app"


def test_encode_project_dir_dot_in_name():
    # Slash->dash AND dot->dash: "/a/b.c" -> "-a-b-c".
    assert csc.encode_project_dir("/a/b.c") == "-a-b-c"


def test_encode_project_dir_dotted_project_name():
    assert csc.encode_project_dir("/Users/jane/my.proj") == "-Users-jane-my-proj"


# --------------------------------------------------------------------------- #
# claude_projects_dir
# --------------------------------------------------------------------------- #
def test_claude_projects_dir_default(monkeypatch, tmp_path):
    monkeypatch.delenv("CLAUDE_CONFIG_DIR", raising=False)
    monkeypatch.setattr(csc.Path, "home", classmethod(lambda cls: tmp_path))
    assert csc.claude_projects_dir() == tmp_path / ".claude" / "projects"


def test_claude_projects_dir_honors_env(monkeypatch, tmp_path):
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path / "cfg"))
    assert csc.claude_projects_dir() == tmp_path / "cfg" / "projects"


# --------------------------------------------------------------------------- #
# claude_config_dir (single source of truth for the transcript location)
# --------------------------------------------------------------------------- #
def test_claude_config_dir_default(monkeypatch, tmp_path):
    monkeypatch.delenv("CLAUDE_CONFIG_DIR", raising=False)
    monkeypatch.setattr(csc.Path, "home", classmethod(lambda cls: tmp_path))
    assert csc.claude_config_dir() == tmp_path / ".claude"


def test_claude_config_dir_honors_env(monkeypatch, tmp_path):
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path / "cfg"))
    assert csc.claude_config_dir() == tmp_path / "cfg"


def test_projects_dir_is_config_dir_plus_projects(monkeypatch, tmp_path):
    # The reader (projects) and the launcher (config) must agree on one root.
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path / "cfg"))
    assert csc.claude_projects_dir() == csc.claude_config_dir() / "projects"


# --------------------------------------------------------------------------- #
# find_session_id
# --------------------------------------------------------------------------- #
def _make_project(tmp_path, cwd):
    """Create the encoded project dir under a fake projects_dir (tmp_path)."""
    proj = tmp_path / csc.encode_project_dir(cwd)
    proj.mkdir(parents=True, exist_ok=True)
    return proj


def _write_jsonl(proj_dir, stem, mtime):
    p = proj_dir / f"{stem}.jsonl"
    p.write_text("{}\n")
    os.utime(p, (mtime, mtime))
    return p


def test_find_session_id_returns_newest(tmp_path):
    cwd = "/Users/jane/my-project"
    proj = _make_project(tmp_path, cwd)
    since = 1_000.0
    _write_jsonl(proj, "11111111-1111-1111-1111-111111111111", since + 1.0)
    _write_jsonl(proj, "22222222-2222-2222-2222-222222222222", since + 5.0)

    got = csc.find_session_id(cwd, since, projects_dir=str(tmp_path))
    assert got == "22222222-2222-2222-2222-222222222222"


def test_find_session_id_ignores_older_than_since(tmp_path):
    cwd = "/Users/jane/my-project"
    proj = _make_project(tmp_path, cwd)
    since = 1_000.0
    # Only file is well before since (beyond the 1s grace) -> ignored.
    _write_jsonl(proj, "old-session", since - 100.0)

    assert csc.find_session_id(cwd, since, projects_dir=str(tmp_path)) is None


def test_find_session_id_grace_window(tmp_path):
    cwd = "/Users/jane/my-project"
    proj = _make_project(tmp_path, cwd)
    since = 1_000.0
    # 0.5s before since is within the 1.0s grace -> still qualifies.
    _write_jsonl(proj, "grace-session", since - 0.5)

    assert csc.find_session_id(cwd, since, projects_dir=str(tmp_path)) == "grace-session"


def test_find_session_id_missing_dir(tmp_path):
    cwd = "/Users/jane/never-launched"
    # No project dir created at all.
    assert csc.find_session_id(cwd, 1_000.0, projects_dir=str(tmp_path)) is None


def test_find_session_id_ignores_non_jsonl(tmp_path):
    cwd = "/Users/jane/my-project"
    proj = _make_project(tmp_path, cwd)
    since = 1_000.0
    # A newer non-jsonl file must be ignored; the .jsonl wins.
    other = proj / "scratch.txt"
    other.write_text("x")
    os.utime(other, (since + 99.0, since + 99.0))
    _write_jsonl(proj, "real-session", since + 1.0)

    assert csc.find_session_id(cwd, since, projects_dir=str(tmp_path)) == "real-session"


# --------------------------------------------------------------------------- #
# wait_for_session_id
# --------------------------------------------------------------------------- #
def test_wait_for_session_id_appears_after_second_poll(tmp_path):
    cwd = "/Users/jane/my-project"
    proj = _make_project(tmp_path, cwd)
    since = 1_000.0

    calls = {"n": 0}

    def fake_sleep(_interval):
        # On the first sleep (i.e. after the first failing poll), the
        # transcript "appears". The next poll should then find it.
        calls["n"] += 1
        if calls["n"] == 1:
            _write_jsonl(proj, "late-session", since + 2.0)

    got = csc.wait_for_session_id(
        cwd,
        since,
        projects_dir=str(tmp_path),
        timeout=8.0,
        interval=0.25,
        sleep=fake_sleep,
    )
    assert got == "late-session"
    # We never slept for real, and only needed one sleep before success.
    assert calls["n"] == 1


def test_wait_for_session_id_times_out(tmp_path):
    cwd = "/Users/jane/my-project"
    _make_project(tmp_path, cwd)  # dir exists but stays empty

    sleeps = {"n": 0}

    def fake_sleep(_interval):
        sleeps["n"] += 1

    got = csc.wait_for_session_id(
        cwd,
        1_000.0,
        projects_dir=str(tmp_path),
        timeout=1.0,
        interval=0.25,
        sleep=fake_sleep,
    )
    assert got is None
    # It should have polled/slept at least once and then given up.
    assert sleeps["n"] >= 1


def test_wait_for_session_id_immediate_hit_no_sleep(tmp_path):
    cwd = "/Users/jane/my-project"
    proj = _make_project(tmp_path, cwd)
    since = 1_000.0
    _write_jsonl(proj, "already-there", since + 1.0)

    sleeps = {"n": 0}

    def fake_sleep(_interval):
        sleeps["n"] += 1

    got = csc.wait_for_session_id(
        cwd, since, projects_dir=str(tmp_path), sleep=fake_sleep
    )
    assert got == "already-there"
    assert sleeps["n"] == 0  # found on first poll, never slept
