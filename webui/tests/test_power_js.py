"""JCPower (static/power.js): state and gating logic, run with node --test."""
import shutil
import subprocess
from pathlib import Path

import pytest

TEST_FILE = Path(__file__).resolve().parents[1] / "static" / "power.test.js"


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
def test_power_js_node_tests_pass():
    result = subprocess.run(["node", "--test", str(TEST_FILE)], capture_output=True, text=True,
                            timeout=60, cwd=str(TEST_FILE.parent))
    assert result.returncode == 0, result.stdout + result.stderr
