"""The Windows app's update channel (contract C5): JarvisWin.zip with Jarvis/version.json."""
import hashlib
import io
import json
import plistlib
import zipfile

import pytest

from api import app_updates as au


@pytest.fixture(autouse=True)
def store(tmp_path, monkeypatch):
    monkeypatch.setattr(au, "STATE_DIR", tmp_path)
    monkeypatch.setattr("api.auth._signing_key", lambda: b"test-key")
    return tmp_path


def _win_zip(build, version="1.0.0", with_version=True) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("Jarvis/Jarvis.exe", b"MZ" + b"x" * 500)
        zf.writestr("Jarvis/JarvisUpdater.exe", b"MZ" + b"y" * 100)
        if with_version:
            zf.writestr("Jarvis/version.json", json.dumps({"version": version, "build": build}))
    return buf.getvalue()


def _upload(platform, build, data):
    return au.store_upload(platform, build, io.BytesIO(data), len(data))


def test_windows_zip_version_read():
    rec = _upload("windows", 263200000, _win_zip(263200000, "1.0.0"))
    assert rec["build"] == 263200000 and rec["version"] == "1.0.0"


def test_windows_zip_build_must_match():
    with pytest.raises(au.UploadError):
        _upload("windows", 263200001, _win_zip(263200000))


def test_windows_zip_without_version_rejected():
    with pytest.raises(au.UploadError):
        _upload("windows", 5, _win_zip(5, with_version=False))


def test_windows_offer_has_download_link_and_sha256():
    data = _win_zip(263200000)
    _upload("windows", 263200000, data)
    offer = au.latest("windows", 100, "https://ota.example.dev")
    assert offer["available"] and offer["build"] == 263200000
    assert offer["install_url"].endswith("/JarvisWin.zip")
    assert offer["sha256"] == hashlib.sha256(data).hexdigest()


def test_windows_token_accepted():
    _upload("windows", 263200000, _win_zip(263200000))
    token = au.make_token("windows", 263200000)
    assert au.check_token(token)["platform"] == "windows"


def test_mac_archives_still_parse():
    info = plistlib.dumps({"CFBundleVersion": "300", "CFBundleShortVersionString": "2.0"})
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("Jarvis.app/Contents/Info.plist", info)
    rec = _upload("mac", 300, buf.getvalue())
    assert rec["version"] == "2.0"
