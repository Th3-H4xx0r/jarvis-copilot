"""Tests for GET /api/tools/catalog → _build_tools_catalog().

Pure unit test of the serializer: it must return the full registered tool
surface as plain metadata (name/description/toolset/schema) with NO secrets —
no handlers, no check_fns. Does not spin up the raw-HTTP server.
"""
import pathlib
import sys

_WEBUI_DIR = pathlib.Path(__file__).resolve().parent.parent
if str(_WEBUI_DIR) not in sys.path:
    sys.path.insert(0, str(_WEBUI_DIR))

from api.routes import _build_tools_catalog  # noqa: E402


def test_catalog_returns_non_empty_tools_list():
    out = _build_tools_catalog()
    assert isinstance(out, dict)
    assert "tools" in out
    assert isinstance(out["tools"], list)
    assert len(out["tools"]) > 0  # the agent registers many built-in tools


def test_each_tool_has_string_name_and_description_no_secrets():
    out = _build_tools_catalog()
    for tool in out["tools"]:
        assert isinstance(tool["name"], str) and tool["name"]
        assert isinstance(tool["description"], str)
        # No callable / secret fields leak through the serializer.
        assert "handler" not in tool
        assert "check_fn" not in tool
        assert "requires_env" not in tool
        # Only the four documented keys are present.
        assert set(tool.keys()) == {"name", "description", "toolset", "schema"}


def test_catalog_is_sorted_by_name():
    out = _build_tools_catalog()
    names = [t["name"] for t in out["tools"]]
    assert names == sorted(names)


def test_catalog_is_defensive_when_registry_import_fails(monkeypatch):
    # Force the in-function registry import to fail → must degrade to {"tools": []}
    # rather than raising / 500ing.
    import builtins

    real_import = builtins.__import__

    def _boom(name, *args, **kwargs):
        if name == "tools.registry":
            raise ImportError("simulated missing registry")
        return real_import(name, *args, **kwargs)

    monkeypatch.setattr(builtins, "__import__", _boom)
    out = _build_tools_catalog()
    assert out == {"tools": []}
