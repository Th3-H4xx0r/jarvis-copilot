import json

from agent.coding_transcript_read import parse_transcript_text, slice_messages


def _line(t, content, **kw):
    d = {"type": t, "message": {"role": t, "content": content},
         "timestamp": "2026-06-09T10:00:00.000Z"}
    d.update(kw)
    return json.dumps(d)


def test_parse_basic_user_assistant():
    text = "\n".join([
        _line("user", "fix the bug"),
        _line("assistant", [{"type": "text", "text": "On it."}]),
    ])
    msgs = parse_transcript_text(text)
    assert [(m["role"], m["text"]) for m in msgs] == [
        ("user", "fix the bug"), ("assistant", "On it.")]


def test_tool_use_and_result_attached():
    text = "\n".join([
        _line("user", "run tests"),
        _line("assistant", [{"type": "tool_use", "id": "t1", "name": "Bash",
                             "input": {"command": "pytest -q"}}]),
        _line("user", [{"type": "tool_result", "tool_use_id": "t1",
                        "content": "3 passed", "is_error": False}]),
        _line("assistant", [{"type": "text", "text": "All green."}]),
    ])
    msgs = parse_transcript_text(text)
    # tool_result-only user line renders no message; assistant lines merge.
    assert len(msgs) == 2
    a = msgs[1]
    assert a["role"] == "assistant" and a["text"] == "All green."
    assert a["tools"] == [{"name": "Bash", "summary": "pytest -q",
                           "output": "3 passed", "ok": True}]


def test_meta_sidechain_and_envelopes_skipped():
    text = "\n".join([
        _line("user", "<local-command-stdout>x</local-command-stdout>"),
        _line("user", "real question"),
        _line("user", "side", isSidechain=True),
        _line("assistant", [{"type": "thinking", "thinking": "hmm"}]),
        _line("user", "meta", isMeta=True),
    ])
    msgs = parse_transcript_text(text)
    assert [(m["role"], m["text"]) for m in msgs] == [("user", "real question")]


def test_slice_after_semantics():
    text = "\n".join(_line("user", f"m{i}") for i in range(5))
    msgs = parse_transcript_text(text)
    s = slice_messages(msgs, after=3)
    assert s["total"] == 5
    assert [m["text"] for m in s["messages"]] == ["m3", "m4"]
    assert [m["i"] for m in s["messages"]] == [3, 4]


def test_edit_tool_carries_diff():
    text = _line("assistant", [{
        "type": "tool_use", "id": "t1", "name": "Edit",
        "input": {"file_path": "/x/a.py",
                  "old_string": "a = 1\nb = 2",
                  "new_string": "a = 1\nb = 3"}}])
    msgs = parse_transcript_text(text)
    diff = msgs[0]["tools"][0]["diff"]
    assert "-b = 2" in diff and "+b = 3" in diff
    assert not any(d.startswith(("---", "+++")) for d in diff)


def test_write_tool_diff_is_all_added():
    text = _line("assistant", [{
        "type": "tool_use", "id": "t1", "name": "Write",
        "input": {"file_path": "/x/a.py", "content": "x\ny"}}])
    msgs = parse_transcript_text(text)
    assert msgs[0]["tools"][0]["diff"] == ["+x", "+y"]


def test_bash_tool_has_no_diff():
    text = _line("assistant", [{
        "type": "tool_use", "id": "t1", "name": "Bash",
        "input": {"command": "ls"}}])
    msgs = parse_transcript_text(text)
    assert "diff" not in msgs[0]["tools"][0]
