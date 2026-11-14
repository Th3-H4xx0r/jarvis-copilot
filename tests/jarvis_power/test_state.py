"""Power integrations: on/off and settings kept in each integration's registry space."""
from __future__ import annotations

import json

from jarvis_power import discovery, state

from .conftest import simple


def test_ensure_seeds_once(fake_pkg, reg):
    fake_pkg({"alpha": simple(default=False)})
    state.ensure_all()
    assert state.is_on("alpha") is False
    # A later boot with a different default never re-seeds what is stored.
    fake_pkg({"alpha": simple(default=True)})
    state.ensure_all()
    state.reset_cache()
    assert state.is_on("alpha") is False
    assert state.doc("alpha")["changed_by"] == "seed"


def test_unknown_id_is_on(fake_pkg, reg):
    fake_pkg({"alpha": simple()})
    assert state.is_on("nobody") is True


def test_space_id_collision_uses_prefixed_space(fake_pkg, reg):
    user = reg.space("dashcam", name="My dashcam notes")
    user.append("notes", {"text": "keep me"})
    fake_pkg({"dashcam": simple(id="dashcam", name="Dashcam")})
    state.ensure_all()
    assert state.space_id_for("dashcam") == "power-dashcam"
    assert state.is_power_space("power-dashcam")
    assert not state.is_power_space("dashcam")
    assert reg.open("dashcam").count("notes") == 1
    # Stable even after the user's space goes away.
    reg.delete_space("dashcam")
    state.reset_cache()
    assert state.space_id_for("dashcam") == "power-dashcam"


def test_adopt_space_reuses_existing_space(fake_pkg, reg):
    reg.space("jarvis-health", name="Jarvis Health").put("settings", {"enabled": True})
    fake_pkg({"health": simple(id="jarvis-health", name="Jarvis Health",
                               extra="adopt_space = True")})
    state.ensure_all()
    assert state.space_id_for("jarvis-health") == "jarvis-health"
    assert reg.open("jarvis-health").get("settings") == {"enabled": True}


def test_version_changes_on_write(fake_pkg, reg):
    fake_pkg({"alpha": simple()})
    state.ensure_all()
    before = state.version()
    state.write_enabled("alpha", False, by="app")
    assert state.version() != before
    assert state.is_on("alpha") is False
    mid = state.version()
    state.record_error("alpha", "Couldn't stop: boom")
    assert state.version() != mid
    assert state.doc("alpha")["error"] == "Couldn't stop: boom"


def test_settings_round_trip(fake_pkg, reg):
    fake_pkg({"alpha": simple()})
    state.ensure_all()
    state.store_settings("alpha", {"mode": "b"})
    state.store_settings("alpha", {"other": 1})
    assert state.stored_settings("alpha") == {"mode": "b", "other": 1}


def test_power_spaces_hidden_from_overview(fake_pkg, reg):
    reg.space("shopping", name="Shopping")
    fake_pkg({"alpha": simple()})
    state.ensure_all()
    from jarvis_registry import integrations

    ids = [row["id"] for row in integrations.overview()]
    assert "shopping" in ids
    assert "alpha" not in ids
    assert "power" not in [d["key"] for d in integrations.summary("alpha")["documents"]]


def test_registry_put_cannot_write_power_doc(fake_pkg, reg):
    fake_pkg({"alpha": simple()})
    state.ensure_all()
    from tools import registry_tools

    out = json.loads(registry_tools._h_put({"space": "alpha", "key": "jarvis_power",
                                            "body": {"enabled": False}}))
    assert out.get("ok") is False
    assert state.is_on("alpha") is True


def test_setup_cannot_create_power_id(fake_pkg, reg):
    fake_pkg({"alpha": simple()})
    state.ensure_all()
    from tools import registry_tools

    out = json.loads(registry_tools._h_create({"name": "Alpha", "id": "alpha"}))
    assert out.get("ok") is False
    assert "built-in Power integration" in out["error"]


def test_ui_set_refuses_power_space(fake_pkg, reg):
    fake_pkg({"alpha": simple()})
    state.ensure_all()
    from jarvis_registry import ui
    import pytest

    with pytest.raises(Exception, match="Power integration"):
        ui.save_ui("alpha", {"schema": 1, "presentations": {"card": {"type": "text", "value": "x"}},
                             "scripts": {"load": {"code": "pass"}}})
