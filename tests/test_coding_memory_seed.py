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


def test_build_context_preserves_multiline_entry():
    mem = "line one\nline two same entry"
    md = build_context_markdown(memory_text=mem, user_text="",
                                project_name="p", task="")
    # a multi-line entry stays one bullet with an indented continuation,
    # not collapsed into a run-on line
    assert "- line one" in md
    assert "\n  line two same entry" in md
