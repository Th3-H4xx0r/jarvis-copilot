"""Gmail must attach a photo, not paste its path.

"Send my latest photo to my email" arrived with the literal line
`MEDIA:/root/.jarviscopilot/image_cache/jc-device-recent_photo-….jpg` in the
body: gmail_send built a plain MIMEText and had no attachment support at all.
(iMessage worked, which is what made the gap obvious.)"""
import base64
import importlib.util
import sys
from email import message_from_bytes
from pathlib import Path
from types import SimpleNamespace

import pytest

API_PATH = (Path(__file__).resolve().parents[2]
            / "skills/productivity/google-workspace/scripts/google_api.py")
_PNG = bytes.fromhex("89504e470d0a1a0a0000000d49484452")


@pytest.fixture
def api(monkeypatch, tmp_path):
    hermes_home = tmp_path / ".jarviscopilot"
    hermes_home.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(hermes_home))
    spec = importlib.util.spec_from_file_location("gws_api_attach_test", API_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _args(**kw):
    base = dict(to="you@example.com", subject="Your Latest Photo", body="Here it is.",
                cc="", from_header="", html=False, thread_id="", attach=[])
    base.update(kw)
    return SimpleNamespace(**base)


def _sent_message(api, monkeypatch, args):
    captured = {}

    def _fake_run(path, params=None, body=None):
        captured["body"] = body
        return {"id": "m1", "threadId": "t1"}

    monkeypatch.setattr(api, "_gws_binary", lambda: True)
    monkeypatch.setattr(api, "_run_gws", _fake_run)
    api.gmail_send(args)
    raw = captured["body"]["raw"]
    return message_from_bytes(base64.urlsafe_b64decode(raw))


def test_an_attachment_is_a_real_mime_part(api, monkeypatch, tmp_path):
    photo = tmp_path / "jc-device-recent_photo.jpg"
    photo.write_bytes(_PNG)
    msg = _sent_message(api, monkeypatch, _args(attach=[str(photo)]))

    assert msg.is_multipart()
    parts = msg.get_payload()
    assert parts[0].get_payload(decode=True).decode().strip() == "Here it is."
    attached = [p for p in parts if p.get_filename()]
    assert len(attached) == 1
    assert attached[0].get_filename() == "jc-device-recent_photo.jpg"
    assert attached[0].get_payload(decode=True) == _PNG
    assert attached[0].get_content_type() == "image/jpeg"
    assert msg["subject"] == "Your Latest Photo"


def test_a_media_tag_in_the_body_becomes_the_attachment(api, monkeypatch, tmp_path):
    photo = tmp_path / "shot.png"
    photo.write_bytes(_PNG)
    msg = _sent_message(api, monkeypatch,
                        _args(body=f"Here it is.\nMEDIA:{photo}\n\nSincerely, JARVIS."))

    body = msg.get_payload()[0].get_payload(decode=True).decode()
    assert "MEDIA:" not in body, "the tag is an instruction, never text for the reader"
    assert "Sincerely, JARVIS." in body
    attached = [p for p in msg.get_payload() if p.get_filename()]
    assert attached[0].get_payload(decode=True) == _PNG


def test_a_plain_email_stays_a_simple_message(api, monkeypatch):
    msg = _sent_message(api, monkeypatch, _args())
    assert not msg.is_multipart()
    assert msg.get_payload(decode=True).decode().strip() == "Here it is."


def test_a_missing_file_still_sends_the_note(api, monkeypatch, tmp_path):
    msg = _sent_message(api, monkeypatch, _args(attach=[str(tmp_path / "gone.jpg")]))
    assert "Here it is." in str(msg)
