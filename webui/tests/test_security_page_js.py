"""Security page (Security Advisor, plan Task 8).

The pure helpers in webui/static/security.js are tested with node's built-in
runner (security.test.js); this wrapper shells out to `node --test`. The static
checks pin how the page is wired into the app shell.
"""
import re
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
STATIC = REPO_ROOT / "webui" / "static"


def _read(name):
    return (STATIC / name).read_text(encoding="utf-8")


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
def test_security_js_node_tests_pass():
    result = subprocess.run(
        ["node", "--test", str(STATIC / "security.test.js")],
        cwd=str(REPO_ROOT), capture_output=True, text=True, timeout=60,
    )
    assert result.returncode == 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"


def test_page_is_in_the_navigation_and_loaded():
    html = _read("index.html")
    assert 'data-panel="security"' in html          # rail + sidebar nav (More on the phone shell)
    assert 'id="mainSecurity"' in html and 'id="securityContent"' in html
    assert "static/security.js?v=__WEBUI_VERSION__" in html
    assert "static/security.css?v=__WEBUI_VERSION__" in html


def test_switch_panel_shows_and_loads_security():
    js = _read("panels.js")
    start = js.index("async function switchPanel(")
    body = js[start:js.index("\n}\n", start)]
    showing = re.search(r"\[([^\]]*'live'[^\]]*)\]\.forEach\(p => \{", body)
    assert showing and "'security'" in showing.group(1)
    assert "loadSecurity()" in body
    css = _read("style.css")
    assert "main.main.showing-security > #mainSecurity" in css
    assert ":not(.showing-security)" in css


def test_block_and_allow_are_left_to_the_phone():
    # Face ID lives on the iPhone: the web page never posts block/allow.
    js = _read("security.js")
    assert "action: 'dismiss'" in js
    assert "action: 'block'" not in js and "action: 'allow'" not in js
