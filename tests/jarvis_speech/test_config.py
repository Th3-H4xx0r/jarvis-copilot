"""The `speech:` settings: what a hand-edited file, the web and the phone may put there."""
import pytest
import yaml

from jarvis_speech import config


@pytest.fixture
def cfg_file(tmp_path, monkeypatch):
    path = tmp_path / "config.yaml"
    monkeypatch.setenv("HERMES_CONFIG_PATH", str(path))
    return path


def _write(path, data):
    path.write_text(yaml.safe_dump(data))


def test_defaults_when_section_missing(cfg_file):
    _write(cfg_file, {"model": {"default": "x"}})
    got = config.load()
    assert got["surfaces"] == {"voice": "local", "live": "edge", "upload": "local"}
    assert got["soniox"]["model"] == "stt-rt-v5"


def test_config_coerces_bad_values(cfg_file):
    _write(cfg_file, {"speech": {"surfaces": {"voice": 7, "live": "nonsense-engine"},
                                 "soniox": {"endpoint_latency_level": "9", "speaker_labels": "yes",
                                            "max_endpoint_delay_ms": "abc", "language_hints": "en"}}})
    got = config.load()
    assert got["surfaces"]["voice"] == "local"           # not a string → default
    assert got["surfaces"]["live"] == "nonsense-engine"  # names survive load; engine_for rejects them
    assert got["soniox"]["endpoint_latency_level"] == 2  # out of range → default
    assert got["soniox"]["speaker_labels"] is True
    assert got["soniox"]["max_endpoint_delay_ms"] == 2000
    assert got["soniox"]["language_hints"] == ["en"]     # a bare string becomes a one-item list


def test_unreadable_file_is_defaults(cfg_file):
    cfg_file.write_text("speech: [unclosed")
    assert config.load() == config.coerce({})


def test_validate_rejects_out_of_range_and_api_key():
    with pytest.raises(ValueError):
        config.validate({"soniox": {"endpoint_sensitivity": 2}})
    with pytest.raises(ValueError):
        config.validate({"soniox": {"api_key": "sk-123"}})
    with pytest.raises(ValueError):
        config.validate({"surfaces": {"voice": "no-such-engine"}})
    with pytest.raises(ValueError):
        config.validate({"surfaces": {"live": "local"}})  # live needs edge or a streaming engine


def test_validate_accepts_good_values():
    clean = config.validate({"surfaces": {"voice": "soniox", "live": "soniox", "upload": "local"},
                             "soniox": {"endpoint_sensitivity": "0.5", "custom_words": ["Jarvis", "Jarvis", " "]}})
    assert clean["surfaces"] == {"voice": "soniox", "live": "soniox", "upload": "local"}
    assert clean["soniox"] == {"endpoint_sensitivity": 0.5, "custom_words": ["Jarvis"]}


def test_merge_keeps_sibling_keys():
    stored = {"surfaces": {"voice": "soniox", "live": "edge"}, "soniox": {"custom_words": ["Jarvis"]}}
    merged = config.merge(stored, {"surfaces": {"upload": "soniox"}})
    assert merged["surfaces"] == {"voice": "soniox", "live": "edge", "upload": "soniox"}
    assert merged["soniox"]["custom_words"] == ["Jarvis"]


def test_unknown_keys_listed():
    assert config.unknown_keys({"surfaces": {"pod": "x"}, "bogus": 1}) == ["bogus", "surfaces.pod"]
