from agent.coding_session_manager import CodingSessionManager
from agent.coding_session_db import CodingSessionStore


class FakeDriver:
    name = "server"

    def __init__(self):
        self.calls = []

    def subprocess_env(self):
        return {"HOME": "/home/x"}

    def tmux_new_argv(self, *, tmux_name, cwd):
        return ["tmux", "new-session", "-d", "-s", tmux_name, "-c", cwd]

    def claude_launch_command(self, **k):
        return "claude --model opus"

    def send_message_argvs(self, *, tmux_name, text):
        return [["tmux", "send-keys", "-t", tmux_name, "-l", text],
                ["tmux", "send-keys", "-t", tmux_name, "Enter"]]

    def _run(self, argv):
        self.calls.append(argv)
        return None


def _mgr(tmp_path):
    store = CodingSessionStore(db_path=str(tmp_path / "c.db"))
    drv = FakeDriver()
    mgr = CodingSessionManager(
        store=store, driver=drv,
        plugin_dir="/repo/plugins/jarviscopilot-code-assist",
        memory_loader=lambda: ("mem", "usr"))
    return mgr, drv


def test_launch_creates_session_and_runs_tmux(tmp_path):
    mgr, drv = _mgr(tmp_path)
    s = mgr.launch(cwd=str(tmp_path), title="t", initial_prompt="do x", model="opus")
    assert s["status"] in ("starting", "running")
    assert s["cwd"] == str(tmp_path)
    assert any(c[0] == "tmux" for c in drv.calls)
    ctx = tmp_path / "JARVIS-CONTEXT.md"
    assert ctx.exists()
    assert "mem" in ctx.read_text()


def test_send_message_issues_send_keys(tmp_path):
    mgr, drv = _mgr(tmp_path)
    s = mgr.launch(cwd=str(tmp_path), title="t", initial_prompt=None, model=None)
    drv.calls.clear()
    mgr.send_message(s["id"], "run the tests")
    assert ["tmux", "send-keys", "-t", s["tmux_name"], "Enter"] in drv.calls


def test_list_and_stop(tmp_path):
    mgr, drv = _mgr(tmp_path)
    s = mgr.launch(cwd=str(tmp_path), title="t", initial_prompt=None, model=None)
    assert any(r["id"] == s["id"] for r in mgr.list())
    mgr.stop(s["id"])
    assert mgr.status(s["id"])["status"] == "stopped"
