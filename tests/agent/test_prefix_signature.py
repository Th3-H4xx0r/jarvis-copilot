from agent.prefix_signature import prefix_signature


def test_same_prefix_same_signature():
    msgs = [{"role": "system", "content": "S"}, {"role": "user", "content": "a"}]
    tools = [{"type": "function", "function": {"name": "x", "parameters": {}}}]
    later = msgs + [{"role": "assistant", "content": "b"}, {"role": "user", "content": "c"}]
    assert prefix_signature(msgs, tools) == prefix_signature(later, tools)


def test_system_or_tools_change_changes_signature():
    msgs = [{"role": "system", "content": "S"}]
    tools = [{"type": "function", "function": {"name": "x"}}]
    base = prefix_signature(msgs, tools)
    assert prefix_signature([{"role": "system", "content": "S2"}], tools) != base
    assert prefix_signature(msgs, tools + [{"type": "function", "function": {"name": "y"}}]) != base


def test_shape():
    out = prefix_signature([], None)
    assert out.startswith(" sys=") and " tools=" in out
