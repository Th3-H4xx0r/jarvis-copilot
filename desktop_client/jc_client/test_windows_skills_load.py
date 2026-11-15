"""On the PC: the island and VS Code skills load, and npx is found where Node puts it."""
import importlib
import os
import sys

from jc_client import mcp_relay, skills


def test_island_and_vscode_load_on_win32(monkeypatch):
    monkeypatch.setattr(skills.sys, "platform", "win32")
    saved = dict(skills._REGISTRY)
    try:
        skills._REGISTRY.clear()
        for mod in ("jc_client.skills.island", "jc_client.skills.vscode"):
            sys.modules.pop(mod, None)
        skills.load_all()
        assert skills.has_skill("jarvis_island")
        assert skills.has_skill("vscode_run")
    finally:
        skills._REGISTRY.clear()
        skills._REGISTRY.update(saved)
        for mod in ("jc_client.skills.island", "jc_client.skills.vscode"):
            importlib.import_module(mod)


def test_find_npx_windows_locations(monkeypatch, tmp_path):
    monkeypatch.setattr(mcp_relay.sys, "platform", "win32")
    monkeypatch.setattr(mcp_relay.shutil, "which", lambda name: None)
    node = tmp_path / "nodejs"
    node.mkdir()
    (node / "npx.cmd").write_text("@echo off\n")
    monkeypatch.setenv("ProgramFiles", str(tmp_path))
    monkeypatch.setenv("APPDATA", str(tmp_path / "nope"))
    assert mcp_relay.find_npx() == str(node / "npx.cmd")
    os.remove(node / "npx.cmd")
    assert mcp_relay.find_npx() is None
