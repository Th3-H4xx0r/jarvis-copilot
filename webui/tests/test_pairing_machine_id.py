"""A re-paired computer, phone or board keeps its one device record (2026-11-24: every re-pair made a new record,
so the PC card showed a stale second PC, the power button lost its link and the unlock permission no longer
matched). Devices send a stable hardware id (machine_id) when pairing and registering."""
import pytest

from api import pairing


@pytest.fixture
def store(tmp_path, monkeypatch):
    monkeypatch.setattr(pairing, "_PENDING_FILE", tmp_path / ".pending_pair.json")
    monkeypatch.setattr(pairing, "_DEVICES_FILE", tmp_path / ".devices.json")
    forgotten = []

    class Power:
        def forget(self, did):
            forgotten.append(did)
    monkeypatch.setattr("api.mac_power.store", lambda: Power())
    return forgotten


def _claim(name, machine_id=""):
    code = pairing.create_pairing_code(label=name)["code"]
    return pairing.claim_pairing_code(code, device_name=name, machine_id=machine_id)


def test_a_repair_with_the_same_machine_id_keeps_the_record(store):
    first = _claim("pranav-computer", "win-abc")
    old = pairing.find_device_by_session(first)
    second = _claim("pranav-computer", "win-abc")
    devices = pairing.list_devices()
    assert len(devices) == 1 and devices[0]["id"] == old["id"]
    assert pairing.find_device_by_session(second)["id"] == old["id"]
    assert pairing.find_device_by_session(first) is None        # the old session no longer maps to it


def test_different_machines_with_one_name_stay_apart(store):
    _claim("Jarvis-ESP32 board", "esp32-aaaa")
    _claim("Jarvis-ESP32 board", "esp32-bbbb")
    _claim("Jarvis-ESP32 board")                                 # an old firmware without an id
    assert len(pairing.list_devices()) == 3


def test_registering_a_machine_id_retires_older_duplicates(store):
    old = pairing.find_device_by_session(_claim("pranav-computer", "win-abc"))
    new = pairing.find_device_by_session(_claim("pranav-computer"))   # an old client re-paired without an id
    retired = pairing.adopt_machine_id(new["id"], "win-abc")
    assert retired == [old["id"]] and store == [old["id"]]
    assert [d["id"] for d in pairing.list_devices()] == [new["id"]]


def test_adopting_again_changes_nothing(store):
    dev = pairing.find_device_by_session(_claim("pranav-computer", "win-abc"))
    assert pairing.adopt_machine_id(dev["id"], "win-abc") == [] and store == []
