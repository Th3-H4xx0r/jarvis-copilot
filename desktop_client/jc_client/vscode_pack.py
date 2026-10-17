"""Pack and install the Jarvis Terminal Bridge VS Code extension.

A .vsix is a zip: an ``extension.vsixmanifest``, a ``[Content_Types].xml`` and
the extension's files under ``extension/``. This writes one with ``zipfile``
alone (no vsce, no node) from ``desktop_client/vscode_extension`` and hands it
to VS Code's ``code --install-extension``.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import zipfile
from pathlib import Path
from typing import Optional
from xml.sax.saxutils import escape, quoteattr

EXT_DIR = Path(__file__).resolve().parents[1] / "vscode_extension"
VSIX_NAME = "jarvis-terminal-bridge.vsix"
_FILES = ("package.json", "extension.js", "README.md")
_APP_CODE_BINS = (
    "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
    os.path.expanduser("~/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"),
)
_INSTALL_TIMEOUT = 120

_CONTENT_TYPES = """<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension=".json" ContentType="application/json"/>
  <Default Extension=".js" ContentType="application/javascript"/>
  <Default Extension=".md" ContentType="text/markdown"/>
  <Default Extension=".vsixmanifest" ContentType="text/xml"/>
</Types>
"""


def _manifest(pkg: dict) -> str:
    def attr(key: str, default: str = "") -> str:
        return quoteattr(str(pkg.get(key) or default))

    engine = str((pkg.get("engines") or {}).get("vscode") or "*")
    categories = ",".join(str(c) for c in pkg.get("categories") or [])
    return f"""<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011" xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">
  <Metadata>
    <Identity Language="en-US" Id={attr("name")} Version={attr("version")} Publisher={attr("publisher")} />
    <DisplayName>{escape(str(pkg.get("displayName") or pkg.get("name") or ""))}</DisplayName>
    <Description xml:space="preserve">{escape(str(pkg.get("description") or ""))}</Description>
    <Tags></Tags>
    <Categories>{escape(categories)}</Categories>
    <GalleryFlags>Public</GalleryFlags>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value={quoteattr(engine)} />
      <Property Id="Microsoft.VisualStudio.Code.ExtensionDependencies" Value="" />
      <Property Id="Microsoft.VisualStudio.Code.ExtensionPack" Value="" />
      <Property Id="Microsoft.VisualStudio.Code.LocalizedLanguages" Value="" />
      <Property Id="Microsoft.VisualStudio.Services.GitHubFlavoredMarkdown" Value="true" />
      <Property Id="Microsoft.VisualStudio.Services.Content.Pricing" Value="Free" />
    </Properties>
  </Metadata>
  <Installation>
    <InstallationTarget Id="Microsoft.VisualStudio.Code" />
  </Installation>
  <Dependencies />
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true" />
    <Asset Type="Microsoft.VisualStudio.Services.Content.Details" Path="extension/README.md" Addressable="true" />
  </Assets>
</PackageManifest>
"""


def build_vsix(ext_dir: str, out_path: str) -> str:
    """Write a .vsix of ``ext_dir`` to ``out_path`` and return the path."""
    src = Path(ext_dir)
    pkg = json.loads((src / "package.json").read_text(encoding="utf-8"))
    out = Path(out_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_name(out.name + ".tmp")
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("extension.vsixmanifest", _manifest(pkg))
        z.writestr("[Content_Types].xml", _CONTENT_TYPES)
        for name in _FILES:
            z.write(src / name, "extension/" + name)
    os.replace(tmp, out)
    return str(out)


def find_code_cli() -> Optional[str]:
    found = shutil.which("code")
    if found:
        return found
    return next((p for p in _APP_CODE_BINS if os.path.isfile(p) and os.access(p, os.X_OK)), None)


def _already_current(ext_dir: Path) -> bool:
    """True when VS Code already has exactly this build installed."""
    try:
        pkg = json.loads((ext_dir / "package.json").read_text(encoding="utf-8"))
        folder = f'{pkg["publisher"]}.{pkg["name"]}-{pkg["version"]}'
        root = Path.home() / ".vscode" / "extensions"
        installed = root / folder
        if not installed.is_dir():
            return False
        obsolete = root / ".obsolete"
        if obsolete.exists() and folder in json.loads(obsolete.read_text(encoding="utf-8") or "{}"):
            return False
        have = json.loads((installed / "package.json").read_text(encoding="utf-8"))
        have.pop("__metadata", None)  # VS Code stamps this in on install
        return have == pkg and \
            (installed / "extension.js").read_bytes() == (ext_dir / "extension.js").read_bytes()
    except Exception:
        return False


def install_extension(code_bin: Optional[str] = None) -> tuple[bool, str]:
    """Pack the extension and install it into VS Code. Never raises."""
    try:
        code = code_bin or find_code_cli()
        if not code:
            return False, "VS Code isn't installed (no `code` command found)"
        if _already_current(EXT_DIR):
            return True, "Jarvis Terminal Bridge is up to date in VS Code"
        from jc_client.logger import state_dir
        vsix = build_vsix(str(EXT_DIR), str(state_dir() / VSIX_NAME))
        proc = subprocess.run([code, "--install-extension", vsix, "--force"],
                              capture_output=True, text=True, timeout=_INSTALL_TIMEOUT)
        if proc.returncode != 0:
            why = (proc.stderr or proc.stdout or "").strip().splitlines()
            return False, f"`code --install-extension` failed: {why[-1] if why else proc.returncode}"
        return True, "Jarvis Terminal Bridge installed in VS Code"
    except Exception as exc:  # noqa: BLE001
        return False, f"couldn't install the VS Code bridge: {exc}"
