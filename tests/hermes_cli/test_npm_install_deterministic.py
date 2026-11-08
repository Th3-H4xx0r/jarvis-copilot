"""Tests for _run_npm_install_deterministic (used by `jarviscopilot update`)."""

import subprocess
from unittest.mock import patch

from jarviscopilot_cli.main import _run_npm_install_deterministic


def test_npm_install_uses_utf8_replace_output_decoding(tmp_path):
    pkg_dir = tmp_path / "ui-tui"
    pkg_dir.mkdir()
    (pkg_dir / "package.json").touch()
    (pkg_dir / "package-lock.json").write_text("{}", encoding="utf-8")

    mock_cp = subprocess.CompletedProcess([], 0, stdout="", stderr="")
    with patch("jarviscopilot_cli.main.subprocess.run", return_value=mock_cp) as mock_run:
        result = _run_npm_install_deterministic("/usr/bin/npm", pkg_dir)

    assert result.returncode == 0
    _, kwargs = mock_run.call_args
    assert kwargs["text"] is True
    assert kwargs["encoding"] == "utf-8"
    assert kwargs["errors"] == "replace"
