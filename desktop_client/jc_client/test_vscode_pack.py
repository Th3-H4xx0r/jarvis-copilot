"""Packing + installing the Jarvis Terminal Bridge VS Code extension."""
import json
import os
import shutil
import stat
import tempfile
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

import pytest

from jc_client import vscode_pack

EXT_DIR = Path(__file__).resolve().parents[1] / "vscode_extension"
VSX = "{http://schemas.microsoft.com/developer/vsx-schema/2011}"


@pytest.fixture
def home(monkeypatch):
    d = tempfile.mkdtemp(prefix="jvp")
    monkeypatch.setenv("HOME", d)
    yield Path(d)
    shutil.rmtree(d, ignore_errors=True)


def _fake_code(tmp: Path, rc: int = 0) -> Path:
    """A stand-in `code` CLI that records its arguments."""
    script = tmp / "code"
    script.write_text(f'#!/bin/sh\necho "$@" > "{tmp}/code-args"\nexit {rc}\n')
    script.chmod(script.stat().st_mode | stat.S_IXUSR)
    return script


def test_vsix_contains_manifest_and_extension_js(tmp_path):
    out = vscode_pack.build_vsix(str(EXT_DIR), str(tmp_path / "x.vsix"))
    assert out == str(tmp_path / "x.vsix")
    pkg = json.loads((EXT_DIR / "package.json").read_text())
    with zipfile.ZipFile(out) as z:
        names = set(z.namelist())
        assert {"extension.vsixmanifest", "[Content_Types].xml", "extension/package.json",
                "extension/extension.js", "extension/README.md"} <= names
        assert z.read("extension/extension.js") == (EXT_DIR / "extension.js").read_bytes()
        assert json.loads(z.read("extension/package.json")) == pkg
        manifest = ET.fromstring(z.read("extension.vsixmanifest"))
        types = ET.fromstring(z.read("[Content_Types].xml"))
    assert manifest.tag == VSX + "PackageManifest" and manifest.get("Version") == "2.0.0"
    ident = manifest.find(f"{VSX}Metadata/{VSX}Identity")
    assert ident.get("Id") == pkg["name"]
    assert ident.get("Publisher") == pkg["publisher"]
    assert ident.get("Version") == pkg["version"]
    assert manifest.find(f"{VSX}Metadata/{VSX}DisplayName").text == pkg["displayName"]
    target = manifest.find(f"{VSX}Installation/{VSX}InstallationTarget")
    assert target.get("Id") == "Microsoft.VisualStudio.Code"
    assets = {a.get("Type"): a.get("Path") for a in manifest.iter(VSX + "Asset")}
    assert assets["Microsoft.VisualStudio.Code.Manifest"] == "extension/package.json"
    exts = {d.get("Extension") for d in types}
    assert {".json", ".js", ".md", ".vsixmanifest"} <= exts


def test_package_json_identity():
    pkg = json.loads((EXT_DIR / "package.json").read_text())
    assert f'{pkg["publisher"]}.{pkg["name"]}' == "jarviscopilot.jarvis-terminal-bridge"
    assert pkg["main"] == "./extension.js"
    assert "onStartupFinished" in pkg["activationEvents"]
    assert not pkg.get("dependencies")  # vscode API + node stdlib only


def test_install_extension_without_vscode_returns_reason(home, monkeypatch):
    monkeypatch.setattr(vscode_pack.shutil, "which", lambda name: None)
    monkeypatch.setattr(vscode_pack, "_APP_CODE_BINS", ())
    ok, reason = vscode_pack.install_extension()
    assert ok is False
    assert "VS Code" in reason


def test_install_extension_runs_code_cli(home, tmp_path):
    code = _fake_code(tmp_path)
    ok, detail = vscode_pack.install_extension(str(code))
    assert ok is True, detail
    vsix = home / ".jarviscopilot-client" / "jarvis-terminal-bridge.vsix"
    assert zipfile.is_zipfile(vsix)
    args = (tmp_path / "code-args").read_text().split()
    assert args == ["--install-extension", str(vsix), "--force"]


def test_install_extension_reports_cli_failure(home, tmp_path):
    code = _fake_code(tmp_path, rc=3)
    ok, detail = vscode_pack.install_extension(str(code))
    assert ok is False and detail


def test_install_extension_skips_when_already_current(home, tmp_path):
    pkg = json.loads((EXT_DIR / "package.json").read_text())
    dest = home / ".vscode" / "extensions" / f'{pkg["publisher"]}.{pkg["name"]}-{pkg["version"]}'
    dest.mkdir(parents=True)
    # VS Code stamps __metadata into the installed package.json.
    (dest / "package.json").write_text(json.dumps(dict(pkg, __metadata={"installedTimestamp": 1})))
    shutil.copy(EXT_DIR / "extension.js", dest / "extension.js")
    code = _fake_code(tmp_path)
    ok, detail = vscode_pack.install_extension(str(code))
    assert ok is True and "up to date" in detail
    assert not (tmp_path / "code-args").exists()

    # Marked for removal by VS Code (uninstalled) → install again.
    (home / ".vscode" / "extensions" / ".obsolete").write_text(
        json.dumps({f'{pkg["publisher"]}.{pkg["name"]}-{pkg["version"]}': True}))
    ok, _ = vscode_pack.install_extension(str(code))
    assert ok is True and (tmp_path / "code-args").exists()


def test_install_extension_never_raises(home, monkeypatch):
    def boom(*a, **kw):
        raise RuntimeError("disk full")

    monkeypatch.setattr(vscode_pack, "build_vsix", boom)
    ok, detail = vscode_pack.install_extension("/bin/true")
    assert ok is False and "disk full" in detail


def test_update_reports_the_bridge_install_in_one_line(monkeypatch, capsys):
    pytest.importorskip("wsproto")  # cli imports the client's protocol stack
    from jc_client import cli

    monkeypatch.setattr(vscode_pack, "install_extension", lambda: (True, "installed"))
    cli._install_vscode_bridge_quiet()
    out, err = capsys.readouterr()
    assert out.strip().count("\n") == 0 and "installed" in out and err == ""

    monkeypatch.setattr(vscode_pack, "install_extension", lambda: (False, "no VS Code"))
    cli._install_vscode_bridge_quiet()
    out, err = capsys.readouterr()
    assert out == "" and err.strip().count("\n") == 0 and "no VS Code" in err

    def boom():
        raise RuntimeError("weird")

    monkeypatch.setattr(vscode_pack, "install_extension", boom)
    cli._install_vscode_bridge_quiet()  # best-effort: never raises
    assert "weird" in capsys.readouterr().err
