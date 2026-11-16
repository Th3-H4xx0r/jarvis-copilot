"""PC Stats on the web (webui/static/pc_stats*.js): node tests + the page and Agents wiring."""
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
STATIC = REPO_ROOT / "webui" / "static"


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
def test_pc_stats_js_node_tests_pass():
    result = subprocess.run(["node", "--test", str(STATIC / "pc_stats.test.js")], cwd=str(REPO_ROOT),
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
def test_pc_stats_scripts_parse():
    for name in ("pc_stats_core.js", "pc_stats.js", "pc_stats_edit.js"):
        result = subprocess.run(["node", "--check", str(STATIC / name)], capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, f"{name}: {result.stderr}"


def test_page_loads_pc_stats_in_order_before_agents():
    html = (STATIC / "index.html").read_text()
    assert "static/pc_stats.css" in html
    order = [html.index(f"static/{n}") for n in ("pc_stats_core.js", "pc_stats.js", "pc_stats_edit.js", "agents.js")]
    assert order == sorted(order)


def test_agents_card_is_gated_and_opens_the_page():
    agents = (STATIC / "agents.js").read_text()
    assert "JCPcStats.cardHtml(m)" in agents and "JCPcStats.open(" in agents
    page = (STATIC / "pc_stats.js").read_text()
    assert "isOn('pc-stats')" in page and 'data-power="pc-stats"' in page
    assert "pcStats.active" in page
