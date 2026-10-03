"""Harnesses panel + canvas editor (agent harnesses, plan Task 17).

Graph edits live in webui/static/harness_graph.js and are tested with node's
built-in runner (harness_graph.test.js); this wrapper shells out to
`node --test`. The static checks pin how the panel is wired into the page.
"""
import re
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
STATIC = REPO_ROOT / "webui" / "static"
TEST_FILE = STATIC / "harness_graph.test.js"


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
def test_harness_graph_js_node_tests_pass():
    result = subprocess.run(
        ["node", "--test", str(TEST_FILE)],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert result.returncode == 0, (
        f"node --test failed for harness_graph.test.js\n"
        f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    )


def _read(name):
    return (STATIC / name).read_text(encoding="utf-8")


def test_editor_scripts_loaded_and_precached():
    html, sw = _read("index.html"), _read("sw.js")
    for name in ("harness_graph.js", "harness_editor.js"):
        assert f"static/{name}?v=__WEBUI_VERSION__" in html
        assert f"'./static/{name}' + VQ" in sw


def test_harnesses_panel_markup_and_settings_entry():
    html = _read("index.html")
    assert 'id="mainHarnesses"' in html
    menu = html[html.index('id="settingsMenu"'):html.index("</div>", html.index('id="settingsMenu"'))]
    assert "HarnessEditor.open()" in menu


def test_switch_panel_shows_and_loads_harnesses():
    js = _read("panels.js")
    start = js.index("async function switchPanel(")
    body = js[start:js.index("\n}\n", start)]
    showing = re.search(r"\[([^\]]*'live'[^\]]*)\]\.forEach\(p => \{", body)
    assert showing and "'harnesses'" in showing.group(1)
    assert "HarnessEditor.load" in body
    css = _read("style.css")
    assert "main.main.showing-harnesses > #mainHarnesses" in css
    assert ":not(.showing-harnesses)" in css


def test_editor_escapes_and_posts_designs():
    js = _read("harness_editor.js")
    assert "api/harnesses/designs" in js
    assert "HarnessGraph.toDesign" in js
    assert "function esc(" in js
    # Built-ins open read-only and are duplicated before editing.
    assert "HarnessGraph.duplicate" in js
