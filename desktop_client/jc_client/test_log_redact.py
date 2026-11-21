"""Secret redaction for invoke-arg logging (keeps the Sunshine password out of the log)."""
from __future__ import annotations

from jc_client._log_redact import redact


def test_redacts_nested_password():
    out = redact({"sunshine": {"user": "a", "password": "hunter2"}})
    assert out["sunshine"]["password"] == "***"
    assert out["sunshine"]["user"] == "a"


def test_redacts_token_in_list():
    out = redact([{"token": "t"}, {"ok": 1}])
    assert out[0]["token"] == "***"
    assert out[1]["ok"] == 1


def test_non_secret_untouched():
    assert redact({"name": "Mac", "pin": "1234"})["name"] == "Mac"
