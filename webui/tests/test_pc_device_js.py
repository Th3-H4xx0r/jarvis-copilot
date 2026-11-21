"""The Devices panel's PC card on the web (webui/static/pc_device.js) + the shared Agents controls."""
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
STATIC = REPO_ROOT / "webui" / "static"


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
def test_pc_device_node_tests_pass():
    result = subprocess.run(["node", "--test", str(STATIC / "pc_device.test.js")], cwd=str(REPO_ROOT),
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"


def test_page_loads_pc_device_after_agents_and_before_devices():
    html = (STATIC / "index.html").read_text()
    order = [html.index(f"static/{n}") for n in ("agents.js", "pc_device.js", "devices.js")]
    assert order == sorted(order)


def test_agents_exports_its_pc_controls_and_devices_mounts_the_card():
    agents = (STATIC / "agents.js").read_text()
    assert "window.JCMacControls" in agents and "if (macAct(t)) return;" in agents
    devices = (STATIC / "devices.js").read_text()
    assert "JCPcDevice.mount(" in devices
