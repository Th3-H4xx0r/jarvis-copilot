"""The hooks the server gives the Claude sessions it starts."""
import json

from agent.agent_engine_shim import load_hook_install
from agent.server_hooks import write_hook_settings


def test_hook_settings_cover_every_claude_event(tmp_path):
    p = write_hook_settings(str(tmp_path / "claude-hooks.json"), socket="/run/jc/agent-hook.sock",
                            python="/usr/bin/python3")
    data = json.loads(open(p).read())
    for event, _ in load_hook_install().CLAUDE_EVENTS:
        cmds = [h["command"] for g in data["hooks"][event] for h in g["hooks"]]
        assert any('--socket "/run/jc/agent-hook.sock"' in c and c.startswith('"/usr/bin/python3" -I')
                   for c in cmds), event
    ask = [g for g in data["hooks"]["PreToolUse"] if g.get("matcher") == "AskUserQuestion"]
    assert ask and ask[0]["hooks"][0]["command"].endswith("--ask")
    assert "statusLine" not in data


def test_writing_them_again_changes_nothing(tmp_path):
    p = str(tmp_path / "claude-hooks.json")
    write_hook_settings(p, socket="/s", python="/p")
    first = open(p).read()
    write_hook_settings(p, socket="/s", python="/p")
    assert open(p).read() == first
