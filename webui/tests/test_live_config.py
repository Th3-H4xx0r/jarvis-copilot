"""Live Jarvis settings: one source of truth, and the interlock key inside it.

Three clients read this section (iOS, web, the server's own watchers), so the
things worth testing are that a write survives a round trip, that a key nobody
knows does not get persisted as if it worked, and that `embed_model` — the value
that decides whether a device may label voices at all — comes back exactly as
written.
"""
from __future__ import annotations

import pytest
import yaml

from api import config as api_config
from api import live_config


@pytest.fixture(autouse=True)
def isolated_config(tmp_path, monkeypatch):
    path = tmp_path / "config.yaml"
    monkeypatch.setenv("HERMES_CONFIG_PATH", str(path))
    api_config.reload_config()
    yield path
    api_config.reload_config()


def _on_disk(path):
    if not path.exists():
        return {}
    return yaml.safe_load(path.read_text(encoding="utf-8")) or {}


def test_load_returns_every_default_when_nothing_is_configured():
    assert live_config.load() == live_config.DEFAULTS


def test_a_saved_value_round_trips_and_the_other_defaults_survive(isolated_config):
    live_config.save({"monitor": False, "window_seconds": 120})

    loaded = live_config.load()
    assert loaded["monitor"] is False
    assert loaded["window_seconds"] == 120
    # Everything untouched still reads as its default, which is what makes a
    # partial PUT from a settings sheet safe.
    assert loaded["fact_check"] is live_config.DEFAULTS["fact_check"]
    assert loaded["embed_model"] == live_config.DEFAULTS["embed_model"]
    assert set(loaded) == set(live_config.DEFAULTS)


def test_the_embed_model_id_round_trips_verbatim():
    """This string is compared against a device's declared id. A normalisation
    here would hand the edge lane to a device running another checkpoint."""
    live_config.save({"embed_model": "wespeaker-resnet34-v2"})
    assert live_config.load()["embed_model"] == "wespeaker-resnet34-v2"


def test_writes_land_under_a_live_section_and_leave_other_sections_alone(
        isolated_config):
    isolated_config.write_text(
        yaml.safe_dump({"model": {"provider": "openrouter"}}), encoding="utf-8")

    live_config.save({"translate": True})

    raw = _on_disk(isolated_config)
    assert raw["model"] == {"provider": "openrouter"}
    assert raw["live"]["translate"] is True


def test_two_writes_compose_instead_of_replacing_each_other(isolated_config):
    live_config.save({"translate": True})
    live_config.save({"artifacts": False})

    loaded = live_config.load()
    assert (loaded["translate"], loaded["artifacts"]) == (True, False)


def test_an_unknown_key_is_dropped_rather_than_persisted(isolated_config):
    """A typo'd key that survives a round trip looks like a working setting
    forever, in a section three separate clients read."""
    result = live_config.save({"monitor": False, "montior": True})

    assert "montior" not in _on_disk(isolated_config).get("live", {})
    assert "montior" not in result
    assert live_config.unknown_keys({"montior": True}) == ["montior"]


@pytest.mark.parametrize("patch", [
    {"reply_mode": "interpretive-dance"},
    {"window_seconds": 0},
    {"window_seconds": "not-a-number"},
    {"monitor": "maybe"},
    {"min_window_words": -1},
    {"primary_language": "   "},
])
def test_an_invalid_value_is_refused_so_the_client_learns_it_did_not_take(patch):
    with pytest.raises(ValueError):
        live_config.save(patch)


def test_a_refused_write_changes_nothing(isolated_config):
    live_config.save({"window_seconds": 90})
    with pytest.raises(ValueError):
        live_config.save({"window_seconds": -5})
    assert live_config.load()["window_seconds"] == 90


def test_a_hand_edited_config_is_read_rather_than_rejected(isolated_config):
    """Users edit config.yaml directly; YAML turns `yes` into True and quotes
    happen. A malformed settings file must not be able to stop capture."""
    isolated_config.write_text(yaml.safe_dump({"live": {
        "monitor": "yes",
        "window_seconds": "45",
        "reply_mode": "shouted",
        "min_window_words": -3,
    }}), encoding="utf-8")

    loaded = live_config.load()
    assert loaded["monitor"] is True
    assert loaded["window_seconds"] == 45
    assert loaded["reply_mode"] == live_config.DEFAULTS["reply_mode"]
    assert loaded["min_window_words"] == live_config.DEFAULTS["min_window_words"]


def test_a_live_section_that_is_not_a_mapping_falls_back_to_defaults(
        isolated_config):
    isolated_config.write_text(yaml.safe_dump({"live": "enabled"}),
                               encoding="utf-8")
    assert live_config.load() == live_config.DEFAULTS


def test_reply_mode_accepts_both_documented_modes():
    for mode in live_config.REPLY_MODES:
        assert live_config.save({"reply_mode": mode})["reply_mode"] == mode
