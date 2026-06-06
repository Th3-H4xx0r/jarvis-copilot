import tools.coding_session_tool  # noqa: F401  (registers tools on import)
from tools.registry import registry
import toolsets


def _registered_names():
    return set(getattr(registry, "_tools", {}).keys())


def test_tools_registered():
    names = {"coding_session_launch", "coding_session_list", "coding_session_status",
             "coding_session_message", "coding_session_stop",
             "coding_project_create", "coding_project_list"}
    assert names <= _registered_names()


def test_toolset_is_a_toolsets_key():
    # the gotcha: a tool whose toolset isn't a TOOLSETS key is dropped by
    # _get_platform_tools (see jarviscopilot_cli/tools_config.py).
    assert "coding_sessions" in toolsets.TOOLSETS


def test_tool_names_in_core():
    core = toolsets._HERMES_CORE_TOOLS
    for n in ("coding_session_launch", "coding_session_message", "coding_session_stop"):
        assert n in core


def test_launch_handler_errors_cleanly_without_cwd():
    import json
    from tools.coding_session_tool import _h_launch
    out = json.loads(_h_launch({}))
    assert "error" in out


def test_launch_requires_some_cwd():
    # relative/~/new paths are now ACCEPTED (manager resolves+creates them);
    # only a completely missing cwd is an error. (Don't pass a real cwd here —
    # that would attempt a real launch.)
    import json
    from tools.coding_session_tool import _h_launch
    out = json.loads(_h_launch({"cwd": ""}))
    assert "error" in out


def test_launch_rejects_injection_model(tmp_path):
    import json
    from tools.coding_session_tool import _h_launch
    out = json.loads(_h_launch({"cwd": str(tmp_path), "model": "opus; rm -rf ~"}))
    assert "error" in out and "invalid model" in out["error"]
