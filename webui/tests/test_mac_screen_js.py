"""The web UI's Mac screen card (static/mac_screen.js): node unit tests, and the
script is loaded before ui.js draws tool cards."""
import shutil
import subprocess
from pathlib import Path

import pytest

STATIC = Path(__file__).parent.parent.resolve() / "static"
NODE = shutil.which("node")


@pytest.mark.skipif(NODE is None, reason="node not on PATH")
def test_mac_screen_node_unit_tests_pass():
    out = subprocess.run([NODE, "--test", str(STATIC / "mac_screen.test.js")],
                         capture_output=True, text=True, timeout=30)
    assert out.returncode == 0, out.stdout + out.stderr


def test_index_loads_mac_screen_and_computer_cards_use_it():
    html = (STATIC / "index.html").read_text(encoding="utf-8")
    assert 'static/mac_screen.js' in html
    assert html.index('static/mac_screen.js') < html.index('static/ui.js')
    ui = (STATIC / "ui.js").read_text(encoding="utf-8")
    assert "tc.name==='computer_do'" in ui and "MacScreen.toolRow" in ui
