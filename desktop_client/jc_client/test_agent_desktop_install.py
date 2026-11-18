"""agent-desktop install: a SHA-pinned release, verified before anything is written."""
from __future__ import annotations

import hashlib
import io
import os
import tarfile

import pytest

from jc_client import agent_desktop_install as adi


def _archive(members: dict) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for name, body in members.items():
            info = tarfile.TarInfo(name)
            info.size = len(body)
            tf.addfile(info, io.BytesIO(body))
    return buf.getvalue()


def _pin(monkeypatch, data: bytes, key=("darwin", "arm64"), asset="agent-desktop-test.tar.gz"):
    monkeypatch.setitem(adi.ASSETS, key, (asset, hashlib.sha256(data).hexdigest()))


def test_installs_and_verifies(tmp_path, monkeypatch):
    data = _archive({"agent-desktop": b"#!bin", "agent-desktop-macos-helper": b"helper"})
    _pin(monkeypatch, data)
    urls = []
    path = adi.ensure_agent_desktop(str(tmp_path), opener=lambda u: urls.append(u) or data,
                                    plat="darwin", machine="arm64")
    assert path == adi.installed_path(str(tmp_path), plat="darwin")
    assert os.access(path, os.X_OK)
    assert os.path.isfile(os.path.join(os.path.dirname(path), "agent-desktop-macos-helper"))
    assert urls == ["https://github.com/vercel-labs/agent-desktop/releases/download/v1.3.1/agent-desktop-test.tar.gz"]


def test_checksum_mismatch_installs_nothing(tmp_path, monkeypatch):
    _pin(monkeypatch, b"the real archive")
    bad = _archive({"agent-desktop": b"evil"})
    with pytest.raises(ValueError, match="agent-desktop checksum mismatch"):
        adi.ensure_agent_desktop(str(tmp_path), opener=lambda u: bad, plat="darwin", machine="arm64")
    assert adi.installed_path(str(tmp_path), plat="darwin") is None


def test_already_installed_skips_download(tmp_path, monkeypatch):
    data = _archive({"agent-desktop": b"#!bin"})
    _pin(monkeypatch, data)
    adi.ensure_agent_desktop(str(tmp_path), opener=lambda u: data, plat="darwin", machine="arm64")
    calls = []
    adi.ensure_agent_desktop(str(tmp_path), opener=lambda u: calls.append(u) or data, plat="darwin", machine="arm64")
    assert calls == []


def test_unsupported_platform_returns_none(tmp_path):
    calls = []
    assert adi.ensure_agent_desktop(str(tmp_path), opener=lambda u: calls.append(u) or b"",
                                    plat="linux", machine="x86_64") is None
    assert calls == []


def test_only_known_members_extracted(tmp_path, monkeypatch):
    data = _archive({"../evil": b"x", "sub/agent-desktop": b"#!bin", "README": b"r"})
    _pin(monkeypatch, data)
    path = adi.ensure_agent_desktop(str(tmp_path), opener=lambda u: data, plat="darwin", machine="arm64")
    assert sorted(os.listdir(os.path.dirname(path))) == ["agent-desktop"]
    assert not (tmp_path / "evil").exists() and not (tmp_path / "bin" / "evil").exists()


def test_windows_binary_name(tmp_path, monkeypatch):
    data = _archive({"agent-desktop.exe": b"MZ"})
    _pin(monkeypatch, data, key=("win32", "AMD64"))
    path = adi.ensure_agent_desktop(str(tmp_path), opener=lambda u: data, plat="win32", machine="AMD64")
    assert path.endswith(os.path.join("agent-desktop-1.3.1", "agent-desktop.exe"))


def test_pins_cover_his_machines():
    assert set(adi.ASSETS) >= {("darwin", "arm64"), ("win32", "AMD64")}
    for asset, sha in adi.ASSETS.values():
        assert asset.startswith("agent-desktop-v1.3.1-") and len(sha) == 64


def test_update_survives_install_failure(monkeypatch, capsys):
    from jc_client import cli

    def boom(*a, **k):
        raise ValueError("agent-desktop checksum mismatch")

    monkeypatch.setattr(adi, "ensure_agent_desktop", boom)
    cli._ensure_agent_desktop_quiet()  # must not raise
    assert "agent-desktop" in capsys.readouterr().err


def test_install_dir_inherits_its_parents_permissions(tmp_path, monkeypatch):
    # tempfile.mkdtemp gives an owner-only ACL on Windows: installed from an elevated shell, the
    # owner is Administrators and the (non-elevated) service can't even see the binary.
    data = _archive({"agent-desktop": b"#!bin"})
    _pin(monkeypatch, data)

    def no_mkdtemp(*a, **k):
        raise AssertionError("mkdtemp makes an owner-only dir")

    monkeypatch.setattr("tempfile.mkdtemp", no_mkdtemp)
    path = adi.ensure_agent_desktop(str(tmp_path), opener=lambda u: data, plat="darwin", machine="arm64")
    assert path and os.path.isfile(path)
    assert not [n for n in os.listdir(tmp_path / "bin") if n.startswith(".agent-desktop")]  # no temp left
