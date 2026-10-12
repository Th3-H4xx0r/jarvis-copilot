"""The memory/skill review fork sends the parent's exact prompt start.

A fork built from the parent's toolset CONFIG still gets its own tool list:
the webui reshapes a live agent's tools after construction (device tools, the
hand-off tool, the lazy partition), so a rebuilt list differs and the review
pays a full cold cache write. The fork must reuse the parent's tools, system
prompt and prompt-shape state as they are, so its request reads the parent's
cache. Dispatch stays limited to memory/skill tools by the runtime whitelist.
"""

import datetime as _dt
from unittest.mock import patch

from agent.background_review import spawn_background_review_thread


def _tool(name):
    return {"type": "function", "function": {"name": name, "description": name,
                                             "parameters": {"type": "object", "properties": {}}}}


def _parent():
    import run_agent

    agent = object.__new__(run_agent.AIAgent)
    agent.model = "m"
    agent.platform = "webui"
    agent.provider = "openai"
    agent.session_id = "sess-1"
    agent.session_start = _dt.datetime(2026, 1, 1, 12, 0, 0)
    agent.quiet_mode = True
    agent._memory_store = None
    agent._memory_enabled = True
    agent._user_profile_enabled = False
    agent._memory_nudge_interval = 5
    agent._skill_nudge_interval = 5
    agent.background_review_callback = None
    agent.status_callback = None
    agent.enabled_toolsets = None
    agent.disabled_toolsets = None
    agent._current_main_runtime = lambda: {"api_mode": "chat_completions"}
    # The parent's live, post-construction prompt shape.
    agent.tools = [_tool("device_open_app"), _tool("handoff"), _tool("memory"), _tool("tool_search")]
    agent.valid_tool_names = {"device_open_app", "handoff", "memory", "tool_search"}
    agent._cached_system_prompt = "STABLE PARENT PROMPT"
    agent.ephemeral_system_prompt = "webui progress guidance"
    agent._system_prompt_parts = {"stable": "STABLE", "volatile": "PARENT PROMPT"}
    agent._lazy_tools_manifest = "## web\n- web_extract: read pages"
    agent._lazy_all_tool_names = {"device_open_app", "handoff", "memory", "tool_search", "web_extract"}
    agent._cache_retention = "long"
    agent._cache_ttl = "1h"
    return agent


class _Fork:
    """Stands in for the review AIAgent: builds its OWN (different) tool list,
    as a fresh agent would, and records its state when the review runs."""

    seen = {}

    def __init__(self, *args, **kwargs):
        self.tools = [_tool("memory"), _tool("skill_manage")]
        self.valid_tool_names = {"memory", "skill_manage"}
        self._cached_system_prompt = None
        self.ephemeral_system_prompt = None
        self._lazy_tools_manifest = ""
        self._cache_retention = "standard"
        self._cache_ttl = "5m"

    def run_conversation(self, *args, **kwargs):
        _Fork.seen = dict(vars(self))
        raise RuntimeError("stop before any API call")

    def shutdown_memory_provider(self):
        pass

    def close(self):
        pass


def _run_review(parent, **flags):
    import run_agent

    _Fork.seen = {}
    target, _prompt = spawn_background_review_thread(parent, [], **flags)
    with patch.object(run_agent, "AIAgent", _Fork):
        target()
    assert _Fork.seen, "the review never ran"
    return _Fork.seen


def test_fork_reuses_the_parents_tools_and_system_prompt():
    parent = _parent()
    fork = _run_review(parent, review_memory=True)

    assert fork["tools"] == parent.tools
    assert fork["valid_tool_names"] == parent.valid_tool_names
    assert fork["_cached_system_prompt"] == parent._cached_system_prompt
    # The system message is the cached prompt plus the ephemeral one.
    assert fork["ephemeral_system_prompt"] == parent.ephemeral_system_prompt
    assert fork["_system_prompt_parts"] == parent._system_prompt_parts
    assert fork["_lazy_tools_manifest"] == parent._lazy_tools_manifest
    assert fork["_lazy_all_tool_names"] == parent._lazy_all_tool_names
    assert fork["_cache_retention"] == parent._cache_retention
    assert fork["_cache_ttl"] == parent._cache_ttl


def test_fork_tools_are_a_copy_the_parent_never_sees_change():
    parent = _parent()
    before = [dict(t) for t in parent.tools]
    fork = _run_review(parent, review_skills=True)

    assert fork["tools"] is not parent.tools
    fork["tools"].append(_tool("extra"))
    fork["tools"][0]["function"]["name"] = "renamed"
    assert parent.tools == before


def test_retrospective_fork_uses_the_prompt_shape_from_spawn_time():
    """The retrospective fires at the session boundary, where the caller then
    rotates the parent's state; the fork keeps what the parent sent."""
    import run_agent

    parent = _parent()
    sent_tools = [dict(t) for t in parent.tools]
    target, _prompt = spawn_background_review_thread(parent, [], review_outcome=True)
    parent.tools = [_tool("something_else")]
    parent._cached_system_prompt = None
    _Fork.seen = {}
    with patch.object(run_agent, "AIAgent", _Fork), \
         patch("tools.memory_tool.MemoryStore") as store:
        store.return_value.load_from_disk.return_value = None
        target()

    assert _Fork.seen["tools"] == sent_tools
    assert _Fork.seen["_cached_system_prompt"] == "STABLE PARENT PROMPT"


def test_fork_keeps_the_memory_and_skill_whitelist():
    """Same tools as the parent, but dispatch is still limited at runtime."""
    import run_agent
    from jarviscopilot_cli import plugins

    parent = _parent()
    seen = {}

    class _Probe(_Fork):
        def run_conversation(self, *args, **kwargs):
            seen["blocked"] = plugins.get_pre_tool_call_block_message("terminal", {})
            seen["allowed"] = plugins.get_pre_tool_call_block_message("memory", {})
            raise RuntimeError("stop")

    target, _prompt = spawn_background_review_thread(parent, [], review_memory=True)
    with patch.object(run_agent, "AIAgent", _Probe):
        target()

    assert seen["blocked"]
    assert not seen["allowed"]
