from agent.coding_memory_seed import build_context_markdown


def test_build_context_includes_memory_and_user():
    mem = "Pranav prefers direct-to-main\n§\nVoice is realtime-only"
    usr = "User is Pranav, builds JarvisCopilot"
    md = build_context_markdown(memory_text=mem, user_text=usr,
                                project_name="jarvis", task="fix the tests")
    assert "# JARVIS CONTEXT" in md
    assert "fix the tests" in md
    assert "Pranav prefers direct-to-main" in md
    assert "Voice is realtime-only" in md
    assert "builds JarvisCopilot" in md
    # § delimiter must be reformatted to markdown bullets, not left raw
    assert "§" not in md


def test_build_context_handles_empty():
    md = build_context_markdown(memory_text="", user_text="",
                                project_name="p", task="")
    assert "# JARVIS CONTEXT" in md
