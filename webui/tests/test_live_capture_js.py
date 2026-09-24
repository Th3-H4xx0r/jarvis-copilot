"""Runs the browser Live capture unit tests (webui/static/live_capture.test.js) under pytest.

Same arrangement as test_voice_js_endpoint.py: the logic is tested with node's
built-in runner (no npm deps) and this wrapper puts it in the pytest run.
"""
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
TEST_FILE = REPO_ROOT / "webui" / "static" / "live_capture.test.js"


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
def test_live_capture_js_node_tests_pass():
    result = subprocess.run(["node", "--test", str(TEST_FILE)], cwd=str(REPO_ROOT),
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, (
        f"node --test failed for live_capture.test.js\n"
        f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}")
