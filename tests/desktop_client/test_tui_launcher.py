"""Tests for `jc-client tui` (the local Ink TUI launcher)."""
from __future__ import annotations

import importlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "desktop_client"))


def _tl():
    from jc_client import tui_launcher
    importlib.reload(tui_launcher)
    return tui_launcher


class _Paired:
    server_url = "https://hermes:8787"
    cookie = "C"
    cert_fingerprint = "AB"

    @property
    def paired(self):
        return True


class _Unpaired:
    server_url = ""
    cookie = ""
    cert_fingerprint = ""

    @property
    def paired(self):
        return False


class _FakeProxy:
    instances = []

    def __init__(self, *a):
        self.shut = False
        _FakeProxy.instances.append(self)

    def start(self):
        return 7777

    def shutdown(self):
        self.shut = True


def test_attach_url():
    tl = _tl()
    assert tl.gateway_attach_url(7777) == "ws://127.0.0.1:7777/api/tui/ws"


def test_dist_stale_when_source_newer(tmp_path):
    tl = _tl()
    uidir = tmp_path / "ui-tui"
    (uidir / "dist").mkdir(parents=True)
    entry = uidir / "dist" / "entry.js"
    entry.write_text("//", encoding="utf-8")
    (uidir / "src").mkdir()
    src = uidir / "src" / "banner.ts"
    src.write_text("x", encoding="utf-8")
    import os
    # Make the source newer than the bundle.
    os.utime(entry, (1, 1))
    os.utime(src, (10_000, 10_000))
    assert tl._dist_is_stale(uidir, entry) is True
    # And not stale when the bundle is newer.
    os.utime(entry, (20_000, 20_000))
    assert tl._dist_is_stale(uidir, entry) is False


def test_noop_when_unpaired(monkeypatch):
    tl = _tl()
    monkeypatch.setattr(tl.credentials, "load", lambda: _Unpaired())

    def boom(*a, **k):
        raise AssertionError("nothing should launch when unpaired")

    monkeypatch.setattr(tl, "PinnedProxy", boom)
    assert tl.run_tui() == 1


def test_errors_when_node_missing(monkeypatch):
    tl = _tl()
    monkeypatch.setattr(tl.credentials, "load", lambda: _Paired())
    monkeypatch.setattr(tl.shutil, "which", lambda n: None)  # node absent

    def boom(*a, **k):
        raise AssertionError("no proxy without node")

    monkeypatch.setattr(tl, "PinnedProxy", boom)
    assert tl.run_tui() == 1


def test_launches_uitui_with_attach_env(monkeypatch, tmp_path):
    tl = _tl()
    _FakeProxy.instances = []
    monkeypatch.setattr(tl.credentials, "load", lambda: _Paired())
    monkeypatch.setattr(tl.shutil, "which", lambda n: "/usr/bin/node")
    monkeypatch.setattr(tl, "PinnedProxy", _FakeProxy)
    # Pretend a built ui-tui exists.
    uidir = tmp_path / "ui-tui"
    (uidir / "dist").mkdir(parents=True)
    (uidir / "dist" / "entry.js").write_text("//", encoding="utf-8")
    monkeypatch.setattr(tl, "_uitui_dir", lambda: uidir)

    captured = {}

    def fake_run(cmd, cwd=None, env=None):
        captured["cmd"] = cmd
        captured["cwd"] = str(cwd)
        captured["env"] = env

        class R:
            returncode = 0
        return R()

    monkeypatch.setattr(tl.subprocess, "run", fake_run)
    rc = tl.run_tui()
    assert rc == 0
    assert captured["env"]["HERMES_TUI_GATEWAY_URL"] == "ws://127.0.0.1:7777/api/tui/ws"
    assert captured["cmd"][0] == "/usr/bin/node"
    assert str(captured["cmd"][1]).endswith("dist/entry.js")
    assert _FakeProxy.instances[0].shut is True
