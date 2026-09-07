"""A first-class `send_email` tool.

Without one the model had no way to send mail: it fired five tool_search calls,
poked at himalaya's --help, wrote a scratch file, and finally gave up with
"the email systems are currently proving uncooperative" and sent a Telegram
instead. Himalaya was configured and working the whole time."""
import json
import sys
from email import message_from_string
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import tools.email_tool as et  # noqa: E402

_PNG = bytes.fromhex("89504e470d0a1a0a0000000d49484452")


@pytest.fixture
def himalaya(monkeypatch, tmp_path):
    cfg = tmp_path / "config.toml"
    cfg.write_text('[accounts.gmail]\nemail = "me@example.com"\n'
                   'display-name = "Pranav"\ndefault = true\n')
    monkeypatch.setattr(et, "_himalaya_config_path", lambda: cfg)
    monkeypatch.setattr(et, "_himalaya_binary", lambda: "/usr/local/bin/himalaya")
    sent = {}

    def _run(cmd, raw):
        sent["cmd"] = cmd
        sent["raw"] = raw
        return 0, "sent", ""

    monkeypatch.setattr(et, "_run_himalaya", _run)
    return sent


def test_a_plain_email_is_sent_with_a_sender(himalaya):
    out = json.loads(et.send_email(to="you@example.com", subject="Hi", body="Hello there."))
    assert out["sent"] is True
    msg = message_from_string(himalaya["raw"])
    # himalaya refuses outright with "cannot send message without a sender".
    assert "me@example.com" in msg["From"]
    assert msg["To"] == "you@example.com"
    assert msg["Subject"] == "Hi"
    assert msg.get_payload(decode=True).decode().strip() == "Hello there."


def test_an_attachment_is_a_real_mime_part(himalaya, tmp_path):
    photo = tmp_path / "photo.jpg"
    photo.write_bytes(_PNG)
    out = json.loads(et.send_email(to="you@example.com", subject="Photo",
                                   body="Here it is.", attach=[str(photo)]))
    assert out["attached"] == ["photo.jpg"]
    msg = message_from_string(himalaya["raw"])
    assert msg.is_multipart()
    part = [p for p in msg.get_payload() if p.get_filename()][0]
    assert part.get_payload(decode=True) == _PNG
    assert part.get_content_type() == "image/jpeg"


def test_a_media_tag_in_the_body_is_attached_not_printed(himalaya, tmp_path):
    photo = tmp_path / "shot.png"
    photo.write_bytes(_PNG)
    et.send_email(to="you@example.com", subject="P", body=f"Look\nMEDIA:{photo}\n\nJARVIS")
    msg = message_from_string(himalaya["raw"])
    body = msg.get_payload()[0].get_payload(decode=True).decode()
    assert "MEDIA:" not in body and "JARVIS" in body
    assert [p for p in msg.get_payload() if p.get_filename()]


def test_a_missing_recipient_is_a_clear_error(himalaya):
    out = json.loads(et.send_email(to="", subject="x", body="y"))
    assert out.get("error")


def test_a_send_failure_is_reported_not_swallowed(monkeypatch, himalaya):
    monkeypatch.setattr(et, "_run_himalaya", lambda cmd, raw: (1, "", "cannot send message"))
    out = json.loads(et.send_email(to="you@example.com", subject="x", body="y"))
    assert out.get("sent") is not True
    assert "cannot send message" in json.dumps(out)


def test_it_says_so_plainly_when_no_email_is_configured(monkeypatch):
    monkeypatch.setattr(et, "_himalaya_binary", lambda: None)
    monkeypatch.setattr(et, "_smtp_settings", lambda: None)
    out = json.loads(et.send_email(to="you@example.com", subject="x", body="y"))
    assert "not configured" in out.get("error", "").lower()


def test_the_tool_is_registered_and_in_the_toolsets():
    from tools.registry import discover_builtin_tools, registry
    from toolsets import TOOLSETS, _HERMES_CORE_TOOLS
    discover_builtin_tools()
    assert "send_email" in registry.get_tool_names_for_toolset("messaging")
    assert "send_email" in TOOLSETS["messaging"]["tools"]
    assert "send_email" in _HERMES_CORE_TOOLS, "every platform bot should be able to send mail"
