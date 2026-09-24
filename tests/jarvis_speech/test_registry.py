"""Which engine a surface gets — and that anything unusable means today's path."""
import jarvis_speech
from jarvis_speech import registry


class _Fake:
    name, label, streams = "fake", "Fake", True

    def __init__(self, ok=True):
        self.ok = ok

    def available(self):
        return (self.ok, "" if self.ok else "no key")

    def transcribe_file(self, path):
        return {"success": True, "transcript": "fake words", "provider": "fake"}

    def open_stream(self, sink, **kw):
        return None


def _cfg(**surfaces):
    base = {"voice": "local", "live": "edge", "upload": "local"}
    base.update(surfaces)
    return lambda: {"surfaces": base, "soniox": {}}


def test_builtin_engines_listed():
    names = [e["name"] for e in registry.engines()]
    assert "local" in names and "soniox" in names


def test_current_flow_is_listed_first(monkeypatch):
    """Pickers list engines in this order; the current flow leads whatever loaded first."""
    monkeypatch.setattr(registry, "_factories", {"soniox": _Fake, "local": _Fake, "fake": _Fake})
    monkeypatch.setattr(registry, "_instances", {})
    assert registry.names() == ["local", "soniox", "fake"]


def test_engines_report_availability_with_a_reason():
    registry.register_engine("fake", lambda: _Fake(ok=False))
    row = next(e for e in registry.engines() if e["name"] == "fake")
    assert row == {"name": "fake", "label": "Fake", "streams": True, "available": False, "reason": "no key"}


def test_engine_whose_check_raises_is_listed_unavailable():
    class Broken(_Fake):
        def available(self):
            raise RuntimeError("boom")
    registry.register_engine("fake", Broken)
    row = next(e for e in registry.engines() if e["name"] == "fake")
    assert row["available"] is False and row["reason"]


def test_engine_for_local_and_edge_is_none(monkeypatch):
    monkeypatch.setattr(jarvis_speech.config, "load", _cfg())
    assert jarvis_speech.engine_for("voice") is None
    assert jarvis_speech.engine_for("live") is None


def test_engine_for_unknown_name_is_none(monkeypatch):
    monkeypatch.setattr(jarvis_speech.config, "load", _cfg(voice="nope"))
    assert jarvis_speech.engine_for("voice") is None


def test_engine_for_unavailable_is_none(monkeypatch):
    registry.register_engine("fake", lambda: _Fake(ok=False))
    monkeypatch.setattr(jarvis_speech.config, "load", _cfg(voice="fake"))
    assert jarvis_speech.engine_for("voice") is None


def test_engine_for_available_engine(monkeypatch):
    registry.register_engine("fake", lambda: _Fake())
    monkeypatch.setattr(jarvis_speech.config, "load", _cfg(voice="fake"))
    assert jarvis_speech.engine_for("voice").name == "fake"


def test_engine_for_never_raises(monkeypatch):
    def boom():
        raise RuntimeError("config exploded")
    monkeypatch.setattr(jarvis_speech.config, "load", boom)
    assert jarvis_speech.engine_for("voice") is None
