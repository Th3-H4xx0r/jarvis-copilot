"""The server knows each computer's OS (contract C4): from jc-client's register frame,
remembered on the paired record, and carried on skill rows as ``device_os``."""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from api import device_bridge as db  # noqa: E402
from api import pairing  # noqa: E402


class _FakeSock:
    def shutdown(self, *_a):
        pass

    def close(self):
        pass

    def sendall(self, *_a):
        pass


def _conn(did):
    c = db._DeviceConn(device_id=did, sock=_FakeSock(), conn=None, name="Pranav-Desktop")
    db._register(c)
    return c


def test_normalize_os():
    assert db.normalize_os("Windows") == "windows"
    assert db.normalize_os("Darwin") == "macos"
    assert db.normalize_os("Linux") == "linux"
    assert db.normalize_os("") == "macos"
    assert db.normalize_os(None) == "macos"


def test_register_frame_records_os(monkeypatch):
    saved = {}
    monkeypatch.setattr(pairing, "update_device_fields", lambda did, **f: saved.setdefault(did, {}).update(f) or True)
    monkeypatch.setattr(db, "_ws_send_text", lambda *a, **k: None)
    monkeypatch.setattr(db, "_notify_registry_change", lambda: None)
    c = _conn("pc-1")
    try:
        db._handle_message(c, {"type": "register", "skills": [{"name": "ui_look"}],
                               "platform": {"system": "Windows", "release": "11", "machine": "AMD64"}})
        assert db.device_os("pc-1") == "windows"
        assert saved["pc-1"]["os"] == "windows"
    finally:
        db._unregister("pc-1")


def test_append_frame_keeps_os(monkeypatch):
    monkeypatch.setattr(pairing, "update_device_fields", lambda did, **f: True)
    monkeypatch.setattr(db, "_ws_send_text", lambda *a, **k: None)
    monkeypatch.setattr(db, "_notify_registry_change", lambda: None)
    c = _conn("pc-2")
    try:
        db._handle_message(c, {"type": "register", "skills": [{"name": "a"}], "platform": {"system": "Windows"}})
        db._handle_message(c, {"type": "register", "skills": [{"name": "b"}], "append": True})
        assert db.device_os("pc-2") == "windows"
    finally:
        db._unregister("pc-2")


def test_jc_client_register_shape_sets_windows(monkeypatch):
    """jc-client puts the platform under device.platform (service.py); 2026-11-15 the server read
    only a top-level platform, so the PC stayed "macos" and the Mac answered the PC's screen share."""
    saved = {}
    monkeypatch.setattr(pairing, "update_device_fields", lambda did, **f: saved.update(f) or True)
    monkeypatch.setattr(db, "_ws_send_text", lambda *a, **k: None)
    monkeypatch.setattr(db, "_notify_registry_change", lambda: None)
    c = _conn("pc-3")
    try:
        db._handle_message(c, {"type": "register", "skills": [{"name": "a"}],
                               "device": {"name": "pranav-computer",
                                          "platform": {"system": "Windows", "release": "11", "machine": "AMD64"}}})
        assert db.device_os("pc-3") == "windows"
        assert saved.get("os") == "windows"
    finally:
        db._unregister("pc-3")


def test_skill_rows_carry_device_os(monkeypatch):
    monkeypatch.setattr(pairing, "update_device_fields", lambda did, **f: True)
    monkeypatch.setattr(pairing, "list_devices", lambda: [])
    monkeypatch.setattr(db, "_ws_send_text", lambda *a, **k: None)
    monkeypatch.setattr(db, "_notify_registry_change", lambda: None)
    c = _conn("pc-3")
    try:
        db._handle_message(c, {"type": "register", "skills": [{"name": "ui_look"}], "platform": {"system": "Windows"}})
        rows = [r for r in db.all_device_skills() if r["device_id"] == "pc-3"]
        assert rows and all(r["device_os"] == "windows" for r in rows)
    finally:
        db._unregister("pc-3")


def test_missing_os_defaults_to_macos_for_jc_client(monkeypatch):
    monkeypatch.setattr(pairing, "list_devices", lambda: [{"id": "old-mac", "user_agent": "jc-client/0.1"}])
    assert db.device_os("old-mac") == "macos"


def test_paired_record_os_used_when_offline(monkeypatch):
    monkeypatch.setattr(pairing, "list_devices", lambda: [{"id": "pc-off", "os": "windows"}])
    assert db.device_os("pc-off") == "windows"


def test_os_is_a_mutable_pairing_field():
    assert "os" in pairing._DEVICE_MUTABLE_FIELDS
