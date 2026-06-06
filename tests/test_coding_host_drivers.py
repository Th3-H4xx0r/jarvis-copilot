from agent.coding_host_drivers import LocalDriver


def test_tmux_new_session_argv():
    d = LocalDriver()
    argv = d.tmux_new_argv(tmux_name="jc-abc", cwd="/repo")
    assert argv[:3] == ["tmux", "new-session", "-d"]
    assert "-s" in argv and "jc-abc" in argv
    assert "-c" in argv and "/repo" in argv


def test_claude_launch_command_has_plugin_and_context():
    d = LocalDriver()
    cmd = d.claude_launch_command(
        plugin_dir="/repo/plugins/jarviscopilot-code-assist",
        context_file="JARVIS-CONTEXT.md", model="opus", initial_prompt=None)
    assert cmd.startswith("claude ")
    assert "--plugin-dir /repo/plugins/jarviscopilot-code-assist" in cmd
    assert "--append-system-prompt-file JARVIS-CONTEXT.md" in cmd
    assert "--model opus" in cmd
    # NOT the crippled inference-shim flags
    assert '--tools ""' not in cmd
    assert "--no-session-persistence" not in cmd


def test_claude_launch_command_quotes_initial_prompt():
    d = LocalDriver()
    cmd = d.claude_launch_command(
        plugin_dir="/p", context_file="JARVIS-CONTEXT.md",
        model=None, initial_prompt="fix the failing tests")
    # the free-text prompt must be shell-quoted as a single argument
    assert "'fix the failing tests'" in cmd


def test_send_keys_argv_is_literal_then_enter():
    d = LocalDriver()
    seq = d.send_message_argvs(tmux_name="jc-abc", text="run the tests")
    assert seq[0][:2] == ["tmux", "send-keys"]
    assert "-l" in seq[0] and "run the tests" in seq[0]
    assert seq[-1] == ["tmux", "send-keys", "-t", "jc-abc", "Enter"]


def test_subprocess_env_scrubs_api_key(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-should-be-removed")
    d = LocalDriver()
    env = d.subprocess_env()
    assert "ANTHROPIC_API_KEY" not in env
    assert env.get("HOME")
