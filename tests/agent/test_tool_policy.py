"""A harness node's tool setting limits what it may CALL; the tools list itself
stays one canonical list per model so every agent shares the prompt cache."""
import json

from agent.tool_policy import canonical_tools, node_tool_policy, refusal


def _t(name):
    return {"type": "function", "function": {"name": name, "parameters": {}}}


def test_lean_and_all_are_unrestricted():
    assert node_tool_policy("lean") == (None, "")
    assert node_tool_policy("all") == (None, "")
    assert node_tool_policy(None) == (None, "")


def test_none_allows_nothing_and_says_so():
    allowed, note = node_tool_policy("none")
    assert allowed == frozenset()
    assert "without tools" in note.lower()


def test_list_allows_only_those_toolsets(monkeypatch):
    import agent.tool_policy as tp

    monkeypatch.setattr(tp, "_names_for_toolsets",
                        lambda ts: {"web_search"} if "web" in ts else set())
    allowed, note = node_tool_policy(["web"])
    assert "web_search" in allowed
    assert "terminal" not in allowed
    # Reaching an on-demand tool in an allowed group needs the search + bridge.
    assert {"tool_search", "tool_call"} <= allowed
    assert "web" in note


def test_canonical_tools_sorted_and_deduped():
    out = canonical_tools([_t("b"), _t("a"), _t("b")])
    assert [t["function"]["name"] for t in out] == ["a", "b"]


def test_canonical_tools_is_order_independent():
    a = canonical_tools([_t("x"), _t("c"), _t("m")])
    b = canonical_tools([_t("m"), _t("x"), _t("c")])
    assert json.dumps(a) == json.dumps(b)


def test_refusal_is_a_readable_json_error_naming_the_tool():
    body = json.loads(refusal("terminal"))
    assert "terminal" in body["error"]


class _Agent:
    def __init__(self, allowed=None, wired=None):
        self.allowed_tool_names = allowed
        if wired is not None:
            self._handoff_wired = wired


def test_unrestricted_agent_blocks_nothing():
    from agent.tool_policy import block_message
    assert block_message(_Agent(), "terminal", {}) is None


def test_node_call_filter_refuses_outside_setting():
    from agent.tool_policy import block_message
    agent = _Agent(allowed=frozenset())
    msg = block_message(agent, "terminal", {"command": "ls"})
    assert msg and "terminal" in msg
    # A bridged call is judged by the tool it really reaches.
    assert "web_extract" in block_message(agent, "tool_call", {"name": "web_extract", "arguments": {}})
    # Searching is always fine: it only reads schemas.
    assert block_message(agent, "tool_search", {"query": "x"}) is None


def test_allowed_tool_passes():
    from agent.tool_policy import block_message
    assert block_message(_Agent(allowed=frozenset({"web_search"})), "web_search", {}) is None


def test_handoff_refused_only_when_explicitly_unwired():
    from agent.tool_policy import block_message
    assert block_message(_Agent(wired=False), "handoff", {}) is not None
    assert block_message(_Agent(wired=True), "handoff", {}) is None
    assert block_message(_Agent(), "handoff", {}) is None  # agents outside the webui never set it


def test_handoff_allowed_on_a_wired_node_whatever_its_tool_setting():
    """A "none" (or custom-list) fast node wired to a Background node is told to
    hand off — refusing it there would strand the turn."""
    from agent.tool_policy import block_message
    assert block_message(_Agent(allowed=frozenset(), wired=True), "handoff", {}) is None
    assert block_message(_Agent(allowed=frozenset({"web_search"}), wired=True), "handoff", {}) is None


def test_a_bridged_bare_device_name_is_judged_as_the_device_tool(monkeypatch):
    """The bridge resolves tool_call(name="x5_get_status") to device_x5_get_status;
    the node filter must judge the same tool, not refuse the bare name."""
    import agent.tool_policy as tp
    from agent.tool_policy import block_message
    monkeypatch.setattr(tp, "_known_tool_names", lambda: {"device_x5_get_status"})
    agent = _Agent(allowed=frozenset({"device_x5_get_status", "tool_search", "tool_call"}))
    assert block_message(agent, "tool_call", {"name": "x5_get_status", "arguments": {}}) is None


def test_claude_code_engine_dispatch_honours_the_node_filter():
    """The claude-code structured engine dispatches every tool through
    invoke_tool, which must apply the same node filter as the executor."""
    from agent.agent_runtime_helpers import invoke_tool
    agent = _Agent(allowed=frozenset())
    out = json.loads(invoke_tool(agent, "terminal", {"command": "ls"}, "task"))
    assert "terminal" in out["error"]
