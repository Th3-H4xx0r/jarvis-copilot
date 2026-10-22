"""Long-term Memory map (web): pure graph helpers + panel/chip wiring.

The graph logic (query building, load/expand/merge/cap, force step + settle,
view transform, recall matching for the chat chip) lives in
webui/static/memory_graph.js and is tested with node's built-in runner
(memory_graph.test.js); this wrapper shells out to `node --test`. The static
checks pin how the map, side panel, recalls list and chat chip are wired.
"""
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
STATIC = REPO_ROOT / "webui" / "static"
TEST_FILE = STATIC / "memory_graph.test.js"


def _read(name):
    return (STATIC / name).read_text(encoding="utf-8")


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
def test_memory_graph_js_node_tests_pass():
    result = subprocess.run(
        ["node", "--test", str(TEST_FILE)],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert result.returncode == 0, (
        f"node --test failed for memory_graph.test.js\n"
        f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    )


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
@pytest.mark.parametrize("name", ["memory_graph.js", "memory_map.js", "jarvis_memory.js"])
def test_scripts_parse(name):
    result = subprocess.run(["node", "--check", str(STATIC / name)], capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stderr


def test_scripts_loaded_in_order():
    html = _read("index.html")
    graph = html.index("static/memory_graph.js?v=__WEBUI_VERSION__")
    mapjs = html.index("static/memory_map.js?v=__WEBUI_VERSION__")
    panel = html.index("static/jarvis_memory.js?v=__WEBUI_VERSION__")
    assert graph < mapjs < panel


def test_map_uses_the_contract_endpoints():
    js = _read("memory_map.js")
    for path in (
        "api/jarvis-memory/entity?id=",
        "api/jarvis-memory/entity/merge",
        "api/jarvis-memory/entity/unlink",
        "api/jarvis-memory/graph/highlight?recall=",
    ):
        assert path in js, path
    assert '"api/jarvis-memory/entity"' in js  # rename / aliases / pin
    assert "var G = window.MemoryGraph" in js
    assert "G.graphUrl(" in js
    assert "G.mergeGraph(" in js
    assert "function esc(" in js
    # The animation loop stops when settled and when the panel is hidden.
    assert "G.isSettled(" in js
    assert "cancelAnimationFrame" in js


def test_panel_has_map_list_switch_recalls_and_chat_chip():
    js = _read("jarvis_memory.js")
    assert "jmemViewMap" in js and "jmemViewList" in js
    assert "MemoryGraph.recallsUrl" in js
    assert "jmemRecalls" in js
    # Chat chip: one request per chat (cached), matched by user text, never breaks rendering.
    assert "MemoryGraph.matchRecalls" in js
    assert "jmem-recall-chip" in js
    assert "MutationObserver" in js
