"""The Soniox key: where it is read from, and what is ever said about it."""
from jarvis_speech import keys, usage


def test_file_key_wins_over_process_env(tmp_path, monkeypatch):
    home = tmp_path / "home"
    home.mkdir()
    (home / ".env").write_text("# a comment\nOTHER=1\nSONIOX_API_KEY=  file-key-1a2b  \n")
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setenv("SONIOX_API_KEY", "stale-env-key")
    assert keys.soniox_key() == "file-key-1a2b"
    assert keys.key_status() == {"set": True, "hint": "••••1a2b"}


def test_quoted_value_is_unquoted(tmp_path, monkeypatch):
    home = tmp_path / "home"
    home.mkdir()
    (home / ".env").write_text('SONIOX_API_KEY="quoted-key-7777"\n')
    monkeypatch.setenv("HERMES_HOME", str(home))
    assert keys.soniox_key() == "quoted-key-7777"


def test_env_used_when_file_has_none(tmp_path, monkeypatch):
    home = tmp_path / "home"
    home.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setenv("SONIOX_API_KEY", "env-key-9z9z")
    assert keys.soniox_key() == "env-key-9z9z"


def test_no_key(tmp_path, monkeypatch):
    home = tmp_path / "home"
    home.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.delenv("SONIOX_API_KEY", raising=False)
    assert keys.soniox_key() == ""
    assert keys.key_status() == {"set": False, "hint": ""}


def test_usage_sums_by_day_and_prices(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    usage.add("live", 1800)
    usage.add("voice", 1800)
    got = usage.summary()
    assert got["today_s"] == 3600 and got["month_s"] == 3600
    assert abs(got["est_usd"] - 0.12) < 1e-9


def test_usage_with_no_file_is_zero(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    assert usage.summary() == {"today_s": 0, "month_s": 0, "est_usd": 0.0}


def test_a_key_removed_from_the_file_is_gone_even_if_the_process_still_has_it(tmp_path, monkeypatch):
    """The gateway copied .env into its environment at startup; the file decides."""
    home = tmp_path / "home"
    home.mkdir()
    (home / ".env").write_text("OTHER=1\n")
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setenv("SONIOX_API_KEY", "copied-at-startup-1234")
    assert keys.soniox_key() == ""
