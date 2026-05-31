from agent.tool_output_compactor import (
    classify,
    compact_tool_output,
    head_tail,
    strip_ansi,
)


def test_head_tail_marks_omission():
    lines = [f"line{i}" for i in range(30)]
    out = head_tail(lines, 5, 5)
    assert out[:5] == lines[:5]
    assert out[-5:] == lines[-5:]
    assert any("20 lines omitted" in x for x in out)


def test_head_tail_noop_when_small():
    lines = ["a", "b", "c"]
    assert head_tail(lines, 5, 5) == lines


def test_strip_ansi():
    assert strip_ansi("\x1b[31mred\x1b[0m text") == "red text"


def test_classify_picks_pytest():
    assert classify("terminal", "pytest -q tests/", ["pytest", "-q", "tests/"])["id"] == "tests/pytest"


def test_classify_git_status():
    assert classify("terminal", "git status", ["git", "status"])["id"] == "vcs/git-status"


def test_classify_fallback():
    assert classify("terminal", "some random output cmd", ["some"])["id"] == "generic/fallback"


def test_short_output_unchanged():
    txt = "small output"
    assert compact_tool_output("terminal", {"command": "echo hi"}, txt) == txt


def test_non_string_passthrough():
    obj = {"image": "..."}
    assert compact_tool_output("read_image", {}, obj) is obj


def test_long_log_is_compacted_and_smaller():
    body = "\n".join(f"Compiling crate {i}" for i in range(400))
    out = compact_tool_output("terminal", {"command": "cargo build"}, body)
    assert out != body and len(out) < len(body)
    assert "lines omitted" in out or "omitted" in out


def test_failure_tail_preserved():
    lines = ["ok " + str(i) for i in range(200)]
    lines.append("E   AssertionError: boom")
    lines.append("FAILED tests/test_x.py::test_y - AssertionError")
    body = "\n".join(lines)
    out = compact_tool_output("terminal", {"command": "pytest -q"}, body, is_error=True)
    assert "FAILED tests/test_x.py::test_y" in out  # failure line survives in the tail
    assert len(out) < len(body)


def test_domain_tool_json_not_truncated():
    # No shell command in args -> generic fallback must NOT mangle structured output.
    big_json = '{"items": [' + ",".join('{"k":%d}' % i for i in range(400)) + "]}"
    assert len(big_json) >= 512
    assert compact_tool_output("some_api_tool", {"id": "x"}, big_json) == big_json


def test_file_inspection_not_truncated():
    body = "\n".join(f"file line {i}" for i in range(400))
    # `cat bigfile` is a real command but a file dump -> must be left intact.
    assert compact_tool_output("terminal", {"command": "cat bigfile.txt"}, body) == body


def test_clamp_to_max_chars():
    body = "x" * 50000  # one giant line, no newlines
    out = compact_tool_output("terminal", {"command": "make"}, body)
    assert len(out) <= 1300  # clamped near MAX_INLINE_CHARS (+ marker)
