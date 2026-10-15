"""jc-hook for the other coding agents (after coucou): each one's own hook
file or plugin, written with the same care as Claude Code's settings."""
import json
import os
import time

import pytest

from jc_client import hook_install as hi

CMD = '"/py" -I "/bin/jc-hook"'


@pytest.fixture
def home(tmp_path):
    return str(tmp_path)


def read(home, rel):
    with open(os.path.join(home, rel)) as f:
        return json.load(f)


def commands(groups):
    out = []
    for g in groups:
        for h in g.get("hooks", [g]):
            out.append(h.get("command") or h.get("bash"))
    return out


def test_agents_are_listed():
    assert {"codex", "gemini", "antigravity", "copilot", "muse", "opencode", "amp"} <= set(hi.OTHER_AGENTS)


def test_codex_hooks_keep_foreign_entries(home):
    path = os.path.join(home, ".codex", "hooks.json")
    os.makedirs(os.path.dirname(path))
    with open(path, "w") as f:
        json.dump({"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}}, f)
    hi.install_agent("codex", CMD, home=home)
    obj = read(home, ".codex/hooks.json")
    assert "say done" in commands(obj["hooks"]["Stop"])
    assert f"{CMD} --agent codex" in commands(obj["hooks"]["Stop"])
    perm = [h for g in obj["hooks"]["PermissionRequest"] for h in g["hooks"]][0]
    assert perm["timeout"] == 120 and perm["statusMessage"]
    hi.uninstall_agent("codex", home=home)
    assert read(home, ".codex/hooks.json")["hooks"] == {
        "Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}


def test_gemini_uses_its_event_names_and_ms(home):
    hi.install_agent("gemini", CMD, home=home)
    obj = read(home, ".gemini/settings.json")
    g = obj["hooks"]["BeforeTool"][0]
    assert g["matcher"] == "*"
    assert g["hooks"][0]["command"] == f"{CMD} --agent gemini PreToolUse"
    assert g["hooks"][0]["timeout"] == 5000
    assert "AfterModel" not in obj["hooks"]  # fires per chunk: never installed


def test_antigravity_gets_its_own_namespace(home):
    path = os.path.join(home, ".gemini", "config", "hooks.json")
    os.makedirs(os.path.dirname(path))
    with open(path, "w") as f:
        json.dump({"other": {"Stop": []}}, f)
    hi.install_agent("antigravity", CMD, home=home)
    obj = read(home, ".gemini/config/hooks.json")
    assert obj["other"] == {"Stop": []}
    assert obj["jarvis"]["PreToolUse"][0]["matcher"] == "*"
    assert obj["jarvis"]["Stop"][0]["command"] == f"{CMD} --agent antigravity Stop"
    hi.uninstall_agent("antigravity", home=home)
    assert "jarvis" not in read(home, ".gemini/config/hooks.json")


def test_copilot_owns_its_file_with_bash_entries(home):
    hi.install_agent("copilot", CMD, home=home)
    obj = read(home, ".copilot/hooks/jarvis.json")
    assert obj["version"] == 1
    entry = obj["hooks"]["permissionRequest"][0]
    assert entry["bash"] == f"{CMD} --agent copilot permissionRequest" and entry["timeoutSec"] == 120
    hi.uninstall_agent("copilot", home=home)
    assert not os.path.exists(os.path.join(home, ".copilot/hooks/jarvis.json"))


def test_muse_timeouts_in_ms(home):
    hi.install_agent("muse", CMD, home=home)
    obj = read(home, ".config/muse/settings.json")
    h = obj["hooks"]["PermissionRequest"][0]["hooks"][0]
    assert h["timeout"] == 120_000 and h["command"].endswith("--agent muse PermissionRequest")


def test_plugins_are_files_of_their_own(home):
    hi.install_agent("opencode", CMD, home=home, python="/py", script="/bin/jc-hook")
    js = open(os.path.join(home, ".config/opencode/plugins/jarvis.js")).read()
    assert "'/py'" in js and "'/bin/jc-hook'" in js and "tool.execute.before" in js
    hi.install_agent("amp", CMD, home=home, python="/py", script="/bin/jc-hook")
    ts = open(os.path.join(home, ".config/amp/plugins/jarvis.ts")).read()
    assert "action: 'allow'" in ts
    assert hi.agent_status("amp", home=home)["installed"] is True
    hi.uninstall_agent("amp", home=home)
    assert hi.agent_status("amp", home=home)["installed"] is False


def test_install_is_idempotent(home):
    hi.install_agent("gemini", CMD, home=home)
    first = open(os.path.join(home, ".gemini/settings.json")).read()
    hi.install_agent("gemini", CMD, home=home)
    assert open(os.path.join(home, ".gemini/settings.json")).read() == first


def test_unknown_shape_is_refused(home):
    path = os.path.join(home, ".gemini", "settings.json")
    os.makedirs(os.path.dirname(path))
    with open(path, "w") as f:
        json.dump({"hooks": "nope"}, f)
    with pytest.raises(hi.SettingsShape):
        hi.install_agent("gemini", CMD, home=home)


def test_cli_installs_and_reports_another_agent(tmp_path, monkeypatch, capsys):
    import argparse
    from jc_client import cli
    monkeypatch.setattr(cli, "_hooks_home", lambda: str(tmp_path))
    monkeypatch.setattr(cli, "_hooks_bin_dir", lambda: str(tmp_path / "bin"))
    monkeypatch.setattr(cli, "_hooks_settings_path", lambda: str(tmp_path / ".claude" / "settings.json"))
    ns = argparse.Namespace(hooks_command="install", yes=True, agent="codex", no_statusline=False)
    assert cli.cmd_hooks(ns) == 0
    assert os.path.exists(tmp_path / "bin" / "jc-hook")
    assert "--agent codex" in (tmp_path / ".codex" / "hooks.json").read_text()
    assert not (tmp_path / ".claude" / "settings.json").exists()  # Claude Code untouched
    capsys.readouterr()
    assert cli.cmd_hooks(argparse.Namespace(hooks_command="status", agent="all")) == 0
    report = json.loads(capsys.readouterr().out)
    assert report["codex"]["installed"] is True and report["gemini"]["installed"] is False
    assert "claude" in report
    assert cli.cmd_hooks(argparse.Namespace(hooks_command="uninstall", agent="codex")) == 0
    assert "jc-hook" not in (tmp_path / ".codex" / "hooks.json").read_text()


CLAUDE_NAMES = {"SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                "PermissionRequest", "Stop", "SubagentStart", "SubagentStop", "Interrupt",
                "Notification"}


@pytest.mark.parametrize("agent", ["codex", "gemini", "muse", "antigravity", "copilot"])
def test_every_installed_command_reaches_jarvis_normalised(agent, home, tmp_path):
    """Run each command we install through the real relay: the frame names the
    agent and carries an event Jarvis understands."""
    import shlex
    import socket as so
    import threading
    from jc_client.hook_relay import jc_hook

    sock_path = os.path.join("/tmp", f"jcag-{os.getpid()}-{agent}.sock")
    if os.path.exists(sock_path):
        os.unlink(sock_path)
    srv = so.socket(so.AF_UNIX, so.SOCK_STREAM)
    srv.bind(sock_path)
    srv.listen(64)
    frames = []

    def serve():
        while True:
            try:
                c, _ = srv.accept()
            except OSError:
                return
            buf = b""
            while b"\n" not in buf:
                chunk = c.recv(65536)
                if not chunk:
                    break
                buf += chunk
            frames.append(json.loads(buf.split(b"\n", 1)[0]))
            c.close()

    threading.Thread(target=serve, daemon=True).start()
    try:
        hi.install_agent(agent, hi.command_base("/py", "/bin/jc-hook", socket=sock_path), home=home)
        text = open(hi.agent_path(agent, home)).read()
        cmds = [json.loads(json.dumps(c)) for c in _all_commands(json.loads(text))]
        assert cmds
        for cmd in cmds:
            argv = shlex.split(cmd)[3:]          # after "/py" -I "/bin/jc-hook"
            if "PermissionRequest" in cmd or "permissionRequest" in cmd:
                continue                          # blocking kind: covered in test_jc_hook
            # Codex (like Claude Code) names the event in the payload, not argv.
            body = {"session_id": "s1", "hook_event_name": "Stop"} if agent == "codex" else {"session_id": "s1"}
            jc_hook.main(argv, json.dumps(body).encode(), {})
        end = time.time() + 3
        while len(frames) < len(cmds) - 1 and time.time() < end:
            time.sleep(0.02)
        assert frames
        for f in frames:
            assert f["agent"] == agent
            assert f["payload"]["hook_event_name"] in CLAUDE_NAMES
    finally:
        srv.close()
        os.unlink(sock_path)


def _all_commands(obj):
    out = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k in ("command", "bash") and isinstance(v, str):
                out.append(v)
            else:
                out.extend(_all_commands(v))
    elif isinstance(obj, list):
        for v in obj:
            out.extend(_all_commands(v))
    return out


def test_a_symlinked_settings_file_stays_a_link(home, tmp_path):
    """Dotfiles managers (stow, chezmoi) keep settings.json as a link: write
    through it, don't replace it (sweep finding)."""
    real = tmp_path / "dotfiles" / "settings.json"
    real.parent.mkdir()
    real.write_text('{"model": "opus"}')
    link = os.path.join(home, ".claude", "settings.json")
    os.makedirs(os.path.dirname(link), exist_ok=True)
    os.symlink(real, link)
    pv = hi.preview(link, CMD, os.path.join(home, "bin"))
    hi.install(link, pv)
    assert os.path.islink(link)
    assert "jc-hook" in real.read_text()
    assert hi.uninstall(link, os.path.join(home, "bin")) is True
    assert os.path.islink(link) and "jc-hook" not in real.read_text()
    # The other agents' files too.
    gem_real = tmp_path / "dotfiles" / "gemini.json"
    gem_real.write_text("{}")
    os.makedirs(os.path.join(home, ".gemini"))
    os.symlink(gem_real, os.path.join(home, ".gemini", "settings.json"))
    hi.install_agent("gemini", CMD, home=home)
    assert os.path.islink(os.path.join(home, ".gemini", "settings.json")) and "jc-hook" in gem_real.read_text()
