"""machine_id(): this computer's stable hardware id, hashed, so a re-pair keeps the same device record on the server
(2026-11-24: every re-pair made a new record)."""
import json

from jc_client import machine


def test_same_computer_same_id_and_the_raw_id_never_leaves(monkeypatch):
    monkeypatch.setattr(machine, "_raw", lambda: ("win", "8f0c3d2a-1111-2222-3333-444455556666"))
    a, b = machine.machine_id(), machine.machine_id()
    assert a == b and a.startswith("win-") and len(a) == 36 and "8f0c3d2a" not in a


def test_no_hardware_id_sends_nothing(monkeypatch):
    monkeypatch.setattr(machine, "_raw", lambda: ("win", ""))
    assert machine.machine_id() == ""


def test_pairing_sends_it(monkeypatch):
    from jc_client import pair_listener
    sent = {}

    class Resp:
        status, cookie, body = 401, "", b"{}"

        def json(self):
            return {}

    class Client:
        def __init__(self, *a, **k):
            pass

        def post_json(self, path, body):
            sent.update(body)
            return Resp(), ""
    monkeypatch.setattr("jc_client.protocol.HttpClient", Client)
    monkeypatch.setattr(machine, "machine_id", lambda: "win-0123456789abcdef0123456789abcdef")
    pair_listener.claim("https://jarvis.example", "ABC-DEF", "pc")
    assert sent.get("machine_id") == "win-0123456789abcdef0123456789abcdef"


def test_register_frame_carries_it(monkeypatch):
    from jc_client import service
    monkeypatch.setattr(machine, "machine_id", lambda: "mac-0123456789abcdef0123456789abcdef")
    frame = service._register_head({"name": "pc"})
    assert frame["machine_id"] == "mac-0123456789abcdef0123456789abcdef" and json.dumps(frame)
