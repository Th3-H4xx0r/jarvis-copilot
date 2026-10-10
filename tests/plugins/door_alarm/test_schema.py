"""The hub's data points: parsing Tuya's thing model / specifications, roles, value checks."""
import json

import pytest

from plugins.door_alarm import schema

MODEL = {"services": [{"properties": [
    {"abilityId": 1, "code": "doorcontact_state", "name": "Door", "accessMode": "ro", "typeSpec": {"type": "bool"}},
    {"abilityId": 2, "code": "alarm_volume", "name": "Volume", "accessMode": "rw",
     "typeSpec": {"type": "enum", "range": ["low", "middle", "high", "mute"]}},
    {"abilityId": 3, "code": "alarm_ringtone", "name": "Ringtone", "accessMode": "rw",
     "typeSpec": {"type": "value", "min": 1, "max": 32, "step": 1, "scale": 0, "unit": ""}},
    {"abilityId": 4, "code": "battery_percentage", "name": "Battery", "accessMode": "ro",
     "typeSpec": {"type": "value", "min": 0, "max": 100, "step": 1, "scale": 0, "unit": "%"}},
    {"abilityId": 5, "code": "alarm_switch", "name": "Siren", "accessMode": "rw", "typeSpec": {"type": "bool"}},
    {"abilityId": 6, "code": "sub_info", "name": "Sensors", "accessMode": "ro", "typeSpec": {"type": "raw", "maxlen": 64}},
    {"abilityId": 7, "code": "temper_alarm", "name": "Tamper", "accessMode": "ro", "typeSpec": {"type": "bool"}},
    {"abilityId": 8, "code": "work_mode", "name": "Mode", "accessMode": "rw",
     "typeSpec": {"type": "enum", "range": ["doorbell", "alarm", "chime"]}},
]}]}

SPECS = {"category": "wxml", "functions": [
    {"dp_id": 2, "code": "alarm_volume", "type": "Enum", "values": json.dumps({"range": ["low", "high"]})}],
    "status": [
    {"dp_id": 1, "code": "doorcontact_state", "type": "Boolean", "values": "{}"},
    {"dp_id": 2, "code": "alarm_volume", "type": "Enum", "values": json.dumps({"range": ["low", "high"]})},
    {"dp_id": 9, "code": "duration", "type": "Integer", "values": json.dumps({"min": 0, "max": 180, "step": 5, "unit": "s"})}]}


def test_thing_model_is_parsed_by_id():
    dps = schema.parse_model(MODEL)
    assert set(dps) == {1, 2, 3, 4, 5, 6, 7, 8}
    assert dps[2].type == "enum" and dps[2].range == ["low", "middle", "high", "mute"]
    assert dps[3].min == 1 and dps[3].max == 32 and dps[3].step == 1
    assert dps[1].mode == "ro" and dps[5].mode == "rw"
    assert dps[6].type == "raw"


def test_specifications_shape_is_parsed_too_with_function_only_writes():
    dps = schema.parse_specifications(SPECS)
    assert dps[2].mode == "rw" and dps[1].mode == "ro" and dps[9].mode == "ro"
    assert dps[9].type == "value" and dps[9].unit == "s" and dps[9].step == 5


def test_roles_from_code_names():
    roles = schema.roles(schema.parse_model(MODEL))
    assert roles["door"] == ["doorcontact_state"]
    assert roles["volume"] == ["alarm_volume"]
    assert roles["ringtone"] == ["alarm_ringtone"]
    assert roles["siren"] == ["alarm_switch"]
    assert roles["battery"] == ["battery_percentage"]
    assert roles["tamper"] == ["temper_alarm"]
    assert roles["mode"] == ["work_mode"]


def test_product_file_overrides_roles(tmp_path):
    (tmp_path / "pid1.json").write_text(json.dumps({"roles": {"door": ["sub_info"], "siren": []}}))
    roles = schema.roles(schema.parse_model(MODEL), "pid1", products_dir=tmp_path)
    assert roles["door"] == ["sub_info"]
    assert roles["siren"] == []
    assert roles["volume"] == ["alarm_volume"]  # untouched roles keep the heuristic


@pytest.mark.parametrize("dp_id,value,expected", [
    (5, "true", True), (5, 0, False), (2, "high", "high"), (3, 7, 7), (3, "12", 12)])
def test_coerce_accepts_valid_values(dp_id, value, expected):
    assert schema.coerce(schema.parse_model(MODEL)[dp_id], value) == expected


@pytest.mark.parametrize("dp_id,value", [(2, "loud"), (3, 33), (3, 0), (3, 2.5), (1, True), (5, "maybe")])
def test_coerce_rejects_bad_values(dp_id, value):
    with pytest.raises(ValueError):
        schema.coerce(schema.parse_model(MODEL)[dp_id], value)


def test_public_view_is_json_safe():
    dps = schema.parse_model(MODEL)
    out = [d.public() for d in dps.values()]
    json.dumps(out)
    assert out[0]["code"] == "doorcontact_state" and out[0]["writable"] is False
