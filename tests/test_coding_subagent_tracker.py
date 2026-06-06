"""Tests for agent.coding_subagent_tracker (strict TDD — written before impl).

Covers parsing a Claude Code JSONL transcript for Task-tool subagent spawns:
both message-wrapping shapes, Task-only filtering, completed/running status,
tolerant parsing of garbage lines, missing files, and the summarize roll-up.
"""

import json

from agent.coding_subagent_tracker import (
    iter_tool_results,
    iter_tool_uses,
    parse_subagents,
    summarize,
)


def _write_jsonl(path, objs):
    """Write a list of objects (or raw strings) as JSONL lines."""
    lines = []
    for o in objs:
        lines.append(o if isinstance(o, str) else json.dumps(o))
    path.write_text("\n".join(lines) + "\n")
    return str(path)


def _task_use(tool_id, sub_type, description):
    return {
        "type": "tool_use",
        "id": tool_id,
        "name": "Task",
        "input": {
            "subagent_type": sub_type,
            "description": description,
            "prompt": "do the thing",
        },
    }


def _tool_result(tool_use_id):
    return {"type": "tool_result", "tool_use_id": tool_use_id, "content": "done"}


def test_two_spawns_status_order_and_fields(tmp_path):
    """explorer (completed via tool_result) + coder (running) in order."""
    transcript = [
        # wrapped assistant message with the explorer Task spawn
        {
            "type": "assistant",
            "message": {
                "role": "assistant",
                "content": [_task_use("toolu_explorer", "explorer", "find X")],
            },
        },
        # bare assistant message with the coder Task spawn
        {
            "role": "assistant",
            "content": [_task_use("toolu_coder", "coder", "write Y")],
        },
        # tool_result for the explorer only -> explorer completed, coder running
        {
            "type": "user",
            "message": {
                "role": "user",
                "content": [_tool_result("toolu_explorer")],
            },
        },
    ]
    p = _write_jsonl(tmp_path / "transcript.jsonl", transcript)

    subs = parse_subagents(p)

    assert len(subs) == 2
    # discovery order preserved: explorer first, coder second
    assert [s["id"] for s in subs] == ["toolu_explorer", "toolu_coder"]

    explorer = subs[0]
    assert explorer["sub_type"] == "explorer"
    assert explorer["description"] == "find X"
    assert explorer["status"] == "completed"

    coder = subs[1]
    assert coder["sub_type"] == "coder"
    assert coder["description"] == "write Y"
    assert coder["status"] == "running"


def test_non_task_tool_use_is_not_counted(tmp_path):
    """A Bash tool_use must be ignored; only Task spawns count."""
    transcript = [
        {
            "type": "assistant",
            "message": {
                "role": "assistant",
                "content": [
                    {
                        "type": "tool_use",
                        "id": "toolu_bash",
                        "name": "Bash",
                        "input": {"command": "ls"},
                    },
                    _task_use("toolu_real", "explorer", "real one"),
                ],
            },
        },
    ]
    p = _write_jsonl(tmp_path / "t.jsonl", transcript)

    subs = parse_subagents(p)

    assert len(subs) == 1
    assert subs[0]["id"] == "toolu_real"
    assert subs[0]["sub_type"] == "explorer"


def test_both_message_shapes_parsed(tmp_path):
    """Wrapped (message.content) and bare (content) shapes both yield spawns."""
    transcript = [
        {
            "type": "assistant",
            "message": {
                "role": "assistant",
                "content": [_task_use("toolu_wrapped", "explorer", "w")],
            },
        },
        {
            "role": "assistant",
            "content": [_task_use("toolu_bare", "coder", "b")],
        },
    ]
    p = _write_jsonl(tmp_path / "t.jsonl", transcript)

    subs = parse_subagents(p)

    assert {s["id"] for s in subs} == {"toolu_wrapped", "toolu_bare"}
    assert all(s["status"] == "running" for s in subs)


def test_malformed_and_unrelated_lines_skipped(tmp_path):
    """Garbage / non-JSON / unrelated lines must not raise and not count."""
    good = _task_use("toolu_ok", "explorer", "ok")
    raw_lines = [
        "this is not json at all {",  # malformed -> skip
        "",  # blank line -> skip
        "   ",  # whitespace -> skip
        json.dumps({"type": "system", "content": "boot"}),  # unrelated
        json.dumps("a bare json string"),  # valid json, wrong shape
        json.dumps([1, 2, 3]),  # valid json list, wrong shape
        json.dumps({"role": "user", "content": "hello there"}),  # user text
        json.dumps(
            {"type": "assistant", "message": {"content": [good]}}
        ),  # the only real spawn
    ]
    p = tmp_path / "t.jsonl"
    p.write_text("\n".join(raw_lines) + "\n")

    subs = parse_subagents(str(p))

    assert len(subs) == 1
    assert subs[0]["id"] == "toolu_ok"


def test_missing_file_returns_empty_list(tmp_path):
    """A path that does not exist returns [] rather than raising."""
    missing = tmp_path / "does_not_exist.jsonl"
    assert parse_subagents(str(missing)) == []


def test_missing_input_fields_default_to_empty(tmp_path):
    """Task with no subagent_type/description still parses with '' defaults."""
    transcript = [
        {
            "role": "assistant",
            "content": [
                {
                    "type": "tool_use",
                    "id": "toolu_bare_input",
                    "name": "Task",
                    "input": {},
                }
            ],
        },
        # a Task with no input key at all
        {
            "role": "assistant",
            "content": [
                {"type": "tool_use", "id": "toolu_no_input", "name": "Task"}
            ],
        },
    ]
    p = _write_jsonl(tmp_path / "t.jsonl", transcript)

    subs = parse_subagents(p)

    assert len(subs) == 2
    for s in subs:
        assert s["sub_type"] == ""
        assert s["description"] == ""
        assert s["status"] == "running"


def test_summarize_counts(tmp_path):
    subs = [
        {"id": "a", "sub_type": "x", "description": "", "status": "completed"},
        {"id": "b", "sub_type": "y", "description": "", "status": "running"},
        {"id": "c", "sub_type": "z", "description": "", "status": "completed"},
    ]
    assert summarize(subs) == {"total": 3, "running": 1, "completed": 2}


def test_summarize_empty():
    assert summarize([]) == {"total": 0, "running": 0, "completed": 0}


def test_iter_helpers_normalize_both_shapes():
    """iter_tool_uses / iter_tool_results work on wrapped and bare shapes."""
    use = _task_use("toolu_x", "explorer", "d")
    res = _tool_result("toolu_x")

    wrapped = {"type": "assistant", "message": {"content": [use, res]}}
    bare = {"content": [use, res]}

    for obj in (wrapped, bare):
        uses = iter_tool_uses(obj)
        results = iter_tool_results(obj)
        assert [u["id"] for u in uses] == ["toolu_x"]
        assert results == ["toolu_x"]

    # objects with no content yield nothing, no raise
    assert iter_tool_uses({"type": "system"}) == []
    assert iter_tool_results({"role": "user", "content": "plain text"}) == []
