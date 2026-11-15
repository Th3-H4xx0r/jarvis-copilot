"""Holo Drop on the web (webui/static/holo_drop.js): node tests + the page wiring."""
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
STATIC = REPO_ROOT / "webui" / "static"


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
def test_holo_drop_js_node_tests_pass():
    result = subprocess.run(["node", "--test", str(STATIC / "holo_drop.test.js")], cwd=str(REPO_ROOT),
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"


def test_page_loads_holo_drop_and_gates_its_button():
    html = (STATIC / "index.html").read_text()
    assert 'static/holo_drop.js' in html
    assert 'data-power="holo-drop"' in html and "JCHoloDrop.openOrbit()" in html


def test_power_page_link_opens_the_web_orbit():
    js = (STATIC / "power.js").read_text()
    assert "holo_drop" in js and "JCHoloDrop" in js
