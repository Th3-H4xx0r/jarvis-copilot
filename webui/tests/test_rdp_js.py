"""Remote Desktop on the web (webui/static/rdp*.js): node tests, the vendored client, the page and
Agents wiring."""
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
STATIC = REPO_ROOT / "webui" / "static"
VENDOR = STATIC / "vendor" / "guacamole-common-1.5.5.min.js"


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
def test_rdp_js_node_tests_pass():
    result = subprocess.run(["node", "--test", str(STATIC / "rdp.test.js")], cwd=str(REPO_ROOT),
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
def test_rdp_scripts_parse():
    for name in ("rdp_core.js", "rdp.js"):
        result = subprocess.run(["node", "--check", str(STATIC / name)], capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, f"{name}: {result.stderr}"


def test_vendored_guacamole_is_the_pinned_version_with_its_licence():
    head = VENDOR.read_text()[:2000]
    assert "Licensed to the Apache Software Foundation" in head
    assert "guacamole-common-js 1.5.5" in head and "744a82354317a33d416a181a07eec20a3d8a2486" in head
    assert "Guacamole.WebSocketTunnel" in VENDOR.read_text()


def test_page_loads_rdp_in_order_and_the_card_opens_it():
    html = (STATIC / "index.html").read_text()
    assert "static/rdp.css" in html
    order = [html.index(f"static/{n}") for n in
             ("vendor/guacamole-common-1.5.5.min.js", "rdp_core.js", "rdp.js", "agents.js")]
    assert order == sorted(order)
    agents = (STATIC / "agents.js").read_text()
    assert "'rdp-open'" in agents and "JCRdp.open(" in agents and "isOn('remote-desktop')" in agents
    page = (STATIC / "rdp.js").read_text()
    assert 'data-power", "remote-desktop"' in page or "data-power', 'remote-desktop'" in page
