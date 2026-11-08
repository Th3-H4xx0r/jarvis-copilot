"""One list of CLI-session metadata fields, applied the same way everywhere."""
from types import SimpleNamespace

from api.session_routes import CLI_META_FIELDS, _apply_cli_meta, _merge_cli_sidebar_metadata


def _meta(**extra):
    meta = {key: f"v-{key}" for key in CLI_META_FIELDS}
    meta.update(extra)
    return meta


def test_apply_copies_every_field_and_marks_the_session():
    s = SimpleNamespace()
    _apply_cli_meta(s, _meta())
    assert s.is_cli_session is True
    for key in CLI_META_FIELDS:
        assert getattr(s, key) == f"v-{key}", key


def test_raw_source_falls_back_to_source_tag():
    s = SimpleNamespace()
    _apply_cli_meta(s, _meta(raw_source=None, source_tag="telegram"))
    assert s.raw_source == "telegram"


def test_missing_fields_are_cleared_not_kept():
    s = SimpleNamespace(chat_id="stale")
    _apply_cli_meta(s, {"source_tag": "cli"})
    assert s.chat_id is None and s.raw_source == "cli"


def test_the_sidebar_merge_covers_every_session_field():
    merged = _merge_cli_sidebar_metadata({"session_id": "x"}, _meta())
    for key in CLI_META_FIELDS:
        assert merged[key] == f"v-{key}", key

