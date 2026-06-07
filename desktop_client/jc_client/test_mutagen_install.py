"""Tests for the Mutagen fetch/install (no network — injected opener)."""
import hashlib
import io
import os
import stat
import tarfile

from jc_client import mutagen_install as mi


def test_asset_naming():
    assert mi.asset_name("0.18.1", "darwin", "arm64") == \
        "mutagen_darwin_arm64_v0.18.1.tar.gz"
    assert mi.asset_url("0.18.1", "linux", "amd64") == (
        "https://github.com/mutagen-io/mutagen/releases/download/v0.18.1/"
        "mutagen_linux_amd64_v0.18.1.tar.gz")
    assert mi.sha256sums_url("0.18.1").endswith("/v0.18.1/SHA256SUMS")


def test_platform_target_known():
    osn, arch = mi.platform_target()
    # the test host is one of these; just assert it resolved to something sane
    assert osn in ("darwin", "linux", "windows", None)
    assert arch in ("arm64", "amd64", "386", None)


def test_expected_sha256_parsing():
    sums = ("abc123  mutagen_darwin_arm64_v0.18.1.tar.gz\n"
            "def456  mutagen_linux_amd64_v0.18.1.tar.gz\n")
    assert mi._expected_sha256(sums, "mutagen_darwin_arm64_v0.18.1.tar.gz") == "abc123"
    assert mi._expected_sha256(sums, "nope.tar.gz") is None


def _make_tar(version: str) -> bytes:
    """A fake release tarball: a `mutagen` script that prints `version`, plus the
    agents bundle placeholder."""
    script = f"#!/bin/sh\n[ \"$1\" = version ] && echo {version}\n".encode()
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        ti = tarfile.TarInfo("mutagen")
        ti.size = len(script)
        ti.mode = 0o755
        tf.addfile(ti, io.BytesIO(script))
        agents = b"fake-agents"
        ta = tarfile.TarInfo("mutagen-agents.tar.gz")
        ta.size = len(agents)
        tf.addfile(ta, io.BytesIO(agents))
    return buf.getvalue()


def test_ensure_mutagen_installs_and_verifies(tmp_path):
    tar = _make_tar("0.18.1")
    sha = hashlib.sha256(tar).hexdigest()
    sums = f"{sha}  mutagen_{mi.platform_target()[0]}_{mi.platform_target()[1]}_v0.18.1.tar.gz\n"

    def opener(url):
        return sums.encode() if url.endswith("SHA256SUMS") else tar

    # need a resolvable platform for the asset name in SHA verify
    if None in mi.platform_target():
        import pytest
        pytest.skip("unsupported test platform")

    path = mi.ensure_mutagen(str(tmp_path), opener=opener)
    assert os.path.isfile(path)
    assert os.stat(path).st_mode & stat.S_IXUSR
    assert os.path.isfile(os.path.join(mi.bin_dir(str(tmp_path)), "mutagen-agents.tar.gz"))
    # idempotent: already-installed + right version → no re-download
    calls = []
    path2 = mi.ensure_mutagen(str(tmp_path), opener=lambda u: calls.append(u) or b"")
    assert path2 == path and calls == []


def test_ensure_mutagen_checksum_mismatch_raises(tmp_path):
    if None in mi.platform_target():
        import pytest
        pytest.skip("unsupported test platform")
    tar = _make_tar("0.18.1")
    asset = mi.asset_name("0.18.1", *mi.platform_target())

    def opener(url):
        return f"deadbeef  {asset}\n".encode() if url.endswith("SHA256SUMS") else tar

    try:
        mi.ensure_mutagen(str(tmp_path), opener=opener)
        assert False, "expected checksum mismatch"
    except RuntimeError as e:
        assert "checksum mismatch" in str(e)


def test_installed_path_and_version(tmp_path):
    assert mi.installed_path(str(tmp_path)) is None  # nothing yet
