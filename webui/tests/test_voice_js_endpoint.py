"""Runs the pure-JS adaptive-endpointer unit tests (plan 1.1) under pytest.

The actual test logic lives in webui/static/voice_endpoint.test.js and is
exercised with node's built-in test runner (no npm deps). This wrapper just
shells out to `node --test` so the JS-logic tests show up in the same pytest
run as everything else, per the "test_voice_js_*.py" naming convention.
"""
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
TEST_FILE = REPO_ROOT / "webui" / "static" / "voice_endpoint.test.js"


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
def test_voice_endpoint_js_node_tests_pass():
    result = subprocess.run(
        ["node", "--test", str(TEST_FILE)],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert result.returncode == 0, (
        f"node --test failed for voice_endpoint.test.js\n"
        f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    )
