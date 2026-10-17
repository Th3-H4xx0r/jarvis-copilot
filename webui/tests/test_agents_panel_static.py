"""The web Agents panel replaces the Coding panel (agents + coding merge,
plan Task 14). Static checks over the shipped files: the panel is wired in,
the old panel is gone, the standalone terminal page loads the shared mount,
and the new scripts parse."""
import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1] / "static"


def _read(name):
    return (ROOT / name).read_text(encoding="utf-8")


def test_index_loads_agents_scripts_not_coding():
    html = _read("index.html")
    assert "static/agents.js" in html
    assert "static/agents_terminal.js" in html
    assert "coding.js" not in html
    # the terminal module loads before the panel that mounts it
    assert html.index("static/agents_terminal.js") < html.index("static/agents.js")


def test_index_has_agents_view_and_nav():
    html = _read("index.html")
    assert 'id="mainAgents"' in html
    assert 'id="mainCoding"' not in html
    assert html.count('data-panel="agents"') >= 2          # desktop rail + mobile nav
    assert 'data-panel="coding"' not in html


def test_old_coding_panel_is_deleted():
    assert not (ROOT / "coding.js").exists()


def test_panels_registers_agents_and_keeps_coding_alias():
    js = _read("panels.js")
    assert "loadAgents" in js and "onAgentsPanelLeave" in js
    assert re.search(r"name === 'coding' \? 'agents'", js), "old 'coding' links must still open Agents"
    assert "loadCoding" not in js and "onCodingPanelLeave" not in js
    i = js.index("async function switchPanel(")
    body = js[i:i + 6000]
    assert "'agents'" in body


def test_agents_view_is_shown_only_on_its_page():
    css = _read("style.css")
    assert "main.main.showing-agents > #mainAgents{display:flex" in css
    assert "main.main > #mainAgents," in css
    assert ":not(.showing-agents)" in css
    assert ".cdg-" not in css, "the Coding panel's rules should go with it"


def test_agents_entry_points_exported():
    js = _read("agents.js")
    assert "window.loadAgents" in js
    assert "window.onAgentsPanelLeave" in js
    # polls only while the panel is visible: stops on leave and on a hidden tab
    assert "visibilitychange" in js
    assert "/agents/list" in js


def test_terminal_module_shape():
    js = _read("agents_terminal.js")
    assert "window.AgentsTerminal" in js
    for name in ("mount", "close"):
        assert re.search(r"\b%s\b" % name, js)
    assert "/api/terminal/output" in js
    assert "requestAnimationFrame" in js          # batched writes, lifted from coding.js


def test_standalone_terminal_page():
    page = _read("agents_terminal.html")
    assert "static/agents_terminal.js" in page
    assert "terminal_id" in page
    assert "xterm@5.3.0" in page
    assert "<base" in page                         # API calls resolve at the app root


def test_i18n_has_tab_agents():
    js = _read("i18n.js")
    assert "tab_agents:" in js
    assert "tab_coding:" not in js


@pytest.mark.parametrize("name", ["agents.js", "agents_terminal.js"])
def test_node_check_passes(name):
    node = shutil.which("node")
    if not node:
        pytest.skip("node is not installed")
    res = subprocess.run([node, "--check", str(ROOT / name)], capture_output=True, text=True, timeout=60)
    assert res.returncode == 0, res.stderr
