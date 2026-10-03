"""Answered-by line + background replies (agent harnesses, plan Task 16).

The formatting logic lives in webui/static/harness_format.js and is tested
with node's built-in runner (harness_format.test.js); this wrapper shells out
to `node --test` so it runs with the rest of pytest. The static checks below
pin the seams in messages.js / ui.js / sessions.js that use it.
"""
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
STATIC = REPO_ROOT / "webui" / "static"
TEST_FILE = STATIC / "harness_format.test.js"


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
def test_harness_format_js_node_tests_pass():
    result = subprocess.run(
        ["node", "--test", str(TEST_FILE)],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert result.returncode == 0, (
        f"node --test failed for harness_format.test.js\n"
        f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    )


def _read(name):
    return (STATIC / name).read_text(encoding="utf-8")


def test_format_script_loaded_and_precached():
    assert "static/harness_format.js" in _read("index.html")
    assert "harness_format.js" in _read("sw.js")


def test_live_stream_keeps_turn_meta_for_the_final_message():
    js = _read("messages.js")
    assert "addEventListener('turn_meta'" in js
    done = js.index("source.addEventListener('done'")
    assert "_liveTurnMeta" in js[done:done + 6000]


def test_footer_renders_answered_by_and_marks_side_replies():
    ui = _read("ui.js")
    assert "HarnessFormat.answeredBy" in ui
    assert "msg-answered-by" in ui
    assert "HarnessFormat.isSideReply" in ui
    assert ".msg-answered-by" in _read("style.css")
    assert ".assistant-turn.harness-side" in _read("style.css")


def test_mirror_appends_harness_results():
    js = _read("sessions.js")
    i = js.index("es.addEventListener('harness_result'")
    block = js[i:i + 1200]
    assert "d.session_id" in block and "renderMessages" in block
