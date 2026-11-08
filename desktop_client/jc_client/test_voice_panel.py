"""The native voice panel's loader and health line."""
from __future__ import annotations

from jc_client import voice_panel


def test_a_missing_dylib_leaves_the_web_panel_in_place(monkeypatch, tmp_path):
    """No dylib is a fallback, not a failure — `build.sh` may never have run."""
    monkeypatch.setattr(voice_panel, "_panel_class", voice_panel._UNSET)
    monkeypatch.setattr(voice_panel, "__file__", str(tmp_path / "voice_panel.py"))
    assert voice_panel._voice_panel_class() is None


def test_the_dylib_is_only_looked_for_once(monkeypatch, tmp_path):
    monkeypatch.setattr(voice_panel, "_panel_class", voice_panel._UNSET)
    monkeypatch.setattr(voice_panel, "__file__", str(tmp_path / "voice_panel.py"))
    assert voice_panel._voice_panel_class() is None
    # A second call must not re-open the dylib; the cached answer stands even if
    # the file appears afterwards.
    (tmp_path / "assets").mkdir()
    (tmp_path / "assets" / "libJarvisVoiceUI.dylib").write_bytes(b"not a dylib")
    assert voice_panel._voice_panel_class() is None


def _health(monkeypatch, *, darwin=True, cls=None, error=None, dylib=True, tmp_path=None):
    monkeypatch.setattr(voice_panel.sys, "platform", "darwin" if darwin else "linux")
    monkeypatch.setattr(voice_panel, "_panel_class", cls)
    monkeypatch.setattr(voice_panel, "_panel_error", error)
    path = (tmp_path / "libJarvisVoiceUI.dylib") if tmp_path else None
    if path is not None and dylib:
        path.write_bytes(b"")
    monkeypatch.setattr(voice_panel, "_dylib_path",
                        lambda: path if path is not None else __import__("pathlib").Path("/nope"))
    return voice_panel.voice_panel_health()


def test_health_is_not_a_question_off_macos(monkeypatch):
    ok, detail = _health(monkeypatch, darwin=False)
    assert ok is False and "macOS only" in detail


def test_health_names_the_build_step_when_the_dylib_was_never_built(monkeypatch, tmp_path):
    ok, detail = _health(monkeypatch, dylib=False, tmp_path=tmp_path)
    assert ok is False
    assert "build.sh" in detail


def test_health_repeats_why_the_dylib_would_not_load(monkeypatch, tmp_path):
    """The ctypes message names the cause — a wrong architecture, say."""
    ok, detail = _health(monkeypatch, cls=None,
                         error="incompatible architecture (have 'arm64', need 'x86_64')",
                         tmp_path=tmp_path)
    assert ok is False
    assert "incompatible architecture" in detail


def test_health_is_good_when_the_panel_and_its_shader_are_there(monkeypatch, tmp_path):
    class _Cls:
        @staticmethod
        def orbShaderAvailable():
            return True

    ok, detail = _health(monkeypatch, cls=_Cls, tmp_path=tmp_path)
    assert ok is True and detail == "native panel"


def test_a_loaded_panel_with_no_shader_is_still_a_working_panel(monkeypatch, tmp_path):
    """The orb goes missing; the conversation does not. Say so without crying wolf."""
    class _Cls:
        @staticmethod
        def orbShaderAvailable():
            return False

    ok, detail = _health(monkeypatch, cls=_Cls, tmp_path=tmp_path)
    assert ok is True
    assert "shader" in detail and "build.sh" in detail
