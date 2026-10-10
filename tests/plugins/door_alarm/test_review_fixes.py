"""Regressions for the two-reviewer bug sweep (2026-10-10): each test is a finding, failing first."""
import pytest

from plugins.door_alarm import schema
from plugins.door_alarm.alarm import Alarm
from plugins.door_alarm.hub import Hub
from plugins.door_alarm.service import DoorService
from plugins.door_alarm.store import DoorStore
from plugins.toyota.approver import Approvals
from webui.api.door_routes import handle_door_request

from .test_hub import DOOR_BOOL, make
from .test_service import FakeApprover, FakeBridge, FakeCloud, FakePush

SENSOR = {"abilityId": 5, "code": "sensor_state", "name": "Sensor", "accessMode": "ro",
          "typeSpec": {"type": "enum", "range": ["s1", "s2"]}}


def doors(changes):
    return [(c.contact, c.open) for c in changes if c.kind == "door"]


# ── alarm ──

def test_disarm_after_the_siren_timed_out_still_turns_the_siren_off():
    clock = [0.0]
    contacts = [{"id": "dp:x", "name": "X", "open": False, "instant": True}]
    alarm = Alarm({"exit_delay": 0, "siren_duration": 10}, contacts=lambda: contacts, clock=lambda: clock[0])
    alarm.arm("away")
    alarm.door_opened(contacts[0])
    clock[0] += 11
    alarm.tick()                                   # siren timed out (write may have failed)
    assert [e.kind for e in alarm.disarm()][:2] == ["siren_off", "stop_ring"]


def test_silence_always_sends_siren_off():
    clock = [0.0]
    contacts = [{"id": "dp:x", "name": "X", "open": False, "instant": True}]
    alarm = Alarm({"exit_delay": 0, "siren_duration": 10}, contacts=lambda: contacts, clock=lambda: clock[0])
    alarm.arm("away")
    alarm.door_opened(contacts[0])
    clock[0] += 11
    alarm.tick()
    assert [e.kind for e in alarm.silence()] == ["siren_off", "stop_ring"]


def test_no_doors_means_no_arming():
    alarm = Alarm({}, contacts=lambda: [], clock=lambda: 0.0)
    with pytest.raises(ValueError):
        alarm.arm("away")


# ── hub ──

def test_sensor_by_value_contacts_are_not_open_after_a_restart(tmp_path):
    hub, store, clock = make(tmp_path, SENSOR)
    hub.apply([{"dp_id": 5, "value": "s1"}], source="cloud")
    again = Hub(store, clock=lambda: clock[0])
    assert all(c["open"] is None for c in again.contacts())
    assert again.open_contacts() == []


def test_open_close_open_quickly_on_one_link_is_three_events(tmp_path):
    hub, _store, clock = make(tmp_path, DOOR_BOOL)
    hub.apply([{"dp_id": 1, "value": True}], source="esp32")
    clock[0] += 1.2
    hub.apply([{"dp_id": 1, "value": False}], source="esp32")
    clock[0] += 1.3
    assert doors(hub.apply([{"dp_id": 1, "value": True}], source="esp32")) == [("dp:doorcontact_state", True)]
    assert hub.contacts()[0]["open"] is True


def test_a_late_cloud_copy_of_an_open_is_not_a_second_opening(tmp_path):
    hub, _store, clock = make(tmp_path, DOOR_BOOL)
    hub.apply([{"dp_id": 1, "value": True}], source="esp32")
    clock[0] += 12
    assert doors(hub.apply([{"code": "doorcontact_state", "value": True}], source="cloud")) == []


def test_reports_carry_their_own_time_and_old_ones_are_late(tmp_path):
    hub, _store, clock = make(tmp_path, DOOR_BOOL, now=[1_800_000_000.0])
    changes = hub.apply([{"dp_id": 1, "value": True, "t": clock[0] - 1200}], source="esp32")
    assert changes[0].late is True and changes[0].t == clock[0] - 1200
    fresh = hub.apply([{"dp_id": 1, "value": False, "t": clock[0]}], source="esp32")
    assert fresh[0].late is False


def test_doorbell_codes_are_not_doors():
    dps = schema.parse_model({"services": [{"properties": [
        {"abilityId": 1, "code": "doorbell_volume", "accessMode": "rw", "typeSpec": {"type": "value", "min": 0, "max": 5}},
        {"abilityId": 2, "code": "doorbell_song", "accessMode": "rw", "typeSpec": {"type": "value", "min": 1, "max": 32}},
    ]}]})
    roles = schema.roles(dps)
    assert roles["door"] == [] and roles["volume"] == ["doorbell_volume"] and roles["ringtone"] == ["doorbell_song"]


def test_a_product_file_written_after_setup_applies_on_reload(tmp_path, monkeypatch):
    hub, store, _clock = make(tmp_path, DOOR_BOOL)
    store.update_config(product_id="pid9")
    products = tmp_path / "products"
    products.mkdir()
    (products / "pid9.json").write_text('{"roles": {"door": [], "siren": ["doorcontact_state"]}}')
    monkeypatch.setattr(schema, "PRODUCTS_DIR", products)
    hub.reload()
    assert hub.roles["door"] == [] and hub.roles["siren"] == ["doorcontact_state"]


# ── service ──

@pytest.fixture
def env(tmp_path):
    clock = [1_800_000_000.0]
    bridge, cloud, push = FakeBridge(), FakeCloud(), FakePush()
    order = []
    svc = DoorService(store=DoorStore(tmp_path), clock=lambda: clock[0], bridge=bridge, push=push,
                      cloud=lambda: cloud, approver=FakeApprover(), approvals=Approvals(clock=lambda: clock[0]),
                      run_prompt=lambda p: None, run=lambda fn: fn(), confirm_timeout=0.2)
    bridge.service = svc
    svc.pick("hub1")
    svc.set_proxy("board1")
    svc.update_settings({"alarm": {"exit_delay": 0, "entry_delay": 0, "siren_duration": 180}})
    bridge.calls.clear()
    return svc, clock, bridge, push


def test_alerts_go_out_before_any_hub_write(env):
    svc, clock, bridge, push = env
    svc.arm("away")
    svc.on_board_event("board1", "door_report", {"dps": {"1": True}, "t": 0, "seq": 1})
    skills = [c[1] for c in bridge.calls]
    assert skills.index("door_alarm_ring") < skills.index("esp32_door_set")
    assert skills.index("pod_show") < skills.index("esp32_door_set")


def test_the_phone_rings_even_without_a_live_link(env):
    svc, clock, bridge, push = env
    bridge.connected = {"board1"}             # phone asleep: only the push wake can reach it
    svc.arm("away")
    svc.on_board_event("board1", "door_report", {"dps": {"1": True}, "t": 0, "seq": 1})
    assert any(c[1] == "door_alarm_ring" for c in bridge.calls)


def test_a_replayed_old_opening_does_not_set_off_the_alarm(env):
    svc, clock, bridge, push = env
    svc.arm("home")
    svc.on_board_event("board1", "door_report", {"dps": {"1": True}, "t": clock[0] - 1200, "seq": 1})
    assert svc.alarm.state == "armed_home"


def test_siren_preferences_are_checked_against_the_hub(env):
    svc, *_ = env
    with pytest.raises(ValueError):
        svc.update_settings({"siren": {"volume": "silent"}})
    svc.update_settings({"siren": {"volume": "middle"}})
    assert svc.settings()["siren"]["volume"] == "middle"


# ── routes: what Jarvis (host-signed) and other paired devices may do ──

def call(svc, method, path, body=None, host=False, caller=None):
    return handle_door_request(method, path, body, host_signed=host, service=svc, caller=caller)


def test_jarvis_cannot_rearm_switch_modes_or_bypass_closed_doors(env):
    svc, *_ = env
    assert call(svc, "POST", "/arm", {"mode": "away", "bypass": ["dp:doorcontact_state"]}, host=True)[0] == 400
    assert call(svc, "POST", "/arm", {"mode": "away"}, host=True)[0] == 200
    assert call(svc, "POST", "/arm", {"mode": "home"}, host=True)[0] == 403
    assert call(svc, "POST", "/arm", {"mode": "away"}, host=True)[0] == 403


def test_jarvis_cannot_touch_hub_settings_while_armed(env):
    svc, *_ = env
    call(svc, "POST", "/arm", {"mode": "home"})
    assert call(svc, "POST", "/set", {"code": "alarm_switch", "value": False}, host=True)[0] == 403


def test_jarvis_may_only_rename_doors_in_settings(env):
    svc, *_ = env
    assert call(svc, "POST", "/settings", {"alarm": {"entry_delay": 300}}, host=True)[0] == 403
    assert call(svc, "POST", "/settings", {"contacts": {"dp:doorcontact_state": {"on_open_prompt": "x"}}},
                host=True)[0] == 403
    assert call(svc, "POST", "/settings", {"contacts": {"dp:doorcontact_state": {"instant": False}}},
                host=True)[0] == 403
    status, payload = call(svc, "POST", "/settings", {"contacts": {"dp:doorcontact_state": {"name": "Front"}}}, host=True)
    assert status == 200 and payload["contacts"][0]["name"] == "Front"


def test_jarvis_history_source_is_always_jarvis(env):
    svc, *_ = env
    call(svc, "POST", "/arm", {"mode": "away", "source": "app"}, host=True)
    assert svc.history(5)[0]["source"] == "Jarvis"


def test_boards_and_the_pod_cannot_change_anything(env):
    svc, *_ = env
    for path, body in (("/arm", {"mode": "away"}), ("/settings", {"alarm": {"entry_delay": 300}}),
                       ("/setup/proxy", {"board_id": ""}), ("/set", {"code": "alarm_volume", "value": "low"})):
        assert call(svc, "POST", path, body, caller="board")[0] == 403, path
    assert call(svc, "GET", "/state", caller="board")[0] == 200


def test_the_proxy_must_be_a_connected_door_capable_board(env, monkeypatch):
    svc, *_ = env
    monkeypatch.setattr("webui.api.door_routes._proxies", lambda: [{"id": "board1", "name": "Board"}])
    assert call(svc, "POST", "/setup/proxy", {"board_id": "phone1"})[0] == 400
    assert call(svc, "POST", "/setup/proxy", {"board_id": "board1"})[0] == 200


def test_server_only_device_skills_are_hidden_from_the_agent():
    from webui.api.device_bridge import SERVER_ONLY_SKILLS
    assert {"esp32_door_set", "esp32_door_configure", "esp32_door_forget", "door_alarm_ring"} <= SERVER_ONLY_SKILLS


# ── who counts as a board (2026-10-10 live bug: the phone relays esp32_* skills and was refused) ──

def test_a_phone_that_relays_board_skills_is_not_a_board():
    from webui.api.door_routes import caller_kind
    phone = {"id": "p", "kind": "mobile-ios"}
    assert caller_kind(phone, ["open_app", "esp32_get_state", "pod_show", "door_alarm_ring"]) is None
    assert caller_kind({"id": "x", "kind": "browser"}, ["open_app", "esp32_get_state"]) is None


def test_a_board_or_pod_session_is_a_board():
    from webui.api.door_routes import caller_kind
    assert caller_kind({"id": "b", "kind": "browser"}, ["esp32_get_state", "esp32_door_set"]) == "board"
    assert caller_kind({"id": "pod", "kind": "browser"}, ["pod_show", "pod_status"]) == "board"
    assert caller_kind({"id": "web", "kind": "browser"}, []) is None


# ── his hub (PHYSEN wxml p9marmvo8k9lfhz6): English everywhere, sensors decoded (2026-10-10) ──

WXML = [
    {"abilityId": 1, "code": "doorbell_list_data", "name": "门铃列表数据", "accessMode": "rw", "typeSpec": {"type": "raw"}},
    {"abilityId": 2, "code": "doorbell_ring_value", "name": "门铃铃声", "accessMode": "rw",
     "typeSpec": {"type": "value", "min": 0, "max": 32, "step": 1}},
    {"abilityId": 3, "code": "doorbell_volume_value", "name": "门铃音量", "accessMode": "rw",
     "typeSpec": {"type": "value", "min": 0, "max": 100, "step": 1}},
    {"abilityId": 5, "code": "alarm_message", "name": "告警消息", "accessMode": "rw", "typeSpec": {"type": "raw"}},
    {"abilityId": 7, "code": "disturb_time_set", "name": "勿扰时段", "accessMode": "rw", "typeSpec": {"type": "raw"}},
    {"abilityId": 10, "code": "doorbell_call", "name": "门铃呼叫", "accessMode": "ro",
     "typeSpec": {"type": "value", "min": 1, "max": 32}},
    {"abilityId": 101, "code": "doorbell_mode", "name": "模式", "accessMode": "rw",
     "typeSpec": {"type": "enum", "range": ["LightSound", "Sound", "Light"]}},
    {"abilityId": 103, "code": "accessery_id", "name": "子设备序号", "accessMode": "ro",
     "typeSpec": {"type": "value", "min": 1, "max": 8}},
    {"abilityId": 104, "code": "mode_alarmid", "name": "模式告警信息", "accessMode": "rw",
     "typeSpec": {"type": "enum", "range": ["LightSound", "Sound", "Light", "Invalid"]}},
]
FRONT_DOOR = "AEYAcgBvAG4AdAAgAEQAbwBvAHI="  # UTF-16BE "Front Door"


def wxml_hub(tmp_path):
    clock = [1_800_000_000.0]
    store = DoorStore(tmp_path)
    dps = schema.parse_model({"services": [{"properties": WXML}]})
    store.save_config({"dev_id": "hub1", "product_id": "p9marmvo8k9lfhz6",
                       "dps": [d.public() for d in dps.values()], "roles": schema.roles(dps, "p9marmvo8k9lfhz6")})
    return Hub(store, clock=lambda: clock[0]), store, clock


def test_every_name_on_his_hub_is_english(tmp_path):
    hub, _store, _clock = wxml_hub(tmp_path)
    public = hub.public()
    assert all(d["name"].isascii() for d in public["dps"]), [d["name"] for d in public["dps"]]
    names = {d["code"]: d["name"] for d in public["dps"]}
    assert names["doorbell_volume_value"] == "Volume" and names["doorbell_ring_value"] == "Ringtone"
    mode = next(d for d in public["dps"] if d["code"] == "doorbell_mode")
    assert mode["option_labels"]["LightSound"] == "Light + sound"


def test_raw_fields_are_hidden_or_decoded(tmp_path):
    hub, _store, _clock = wxml_hub(tmp_path)
    hub.apply([{"code": "alarm_message", "value": FRONT_DOOR}], source="cloud", snapshot=True)
    public = hub.public()
    hidden = {d["code"] for d in public["dps"] if d["hidden"]}
    assert {"doorbell_list_data", "disturb_time_set"} <= hidden
    assert public["values"]["alarm_message"]["display"] == "Front Door"


def test_a_door_opening_on_his_hub_is_the_named_sensor(tmp_path):
    hub, _store, clock = wxml_hub(tmp_path)
    hub.apply([{"code": "alarm_message", "value": FRONT_DOOR}], source="cloud", snapshot=True)
    assert [c["name"] for c in hub.contacts()] == ["Front Door"]       # learned from the snapshot, no opening
    clock[0] += 10
    changes = hub.apply([{"code": "alarm_message", "value": FRONT_DOOR}], source="cloud")
    assert [(c.kind, c.open) for c in changes] == [("door", True)]


def test_any_other_chinese_name_becomes_readable_english():
    assert schema.english("门铃音量", "doorbell_volume_value") == "Doorbell volume value"
    assert schema.english("Volume", "x") == "Volume"


def test_a_status_read_fills_values_and_lists_sensors(tmp_path):
    from .test_service import FakeBridge, FakeCloud, FakePush, FakeApprover
    store = DoorStore(tmp_path)
    dps = schema.parse_model({"services": [{"properties": WXML}]})
    store.save_config({"dev_id": "hub1", "product_id": "p9marmvo8k9lfhz6",
                       "dps": [d.public() for d in dps.values()], "roles": schema.roles(dps, "p9marmvo8k9lfhz6")})
    cloud = FakeCloud()
    cloud.properties = lambda dev_id: [{"code": "alarm_message", "value": FRONT_DOOR, "dp_id": 5},
                                       {"code": "doorbell_volume_value", "value": 44, "dp_id": 3}]
    svc = DoorService(store=store, bridge=FakeBridge(), push=FakePush(), cloud=lambda: cloud,
                      approver=FakeApprover(), run=lambda fn: fn())
    svc.refresh_values()
    state = svc.state()
    assert state["hub"]["values"]["doorbell_volume_value"]["value"] == 44
    assert [c["name"] for c in state["hub"]["contacts"]] == ["Front Door"]


# ── real-time UI (task 4): arm now, deadlines, the phone popup ──

def test_arm_now_skips_the_exit_delay():
    clock = [1000.0]
    contacts = [{"id": "dp:x", "name": "X", "open": False}]
    alarm = Alarm({"exit_delay": 60}, contacts=lambda: contacts, clock=lambda: clock[0])
    alarm.arm("away")
    assert alarm.public()["deadline"] == 1060.0
    alarm.arm_now()
    assert alarm.state == "armed_away" and alarm.public()["deadline"] is None
    with pytest.raises(ValueError):
        alarm.arm_now()          # only while the exit delay runs


def test_a_tripped_door_pops_the_alarm_on_the_phone(env):
    svc, clock, bridge, push = env
    svc.update_settings({"alarm": {"entry_delay": 30}})
    svc.arm("away")
    svc.on_board_event("board1", "door_report", {"dps": {"1": True}, "t": 0, "seq": 1})
    assert any(c[1] == "door_show_alarm" for c in bridge.calls)


def test_arm_now_route(env):
    svc, *_ = env
    svc.update_settings({"alarm": {"exit_delay": 60}})
    call(svc, "POST", "/arm", {"mode": "away"})
    status, payload = call(svc, "POST", "/arm_now", {})
    assert status == 200 and payload["alarm"]["state"] == "armed_away"
    assert call(svc, "POST", "/arm_now", {})[0] == 400


def test_cancel_arming_only_during_the_exit_delay():
    clock = [1000.0]
    contacts = [{"id": "dp:x", "name": "X", "open": False}]
    alarm = Alarm({"exit_delay": 60}, contacts=lambda: contacts, clock=lambda: clock[0])
    alarm.arm("away")
    alarm.cancel_arming()
    assert alarm.state == "disarmed"
    alarm.arm("home")
    with pytest.raises(ValueError):
        alarm.cancel_arming()     # armed: that's a disarm, which needs Face ID


def test_only_the_phone_cancels_arming(env):
    svc, *_ = env
    svc.update_settings({"alarm": {"exit_delay": 60}})
    call(svc, "POST", "/arm", {"mode": "away"})
    assert call(svc, "POST", "/cancel_arming", {}, host=True)[0] == 403   # not Jarvis / the Pod
    status, payload = call(svc, "POST", "/cancel_arming", {})
    assert status == 200 and payload["alarm"]["state"] == "disarmed"


def test_the_pod_shows_arming_and_disarmed(env):
    svc, clock, bridge, push = env
    svc.update_settings({"alarm": {"exit_delay": 60}})
    bridge.calls.clear()
    svc.arm("away")
    page = [c[2]["page"] for c in bridge.calls if c[1] == "pod_show"][-1]
    assert '"timer"' in __import__("json").dumps(page) and "Arming" in __import__("json").dumps(page)
    timer = [c for c in page["root"]["children"] if c["type"] == "timer"][0]
    assert timer["in"] == 60   # seconds left, so a Pod whose clock is off still counts right
    svc.cancel_arming()
    page = [c[2]["page"] for c in bridge.calls if c[1] == "pod_show"][-1]
    assert "Disarmed" in __import__("json").dumps(page)


def test_the_pod_beeps_while_arming_and_sounds_the_siren(env):
    svc, clock, bridge, push = env
    svc.update_settings({"alarm": {"exit_delay": 60, "entry_delay": 0}})
    bridge.calls.clear()
    svc.arm("away")
    page = [c[2]["page"] for c in bridge.calls if c[1] == "pod_show"][-1]
    assert page["sound"]["name"] == "beep" and page["sound"]["for_s"] == 60
    svc.arm_now()
    svc.on_board_event("board1", "door_report", {"dps": {"1": True}, "t": 0, "seq": 9})
    alarm_pages = [c[2]["page"] for c in bridge.calls if c[1] == "pod_show" and "ALARM" in str(c[2]["page"])]
    assert alarm_pages and alarm_pages[-1]["sound"]["name"] == "siren" and alarm_pages[-1]["sound"]["loud"]


def test_the_pod_alarm_goes_out_before_the_slow_phone_calls(env):
    svc, clock, bridge, push = env
    svc.update_settings({"alarm": {"exit_delay": 0, "entry_delay": 30}})
    svc.arm("away")
    svc.on_board_event("board1", "door_report", {"dps": {"1": True}, "t": 0, "seq": 9})
    bridge.calls.clear()
    clock[0] += 30
    svc.tick()
    skills = [c[1] for c in bridge.calls]
    assert skills[0] == "pod_show" and bridge.calls[0][2]["page"]["sound"]["name"] == "siren"
    assert skills.count("pod_show") == 1          # shown once, not again by the effect
