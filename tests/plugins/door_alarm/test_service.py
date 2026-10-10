"""DoorService wiring: reports → alarm → effects, commands over ESP32 then cloud, Face ID, health, setup."""
import pytest

from plugins.door_alarm.alarm import ArmRefused
from plugins.door_alarm.service import CommandFailed, DoorService, NotSetUp
from plugins.door_alarm.store import DoorStore
from plugins.door_alarm.tuya_cloud import TuyaError
from plugins.toyota.approver import ApprovalError, Approvals

MODEL = {"services": [{"properties": [
    {"abilityId": 1, "code": "doorcontact_state", "name": "Front Door", "accessMode": "ro", "typeSpec": {"type": "bool"}},
    {"abilityId": 2, "code": "alarm_volume", "name": "Volume", "accessMode": "rw",
     "typeSpec": {"type": "enum", "range": ["low", "middle", "high", "mute"]}},
    {"abilityId": 3, "code": "alarm_switch", "name": "Siren", "accessMode": "rw", "typeSpec": {"type": "bool"}},
]}]}


class FakeBridge:
    def __init__(self):
        self.calls = []
        self.service = None
        self.connected = {"board1", "phone1", "pod1"}
        self.offers = {"door_alarm_ring": "phone1", "door_show_approvals": "phone1", "door_show_alarm": "phone1", "pod_show": "pod1",
                       "esp32_door_configure": "board1"}
        self.fail_set = False

    def invoke(self, device, skill, args, timeout=10.0):
        self.calls.append((device, skill, args))
        if skill == "esp32_door_set":
            if self.fail_set:
                return {"ok": False, "error": "not connected"}
            self.service.on_board_event(device, "door_report", {"dps": args["dps"], "t": 0, "seq": 1})
        return {"ok": True, "result": {"ok": True}}

    def offering(self, skill):
        return self.offers.get(skill)

    def is_connected(self, device):
        return device in self.connected


class FakePush:
    def __init__(self):
        self.sent = []

    def __call__(self, title, body, data=None, category=None, level=None):
        self.sent.append({"title": title, "body": body, "level": level, "category": category})
        return 1


class FakeCloud:
    def __init__(self):
        self.issued = []
        self.local_key = "0123456789abcdef"
        self.fail = None

    def devices(self):
        return [{"id": "hub1", "name": "Wireless Doorbell", "product_id": "pid", "category": "wxml",
                 "online": True, "local_key": self.local_key}]

    def device(self, dev_id):
        if self.fail:
            raise self.fail
        return {"id": dev_id, "name": "Wireless Doorbell", "product_id": "pid", "product_name": "Door chime",
                "category": "wxml", "online": True, "local_key": self.local_key, "ip": "1.2.3.4"}

    def model(self, dev_id):
        return MODEL

    def properties(self, dev_id):
        return [{"dp_id": 1, "code": "doorcontact_state", "value": False}]

    def issue(self, dev_id, values):
        if self.fail:
            raise self.fail
        self.issued.append(values)


class FakeApprover:
    def __init__(self):
        self.calls = []

    def verify(self, command, nonce, ts, signature, domain="jarvis-car"):
        self.calls.append((command, nonce, domain))
        if signature != "good":
            raise ApprovalError("Face ID approval didn't check out on this server.", "bad_signature")


@pytest.fixture
def env(tmp_path):
    clock = [10_000.0]
    bridge, push, cloud, prompts = FakeBridge(), FakePush(), FakeCloud(), []
    svc = DoorService(store=DoorStore(tmp_path), clock=lambda: clock[0], bridge=bridge, push=push,
                      cloud=lambda: cloud, approver=FakeApprover(), approvals=Approvals(clock=lambda: clock[0]),
                      run_prompt=prompts.append, run=lambda fn: fn(), confirm_timeout=0.2)
    bridge.service = svc
    svc.pick("hub1")
    svc.set_proxy("board1")
    svc.update_settings({"alarm": {"exit_delay": 0, "entry_delay": 30, "siren_duration": 180}})
    bridge.calls.clear()
    return svc, clock, bridge, push, cloud, prompts


def door(svc, open_, source="esp32", query=False):
    if source == "esp32":
        svc.on_board_event("board1", "door_report", {"dps": {"1": open_}, "t": 0, "seq": 2, "query": query})
    else:
        svc.on_cloud_report([{"code": "doorcontact_state", "value": open_, "t": 0, "dp_id": 1}])


def test_setup_stores_the_key_privately_and_configures_the_board(tmp_path):
    clock = [1.0]
    bridge, cloud = FakeBridge(), FakeCloud()
    svc = DoorService(store=DoorStore(tmp_path), clock=lambda: clock[0], bridge=bridge, push=FakePush(),
                      cloud=lambda: cloud, approver=FakeApprover(), run=lambda fn: fn())
    bridge.service = svc
    devices = svc.list_cloud_devices()
    assert devices[0]["id"] == "hub1" and "local_key" not in devices[0]
    svc.pick("hub1")
    svc.set_proxy("board1")
    configure = [c for c in bridge.calls if c[1] == "esp32_door_configure"][-1]
    assert configure[0] == "board1" and configure[2]["local_key"] == "0123456789abcdef"
    state = svc.state()
    assert "0123456789abcdef" not in str(state)
    assert state["setup"]["hub"] and state["setup"]["proxy"] == "board1"


def test_an_armed_door_opening_runs_entry_then_the_full_alarm(env):
    svc, clock, bridge, push, cloud, _ = env
    svc.arm("away")
    door(svc, True)
    assert svc.alarm.state == "entry"
    assert push.sent[-1]["level"] == "time-sensitive" and "Front Door" in push.sent[-1]["title"]
    clock[0] += 30
    svc.tick()
    assert svc.alarm.state == "triggered"
    skills = [c[1] for c in bridge.calls]
    assert "esp32_door_set" in skills            # siren on the hub
    assert "door_alarm_ring" in skills           # AlarmKit on the phone
    assert "pod_show" in skills                  # red page on the Pod
    siren = [c[2]["dps"] for c in bridge.calls if c[1] == "esp32_door_set"]
    assert {"3": True} in siren and {"2": "high"} in siren   # siren + loudest non-mute volume


def test_the_same_open_on_both_links_counts_once(env):
    svc, clock, _bridge, push, _cloud, _ = env
    svc.arm("away")
    door(svc, True, "esp32")
    clock[0] += 1
    door(svc, True, "cloud")
    assert len([p for p in push.sent if "opened" in p["title"]]) == 1


def test_a_reconnect_snapshot_does_not_open_a_door(env):
    svc, clock, _bridge, push, _cloud, _ = env
    door(svc, False)
    svc.arm("away")
    clock[0] += 60
    door(svc, False, query=True)
    assert svc.alarm.state == "armed_away"


def test_disarm_needs_a_home_domain_face_id_signature(env):
    svc, clock, _bridge, _push, _cloud, _ = env
    svc.arm("home")
    with pytest.raises(ApprovalError):
        svc.disarm({"nonce": "n1", "ts": 1, "signature": "bad"})
    assert svc.alarm.state == "armed_home"
    svc.disarm({"nonce": "n2", "ts": 1, "signature": "good"})
    assert svc.alarm.state == "disarmed"
    assert svc.approver.calls[-1] == ("disarm", "n2", "jarvis-home")


def test_jarvis_can_only_ask_for_a_disarm_approval(env):
    svc, _clock, bridge, push, _cloud, _ = env
    svc.arm("away")
    item = svc.create_approval("disarm")
    assert svc.alarm.state != "disarmed"
    assert any(c[1] == "door_show_approvals" for c in bridge.calls)
    svc.answer_approval(item["id"], {"ts": 1, "signature": "good"})
    assert svc.alarm.state == "disarmed"
    with pytest.raises(ValueError):
        svc.create_approval("arm")


def test_arming_with_an_open_door_is_refused(env):
    svc, _clock, _bridge, _push, _cloud, _ = env
    door(svc, True)
    with pytest.raises(ArmRefused):
        svc.arm("away")
    svc.arm("away", bypass=["dp:doorcontact_state"])
    assert svc.alarm.state == "armed_away"


def test_settings_go_through_the_esp32_first_then_the_cloud(env):
    svc, _clock, bridge, _push, cloud, _ = env
    assert svc.set_value("alarm_volume", "low")["via"] == "esp32"
    bridge.fail_set = True
    cloud_answers = []

    def issue(dev_id, values):
        cloud_answers.append(values)
        svc.on_cloud_report([{"code": k, "value": v, "t": 0, "dp_id": None} for k, v in values.items()])

    cloud.issue = issue
    assert svc.set_value("alarm_volume", "middle")["via"] == "cloud"
    assert cloud_answers == [{"alarm_volume": "middle"}]


def test_a_write_the_hub_never_confirms_is_an_error(env):
    svc, _clock, bridge, _push, cloud, _ = env
    bridge.fail_set = True
    cloud.issue = lambda dev_id, values: None   # accepted, but no report ever comes
    with pytest.raises(CommandFailed):
        svc.set_value("alarm_volume", "low")
    with pytest.raises(ValueError):
        svc.set_value("doorcontact_state", True)  # read-only


def test_cloud_auth_failure_warns_once_an_hour_while_the_esp32_keeps_working(env):
    svc, clock, _bridge, push, _cloud, _ = env
    svc.on_board_event("board1", "door_link", {"state": "connected", "rtt_ms": 30})
    svc.on_cloud_state("auth", "subscription expired")
    for _ in range(5):
        clock[0] += 60
        svc.on_board_event("board1", "door_link", {"state": "connected", "rtt_ms": 30})
        svc.tick()
    warnings = [p for p in push.sent if "cloud" in p["body"].lower() or "tuya" in p["body"].lower()]
    assert len(warnings) == 1
    svc.arm("away")
    door(svc, True)
    assert svc.alarm.state == "entry"


def test_armed_and_blind_warns_loudly(env):
    svc, clock, _bridge, push, _cloud, _ = env
    svc.arm("away")
    svc.on_cloud_state("down", "gone")
    clock[0] += 200
    svc.tick()
    assert any("can't see" in p["title"].lower() or "can't see" in p["body"].lower() for p in push.sent)


def test_a_bad_local_key_refetches_and_reconfigures_the_board(env):
    svc, clock, bridge, _push, cloud, _ = env
    cloud.local_key = "fedcba9876543210"
    svc.on_board_event("board1", "door_link", {"state": "handshake_failed", "error": "hmac"})
    configure = [c for c in bridge.calls if c[1] == "esp32_door_configure"]
    assert configure and configure[-1][2]["local_key"] == "fedcba9876543210"


def test_events_from_another_board_are_ignored(env):
    svc, _clock, _bridge, _push, _cloud, _ = env
    svc.arm("away")
    svc.on_board_event("intruder", "door_report", {"dps": {"1": True}, "t": 0, "seq": 1})
    assert svc.alarm.state == "armed_away"


def test_on_open_prompts_run(env):
    svc, _clock, _bridge, _push, _cloud, prompts = env
    svc.update_settings({"contacts": {"dp:doorcontact_state": {"on_open_prompt": "Turn on the hall light"}}})
    door(svc, True)
    assert prompts and "Turn on the hall light" in prompts[0]


def test_not_set_up(tmp_path):
    svc = DoorService(store=DoorStore(tmp_path), bridge=FakeBridge(), push=FakePush(), cloud=lambda: None,
                      approver=FakeApprover(), run=lambda fn: fn())
    with pytest.raises(NotSetUp):
        svc.arm("away")
    assert svc.state()["setup"]["hub"] is False
