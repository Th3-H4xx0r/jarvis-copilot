"""Typing a phone message into the terminal that runs the session — no tmux."""
from jc_client import instruction_delivery as idl


class FakeVSCode:
    def __init__(self):
        self.sent = []

    def terminal_pid_for(self, pid):
        return 500 if pid == 501 else None

    def send_text(self, shell_pid, text, timeout=3.0):
        self.sent.append((shell_pid, text))
        return True


def test_vscode_types_via_bridge():
    vs = FakeVSCode()
    ok, why = idl.type_into({"term_program": "vscode"}, "run tests", pid=501, vscode=vs,
                            run=lambda argv: 1)
    assert ok and why == "typed into VS Code" and vs.sent == [(500, "run tests")]


def test_vscode_without_window_reports_it():
    ok, why = idl.type_into({"term_program": "vscode"}, "x", pid=999, vscode=FakeVSCode(),
                            run=lambda argv: 1)
    assert not ok and "VS Code" in why


def test_iterm_unchanged():
    calls = []
    ok, why = idl.type_into({"iterm": "w0t0p0:ABC"}, "hi", run=lambda argv: calls.append(argv) or 0)
    assert ok and why == "typed into iTerm" and calls[0][-2:] == ["ABC", "hi"]


def test_no_tmux_path():
    ok, why = idl.type_into({"tmux_pane": "%1", "tmux": "x"}, "hi", run=lambda argv: 0)
    assert not ok and why == "can't type into this terminal"
    assert "tmux" not in open(idl.__file__).read().split('"""', 2)[2]
