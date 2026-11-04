"""vscode_run: open the folder in VS Code when needed, then run in its terminal."""
import os
import shutil
import tempfile

import pytest

from jc_client import vscode_bridge
from jc_client.skills import vscode


class FakeBridge:
    def __init__(self, folders=()):
        self.folders = list(folders)
        self.runs = []
        self.accept = True

    def windows(self):
        return [{"window": "w1", "folders": list(self.folders), "terminals": []}]

    def run_in_terminal(self, cwd, command, timeout=3.0):
        self.runs.append((cwd, command))
        return self.accept


@pytest.fixture
def project(tmp_path, monkeypatch):
    monkeypatch.setattr(vscode_bridge, "_current", None)
    return tmp_path


def test_runs_in_the_window_that_has_the_folder(project, monkeypatch):
    bridge = FakeBridge([str(project)])
    monkeypatch.setattr(vscode_bridge, "_current", bridge)
    opened = []
    out = vscode.vscode_run(str(project), "claude --rc", _open=opened.append)
    assert out["ok"] and out["ran"] and not out["opened_window"]
    assert opened == []
    assert bridge.runs == [(str(project), "claude --rc")]


def test_opens_the_folder_then_waits_for_its_window(project, monkeypatch):
    bridge = FakeBridge()
    monkeypatch.setattr(vscode_bridge, "_current", bridge)
    sleeps = []

    def fake_sleep(s):
        sleeps.append(s)
        bridge.folders = [str(project)]  # the new window says hello

    out = vscode.vscode_run(str(project), "npm test", _open=lambda f: None, _sleep=fake_sleep)
    assert out["ok"] and out["ran"] and out["opened_window"]
    assert sleeps and bridge.runs == [(str(project), "npm test")]


def test_window_that_never_connects_is_an_error(project, monkeypatch):
    bridge = FakeBridge()
    monkeypatch.setattr(vscode_bridge, "_current", bridge)
    t = iter(range(0, 1000, 5))
    out = vscode.vscode_run(str(project), "ls", _open=lambda f: None, _sleep=lambda s: None,
                            _clock=lambda: next(t))
    assert not out["ok"] and not out["ran"]
    assert "never connected" in out["error"]
    assert bridge.runs == []


def test_no_bridge_opens_folder_but_reports_command_not_run(project):
    opened = []
    out = vscode.vscode_run(str(project), "claude --rc", _open=opened.append)
    assert opened == [str(project)]
    assert not out["ok"] and not out["ran"] and "Bridge" in out["error"]


def test_just_open_needs_no_command(project, monkeypatch):
    monkeypatch.setattr(vscode_bridge, "_current", FakeBridge([str(project)]))
    out = vscode.vscode_run(str(project), _open=lambda f: pytest.fail("already open"))
    assert out == {"ok": True, "opened_window": False, "ran": False, "folder": str(project)}


def test_subfolder_of_an_open_window_counts(project, monkeypatch):
    sub = project / "app"
    sub.mkdir()
    bridge = FakeBridge([str(project)])
    monkeypatch.setattr(vscode_bridge, "_current", bridge)
    out = vscode.vscode_run(str(sub), "make", _open=lambda f: pytest.fail("already open"))
    assert out["ran"] and bridge.runs == [(str(sub), "make")]


@pytest.mark.parametrize("bad", ["", "relative/path", "/no/such/folder/xyz"])
def test_bad_folder_is_refused(project, bad):
    with pytest.raises(ValueError):
        vscode.vscode_run(bad, "ls", _open=lambda f: pytest.fail("must not open"))


def test_bridge_start_and_stop_set_current():
    # UNIX socket paths are length-capped: tmp_path is too long on macOS.
    d = tempfile.mkdtemp(dir="/tmp", prefix="jvr")
    b = vscode_bridge.VSCodeBridge(os.path.join(d, "v.sock"))
    b.start()
    try:
        assert vscode_bridge.current() is b
    finally:
        b.stop()
        shutil.rmtree(d, ignore_errors=True)
    assert vscode_bridge.current() is None
