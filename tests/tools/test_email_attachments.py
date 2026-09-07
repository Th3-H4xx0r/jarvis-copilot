"""Sending a photo to email must attach the file, not paste a MEDIA: line.

"Send my latest image to my email" delivered the literal text
`MEDIA:/root/.jarviscopilot/webui/device_images/recent_photo-…jpg` in the body:
the SMTP sender built a plain MIMEText and ignored media entirely."""
import asyncio
import sys
from email import message_from_string
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import tools.send_message_tool as smt  # noqa: E402

_PNG = bytes.fromhex("89504e470d0a1a0a0000000d49484452")


class _FakeSMTP:
    sent = []

    def __init__(self, host, port):
        self.host, self.port = host, port

    def starttls(self, context=None):
        pass

    def login(self, a, b):
        pass

    def send_message(self, msg):
        _FakeSMTP.sent.append(msg)

    def quit(self):
        pass


def _configured(monkeypatch, tmp_path):
    _FakeSMTP.sent = []
    monkeypatch.setattr("smtplib.SMTP", _FakeSMTP)
    monkeypatch.setenv("EMAIL_PASSWORD", "pw")
    monkeypatch.setenv("EMAIL_SMTP_HOST", "smtp.example.com")
    return {"address": "me@example.com", "smtp_host": "smtp.example.com"}


def test_an_image_is_attached_not_pasted_as_text(monkeypatch, tmp_path):
    extra = _configured(monkeypatch, tmp_path)
    photo = tmp_path / "recent_photo.jpg"
    photo.write_bytes(_PNG)

    asyncio.run(smt._send_email(extra, "you@example.com", "Here is the latest image.",
                                media_files=[(str(photo), False)]))

    msg = _FakeSMTP.sent[0]
    assert msg.is_multipart(), "an email with a photo must be multipart"
    payloads = msg.get_payload()
    body = payloads[0].get_payload(decode=True).decode()
    assert "MEDIA:" not in body
    attached = [p for p in payloads if p.get_filename()]
    assert len(attached) == 1
    assert attached[0].get_filename() == "recent_photo.jpg"
    assert attached[0].get_payload(decode=True) == _PNG
    assert attached[0].get_content_type() == "image/jpeg"


def test_a_plain_message_stays_a_simple_email(monkeypatch, tmp_path):
    extra = _configured(monkeypatch, tmp_path)
    asyncio.run(smt._send_email(extra, "you@example.com", "Just a note."))
    msg = _FakeSMTP.sent[0]
    assert not msg.is_multipart()
    assert msg.get_payload(decode=True).decode() == "Just a note."


def test_a_missing_attachment_still_sends_the_message(monkeypatch, tmp_path):
    extra = _configured(monkeypatch, tmp_path)
    out = asyncio.run(smt._send_email(extra, "you@example.com", "Body.",
                                      media_files=[(str(tmp_path / "gone.jpg"), False)]))
    assert out.get("success") is True
    assert _FakeSMTP.sent, "the note itself is still worth delivering"


def test_the_subject_summarises_the_attachment(monkeypatch, tmp_path):
    extra = _configured(monkeypatch, tmp_path)
    photo = tmp_path / "shot.png"
    photo.write_bytes(_PNG)
    asyncio.run(smt._send_email(extra, "you@example.com", "",
                                media_files=[(str(photo), False)]))
    assert _FakeSMTP.sent[0]["Subject"]


def test_device_photos_are_written_where_media_delivery_allows(tmp_path):
    """A photo saved outside the media-delivery roots is dropped by
    filter_media_delivery_paths before any platform sees it, so "send my latest
    photo to X" silently loses the file on every channel."""
    from gateway.platforms.base import _media_delivery_allowed_roots, _path_is_within
    import tools.device_skill_tools as dst

    roots = _media_delivery_allowed_roots()
    target = dst._IMAGE_DIR.expanduser().resolve()
    assert any(_path_is_within(target, Path(r).expanduser().resolve()) for r in roots), (
        f"device images land in {target}, which is outside the delivery allowlist")
