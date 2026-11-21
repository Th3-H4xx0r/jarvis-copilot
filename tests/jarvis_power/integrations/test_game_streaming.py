"""Game Streaming as a Power integration: valid manifest; off gates routes/tools; app-only secret."""
from __future__ import annotations

from jarvis_power import discovery, gate, state


def test_game_streaming_validates_and_gates(reg):
    discovery.reset()
    p = discovery.get("game-streaming")
    assert discovery.validate(p) == []
    state.ensure_all()
    assert gate.route_block("/api/game-streaming/status") is None
    state.write_enabled("game-streaming", False, by="app")
    assert gate.route_block("/api/game-streaming/status")["power_off"] == "game-streaming"
    assert gate.tool_off_message("game_streaming") == "Game Streaming is switched off"


def test_password_setting_is_app_only(reg):
    discovery.reset()
    p = discovery.get("game-streaming")
    (pw,) = [s for s in p.settings if s.key == "password"]
    assert pw.kind == "secret"
    assert pw.jarvis == "never"


def test_start_and_stop_follow_the_switch(reg, monkeypatch):
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "webui"))
    import api.game_streaming_routes as R
    seen = []
    monkeypatch.setattr(R, "power_changed", lambda on: seen.append(on))
    discovery.reset()
    p = discovery.get("game-streaming")
    p.start("webui")
    p.stop("webui")
    assert seen == [True, False]


def test_form_is_slimmed_to_the_login_only(reg):
    discovery.reset()
    p = discovery.get("game-streaming")
    keys = {s.key for s in p.settings}
    assert keys == {"user", "password", "log_path"}       # no host/port/targets JSON on the form
    assert "targets" not in keys and "host" not in keys and "port" not in keys


def test_native_setup_replaces_the_generic_form(reg):
    discovery.reset()
    p = discovery.get("game-streaming")
    assert discovery.validate(p) == []
    assert "settings" in p.native.get("ios", ())          # native "one smart page" setup
    assert "settings" in p.native.get("web", ())

