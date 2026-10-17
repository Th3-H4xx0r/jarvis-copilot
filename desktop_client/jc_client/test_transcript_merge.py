"""The transcript merge both the Mac and the server run (never drops a line)."""
import json

from jc_client.transcript_merge import line_id, merge


def L(uid, text="x"):
    return json.dumps({"uuid": uid, "type": "user", "message": text})


def test_line_id_claude_uuid_and_codex_positional():
    assert line_id(L("u1"), "claude") == "u1"
    assert line_id('{"type":"summary"}', "claude") is None
    assert line_id("not json", "claude") is None
    assert line_id(L("u1"), "codex") is None


def test_claude_append_only():
    r = merge([L("a"), L("b")], [L("a"), L("b"), L("c")], "claude")
    assert r.merged == [L("a"), L("b"), L("c")] and r.fork_tail == [] and r.kind == "appended"


def test_claude_equal_is_noop():
    r = merge([L("a"), L("b")], [L("a"), L("b")], "claude")
    assert r.merged == [L("a"), L("b")] and r.kind == "equal"


def test_claude_receiver_ahead_keeps_its_lines():
    r = merge([L("a"), L("b"), L("c")], [L("a"), L("b")], "claude")
    assert r.merged == [L("a"), L("b"), L("c")] and r.kind == "equal" and r.fork_tail == []


def test_claude_both_sides_added_yields_fork_tail():
    r = merge([L("a"), L("b"), L("c"), L("x")], [L("a"), L("b"), L("c"), L("y"), L("z")], "claude")
    assert r.merged == [L("a"), L("b"), L("c"), L("y"), L("z")]
    assert r.fork_tail == [L("x")] and r.kind == "forked"


def test_lines_without_uuid_kept_in_place():
    s = '{"type":"summary","summary":"s"}'
    r = merge([L("a"), s, L("b")], [L("a"), s, L("b"), L("c")], "claude")
    assert r.merged == [L("a"), s, L("b"), L("c")]


def test_codex_prefix_rules():
    assert merge(["1", "2"], ["1", "2", "3"], "codex").merged == ["1", "2", "3"]
    assert merge(["1", "2", "3"], ["1", "2"], "codex").merged == ["1", "2", "3"]
    r = merge(["1", "2", "x"], ["1", "2", "y"], "codex")
    assert r.merged == ["1", "2", "y"] and r.fork_tail == ["x"] and r.kind == "forked"


def test_never_drops_a_line():
    cases = [
        ([L("a"), L("b"), L("x"), L("w")], [L("a"), L("y")], "claude"),
        ([L("a")], [L("b")], "claude"),
        ([], [L("a")], "claude"),
        ([L("a")], [], "claude"),
        (["1", "x"], ["2", "y"], "codex"),
    ]
    for base, incoming, agent in cases:
        r = merge(base, incoming, agent)
        out = set(r.merged) | set(r.fork_tail)
        assert set(base) <= out and set(incoming) <= out, (base, incoming)
