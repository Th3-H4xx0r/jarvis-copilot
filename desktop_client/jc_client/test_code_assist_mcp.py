"""The code-assist MCP tools are defined once and shared by both hosts."""
from pathlib import Path

import pytest

from jc_client import code_assist_mcp, code_memory_client, code_memory_slug, mcp_server

_REPO = Path(__file__).resolve().parents[2]


def _offered(build):
    """{tool name: description} a built FastMCP server advertises."""
    pytest.importorskip("mcp")
    server = build()
    tools = server._tool_manager.list_tools()
    return {t.name: t.description for t in tools}


def test_the_desktop_offers_every_tool():
    names = set(_offered(mcp_server.build_server))
    assert names == set(code_assist_mcp.REQUIRED_TOOLS) | set(code_assist_mcp.OPTIONAL_TOOLS)


def test_a_backend_without_ask_offers_no_ask():
    backend = {k: v for k, v in mcp_server.DESKTOP_BACKEND.items()
               if k not in code_assist_mcp.OPTIONAL_TOOLS}
    offered = _offered(lambda: code_assist_mcp.build_server(backend))
    assert set(offered) == set(code_assist_mcp.REQUIRED_TOOLS)
    desktop = _offered(mcp_server.build_server)
    for name, doc in offered.items():
        assert doc == desktop[name], name


def test_a_backend_missing_a_required_tool_is_refused():
    with pytest.raises(ValueError, match="query_memory"):
        code_assist_mcp.build_server({k: v for k, v in mcp_server.DESKTOP_BACKEND.items()
                                      if k != "query_memory"})


def test_tools_call_the_backend():
    pytest.importorskip("mcp")
    calls = []
    backend = {name: (lambda *a, _n=name: calls.append((_n, a)) or {"ok": _n})
               for name in code_assist_mcp.REQUIRED_TOOLS}
    server = code_assist_mcp.build_server(backend)
    tool = server._tool_manager.get_tool("store_code_knowledge")
    assert tool.fn("bug", "x", "p") == {"ok": "store_code_knowledge"}
    assert calls == [("store_code_knowledge", ("bug", "x", "p"))]


def test_the_server_host_uses_this_file():
    """The server loads code_assist_mcp.py and code_memory_slug.py by path; if
    they moved, server sessions would break or fork the slug rule."""
    shim = (_REPO / "agent" / "agent_engine_shim.py").read_text()
    assert '"code_assist_mcp.py"' in shim and '"code_memory_slug.py"' in shim


def test_the_client_slug_is_the_shared_rule():
    assert code_memory_client.slug_for is code_memory_slug.project_slug
    assert code_memory_client.current_slug is code_memory_slug.current_slug


@pytest.mark.parametrize("root,remote,slug", [
    ("/x", "https://github.com/a/b.git", "github.com_a_b"),
    ("/x", "git@github.com:a/b.git", "github.com_a_b"),
    ("/x", "ssh://git@host:22/a/B.GIT", "host_22_a_b"),
    ("/Users/me/My Project", None, "my-project"),
    ("/Users/me/My Project/", "", "my-project"),
    (".", None, "project"),
    ("/", None, "project"),
    ("/x/..", None, "project"),
    ("/code/app/src/..", None, "app"),  # the server used to say "project" here
    ("/x", "../../etc/passwd", "etc_passwd"),
])
def test_slug_cases(root, remote, slug):
    assert code_memory_slug.project_slug(root, remote) == slug


def test_current_slug_reads_the_git_remote(tmp_path, monkeypatch):
    monkeypatch.setattr(code_memory_slug, "git_remote",
                        lambda root: "git@github.com:a/b.git" if root == str(tmp_path) else "")
    assert code_memory_slug.current_slug(str(tmp_path)) == "github.com_a_b"
    monkeypatch.chdir(tmp_path)
    assert code_memory_slug.current_slug() == "github.com_a_b"
