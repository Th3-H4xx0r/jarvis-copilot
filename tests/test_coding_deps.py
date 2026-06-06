from agent import coding_deps as deps


def test_ensure_tmux_present(monkeypatch):
    monkeypatch.setattr(deps, "_which", lambda n: "/usr/bin/tmux" if n == "tmux" else None)
    ok, detail = deps.ensure_tmux()
    assert ok and "present" in detail


def test_ensure_tmux_installs_when_missing(monkeypatch):
    state = {"installed": False}

    def fake_which(n):
        if n == "tmux":
            return "/usr/bin/tmux" if state["installed"] else None
        if n == "apt-get":
            return "/usr/bin/apt-get"
        return None

    monkeypatch.setattr(deps, "_which", fake_which)
    calls = []

    def runner(argv, env):
        calls.append(argv)
        state["installed"] = True

    ok, detail = deps.ensure_tmux(runner=runner)
    assert ok
    assert calls and "tmux" in calls[0]           # an install command ran
    assert "installed tmux" in detail


def test_ensure_tmux_no_package_manager(monkeypatch):
    monkeypatch.setattr(deps, "_which", lambda n: None)
    ok, detail = deps.ensure_tmux()
    assert not ok and "manually" in detail


def test_ensure_tmux_install_failure(monkeypatch):
    monkeypatch.setattr(deps, "_which",
                        lambda n: "/usr/bin/apt-get" if n == "apt-get" else None)

    def boom(argv, env):
        raise RuntimeError("apt locked")

    ok, detail = deps.ensure_tmux(runner=boom)
    assert not ok and "failed" in detail


def test_with_privilege_brew_not_sudoed():
    assert deps._with_privilege(["brew", "install", "tmux"])[0] == "brew"


def test_claude_status_present(monkeypatch):
    monkeypatch.setattr(deps, "_which", lambda n: "/usr/bin/claude")
    ok, detail = deps.claude_status(resolve=lambda: "claude")
    assert ok


def test_claude_status_missing(monkeypatch):
    monkeypatch.setattr(deps, "_which", lambda n: None)
    ok, detail = deps.claude_status(resolve=lambda: "claude")
    assert not ok and "claude" in detail
