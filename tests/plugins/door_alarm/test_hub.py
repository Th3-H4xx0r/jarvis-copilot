"""Hub state: door events from DP reports (both links), dedupe, snapshots, contacts, storage."""
import json
import stat

from plugins.door_alarm import schema
from plugins.door_alarm.hub import Hub
from plugins.door_alarm.store import DoorStore


def model(*props):
    return {"services": [{"properties": list(props)}]}


DOOR_BOOL = {"abilityId": 1, "code": "doorcontact_state", "name": "Door", "accessMode": "ro", "typeSpec": {"type": "bool"}}
VOLUME = {"abilityId": 2, "code": "alarm_volume", "name": "Volume", "accessMode": "rw",
          "typeSpec": {"type": "enum", "range": ["low", "high"]}}


def make(tmp_path, *props, now=None):
    clock = now or [1000.0]
    store = DoorStore(tmp_path)
    dps = schema.parse_model(model(*props))
    store.save_config({"dev_id": "hub1", "dps": [d.public() for d in dps.values()], "roles": schema.roles(dps)})
    return Hub(store, clock=lambda: clock[0]), store, clock


def doors(changes):
    return [(c.contact, c.open, c.missed) for c in changes if c.kind == "door"]


def test_open_close_and_dedupe_across_links(tmp_path):
    hub, _store, clock = make(tmp_path, DOOR_BOOL, VOLUME)
    assert doors(hub.apply([{"dp_id": 1, "value": True}], source="esp32")) == [("dp:doorcontact_state", True, False)]
    clock[0] += 1.5  # the cloud reports the same open a moment later
    assert doors(hub.apply([{"code": "doorcontact_state", "value": True}], source="cloud")) == []
    clock[0] += 3
    assert doors(hub.apply([{"dp_id": 1, "value": False}], source="esp32")) == [("dp:doorcontact_state", False, False)]


def test_a_sensor_that_only_ever_says_open_counts_every_opening(tmp_path):
    hub, _store, clock = make(tmp_path, DOOR_BOOL)
    assert len(doors(hub.apply([{"dp_id": 1, "value": True}], source="esp32"))) == 1
    clock[0] += 6
    assert doors(hub.apply([{"dp_id": 1, "value": True}], source="esp32")) == [("dp:doorcontact_state", True, False)]


def test_snapshots_only_report_differences_marked_missed(tmp_path):
    hub, _store, clock = make(tmp_path, DOOR_BOOL)
    hub.apply([{"dp_id": 1, "value": False}], source="esp32")
    clock[0] += 60
    assert doors(hub.apply([{"dp_id": 1, "value": False}], source="esp32", snapshot=True)) == []
    clock[0] += 60
    assert doors(hub.apply([{"dp_id": 1, "value": True}], source="esp32", snapshot=True)) == [("dp:doorcontact_state", True, True)]


def test_two_door_points_make_two_contacts(tmp_path):
    second = dict(DOOR_BOOL, abilityId=3, code="doorcontact_state_2", name="Back door")
    hub, _store, _clock = make(tmp_path, DOOR_BOOL, second)
    ids = [c["id"] for c in hub.contacts()]
    assert ids == ["dp:doorcontact_state", "dp:doorcontact_state_2"]
    assert hub.contacts()[1]["name"] == "Back door"


def test_one_point_naming_the_sensor_learns_contacts_by_value(tmp_path):
    sensor = {"abilityId": 5, "code": "sensor_state", "name": "Sensor", "accessMode": "ro",
              "typeSpec": {"type": "enum", "range": ["s1", "s2"]}}
    hub, _store, clock = make(tmp_path, sensor)
    assert doors(hub.apply([{"dp_id": 5, "value": "s1"}], source="cloud")) == [("sensor_state=s1", True, False)]
    clock[0] += 1
    assert doors(hub.apply([{"dp_id": 5, "value": "s2"}], source="cloud")) == [("sensor_state=s2", True, False)]
    assert [c["id"] for c in hub.contacts()] == ["sensor_state=s1", "sensor_state=s2"]


def test_values_and_link_health_are_public_without_the_key(tmp_path):
    hub, store, _clock = make(tmp_path, DOOR_BOOL, VOLUME)
    store.save_secret({"local_key": "0123456789abcdef"})
    hub.apply([{"dp_id": 2, "value": "high"}], source="esp32")
    hub.local_link({"state": "connected", "ip": "192.168.1.50", "version": "3.5", "rtt_ms": 40})
    public = hub.public()
    assert public["values"]["alarm_volume"]["value"] == "high"
    assert public["link"]["local"]["state"] == "connected"
    assert "0123456789abcdef" not in json.dumps(public)
    assert stat.S_IMODE((tmp_path / "secret.json").stat().st_mode) == 0o600


def test_events_are_logged_and_filtered(tmp_path):
    hub, store, clock = make(tmp_path, DOOR_BOOL)
    hub.apply([{"dp_id": 1, "value": True}], source="esp32")
    clock[0] += 10
    hub.apply([{"dp_id": 1, "value": False}], source="esp32")
    store.append_event({"t": clock[0], "kind": "alarm", "state": "armed_away"})
    assert [e["kind"] for e in store.events(limit=10)] == ["alarm", "door", "door"]  # newest first
    assert len(store.events(limit=10, contact="dp:doorcontact_state")) == 2
