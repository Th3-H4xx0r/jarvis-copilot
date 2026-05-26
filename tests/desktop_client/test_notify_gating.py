from __future__ import annotations
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "desktop_client"))


def _allowed():
    from jc_client import cli
    return cli._notify_allowed


def test_manual_always_fires():
    a = _allowed()
    assert a("off", "manual") is True
    assert a("input", "manual") is True


def test_off_blocks_hook_events():
    a = _allowed()
    assert a("off", "notification") is False
    assert a("off", "stop") is False


def test_input_only_passes_notification():
    a = _allowed()
    assert a("input", "notification") is True
    assert a("input", "stop") is False


def test_stop_only_passes_stop():
    a = _allowed()
    assert a("stop", "stop") is True
    assert a("stop", "notification") is False


def test_all_passes_everything():
    a = _allowed()
    assert a("all", "notification") is True
    assert a("all", "stop") is True
    assert a("", "stop") is True  # default → all
