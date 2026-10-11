"""Background-job cards in the web chat (agent harnesses).

The card logic lives in webui/static/harness_jobs.js and is tested with node's
built-in runner (harness_jobs.test.js); this wrapper shells out to `node --test`.
The static checks pin the seams that use it: the page loads it, the chat draws
cards under replies and the session event stream feeds it live changes.
"""
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
STATIC = REPO_ROOT / "webui" / "static"


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
def test_harness_jobs_js_node_tests_pass():
    result = subprocess.run(["node", "--test", str(STATIC / "harness_jobs.test.js")],
                            cwd=str(REPO_ROOT), capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"


def _read(name):
    return (STATIC / name).read_text(encoding="utf-8")


def test_jobs_script_loaded_after_the_formatter_and_precached():
    html = _read("index.html")
    assert "static/harness_jobs.js?v=__WEBUI_VERSION__" in html
    assert html.index("static/harness_format.js") < html.index("static/harness_jobs.js")
    assert "'./static/harness_jobs.js' + VQ" in _read("sw.js")


def test_chat_draws_job_cards_under_replies():
    js = _read("ui.js")
    assert "HarnessJobs.renderInto(" in js and "_meta.jobs" in js


def test_session_events_feed_live_job_changes():
    js = _read("sessions.js")
    start = js.index("es.addEventListener('harness_job'")
    assert "HarnessJobs.apply(" in js[start:start + 600]


def test_job_card_styles_exist():
    css = _read("style.css")
    for sel in (".harness-job ", ".harness-job-running", ".harness-job-stop", ".harness-job-clock"):
        assert sel in css


def test_a_cached_chat_redraws_its_cards():
    js = _read("ui.js")
    cached = js[js.index("inner.innerHTML=cached.html;"):]
    cached = cached[:cached.index("return;")]
    assert "HarnessJobs.refresh()" in cached


def test_a_reconnect_catches_job_cards_up():
    js = _read("sessions.js")
    start = js.index("es.addEventListener('snapshot'")
    assert "HarnessJobs.catchUp(" in js[start:start + 700]
