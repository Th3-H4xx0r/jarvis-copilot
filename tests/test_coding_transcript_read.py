import json

from agent.coding_transcript_read import (
    context_window_for, parse_transcript_text, slice_messages,
    transcript_context)


def _line(t, content, **kw):
    d = {"type": t, "message": {"role": t, "content": content},
         "timestamp": "2026-06-09T10:00:00.000Z"}
    if "usage" in kw:
        d["message"]["usage"] = kw.pop("usage")
    if "model" in kw:
        d["message"]["model"] = kw.pop("model")
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


def test_task_tool_tagged_as_subagent_with_status():
    text = "\n".join([
        _line("assistant", [{"type": "tool_use", "id": "t1", "name": "Task",
                             "input": {"subagent_type": "Explore",
                                       "description": "map the chat pipeline"}}]),
        _line("user", [{"type": "tool_result", "tool_use_id": "t1",
                        "content": "done", "is_error": False}]),
        _line("assistant", [{"type": "tool_use", "id": "t2", "name": "Task",
                             "input": {"subagent_type": "Plan",
                                       "description": "still going"}}]),
    ])
    msgs = parse_transcript_text(text)
    tools = [t for m in msgs for t in m["tools"]]
    done = next(t for t in tools if t["summary"] == "map the chat pipeline")
    running = next(t for t in tools if t["summary"] == "still going")
    assert done["subagent_type"] == "Explore"
    assert done["ok"] is True            # tool_result attached → completed
    assert running["subagent_type"] == "Plan"
    assert running["ok"] is None         # no result yet → running


def test_non_task_tool_has_no_subagent_type():
    text = _line("assistant", [{"type": "tool_use", "id": "t1", "name": "Bash",
                                "input": {"command": "ls"}}])
    msgs = parse_transcript_text(text)
    assert "subagent_type" not in msgs[0]["tools"][0]


def test_bash_tool_has_no_diff():
    text = _line("assistant", [{
        "type": "tool_use", "id": "t1", "name": "Bash",
        "input": {"command": "ls"}}])
    msgs = parse_transcript_text(text)
    assert "diff" not in msgs[0]["tools"][0]


# ---- context-window gauge ----------------------------------------------------

def test_context_window_for_model():
    assert context_window_for("claude-opus-4-8") == 200_000
    assert context_window_for("claude-fable-5[1m]") == 1_000_000
    assert context_window_for("claude-sonnet-4-6[1m]") == 1_000_000
    assert context_window_for(None) == 200_000


def test_context_from_last_assistant_usage():
    u1 = {"input_tokens": 100, "cache_creation_input_tokens": 200,
          "cache_read_input_tokens": 300, "output_tokens": 50}
    u2 = {"input_tokens": 1000, "cache_creation_input_tokens": 2000,
          "cache_read_input_tokens": 3000, "output_tokens": 90}
    text = "\n".join([
        _line("user", "hi"),
        _line("assistant", [{"type": "text", "text": "a"}],
              usage=u1, model="claude-opus-4-8"),
        _line("user", "more"),
        _line("assistant", [{"type": "text", "text": "b"}],
              usage=u2, model="claude-opus-4-8"),
    ])
    msgs = parse_transcript_text(text)
    ctx = transcript_context(msgs)
    # latest turn: 1000 + 2000 + 3000 = 6000 used of 200k
    assert ctx == {"used": 6000, "window": 200_000, "pct": 3,
                   "model": "claude-opus-4-8"}


def test_context_none_without_usage():
    msgs = parse_transcript_text(_line("user", "no usage here"))
    assert transcript_context(msgs) is None


def test_slice_includes_context_and_strips_internal_usage():
    u = {"input_tokens": 50_000, "cache_creation_input_tokens": 0,
         "cache_read_input_tokens": 150_000, "output_tokens": 10}
    text = "\n".join([
        _line("user", "hi"),
        _line("assistant", [{"type": "text", "text": "yo"}],
              usage=u, model="claude-opus-4-8"),
    ])
    msgs = parse_transcript_text(text)
    s = slice_messages(msgs, after=0)
    assert s["context"] == {"used": 200_000, "window": 200_000, "pct": 100,
                            "model": "claude-opus-4-8"}
    # internal usage/model keys never reach the wire
    assert all("usage" not in m and "model" not in m for m in s["messages"])
