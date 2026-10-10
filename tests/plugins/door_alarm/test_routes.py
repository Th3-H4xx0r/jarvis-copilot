"""/api/door/* — who may do what (phone vs Jarvis over the host-signed loopback), status codes, no key leaks."""
import json

import pytest

from plugins.door_alarm.service import DoorService
from plugins.door_alarm.store import DoorStore
from plugins.toyota.approver import Approvals
from webui.api.door_routes import handle_door_request

from .test_service import FakeApprover, FakeBridge, FakeCloud, FakePush


@pytest.fixture
def svc(tmp_path):
    clock = [5_000.0]
    bridge, cloud = FakeBridge(), FakeCloud()
    service = DoorService(store=DoorStore(tmp_path), clock=lambda: clock[0], bridge=bridge, push=FakePush(),
                          cloud=lambda: cloud, approver=FakeApprover(), approvals=Approvals(clock=lambda: clock[0]),
                          run_prompt=lambda p: None, run=lambda fn: fn(), confirm_timeout=0.2)
    bridge.service = service
    service.pick("hub1")
    service.set_proxy("board1")
    service.update_settings({"alarm": {"exit_delay": 0}})
    return service


def call(svc, method, path, body=None, host=False):
    return handle_door_request(method, path, body, host_signed=host, service=svc)


def test_state_and_setup_never_include_the_local_key(svc):
    for path in ("/state", "/setup", "/settings", "/network"):
        status, payload = call(svc, "GET", path)
        assert status == 200, path
        assert "0123456789abcdef" not in json.dumps(payload, default=str), path


def test_arm_and_refusal(svc):
    svc.on_board_event("board1", "door_report", {"dps": {"1": True}, "t": 0, "seq": 1})
    status, payload = call(svc, "POST", "/arm", {"mode": "away"}, host=True)
    assert status == 409 and payload["open_contacts"][0]["id"] == "dp:doorcontact_state"
    status, payload = call(svc, "POST", "/arm", {"mode": "away", "bypass": ["dp:doorcontact_state"]}, host=True)
    assert status == 200 and payload["alarm"]["state"] == "armed_away"


def test_only_the_phone_disarms_and_only_with_a_signature(svc):
    call(svc, "POST", "/arm", {"mode": "home"})
    status, payload = call(svc, "POST", "/disarm", {"nonce": "n", "ts": 1, "signature": "good"}, host=True)
    assert status == 403
    status, payload = call(svc, "POST", "/disarm", {"nonce": "n", "ts": 1, "signature": "bad"})
    assert status == 403 and payload["code"] == "bad_signature"
    status, payload = call(svc, "POST", "/disarm", {"nonce": "n2", "ts": 1, "signature": "good"})
    assert status == 200 and payload["alarm"]["state"] == "disarmed"


def test_jarvis_asks_and_the_phone_answers(svc):
    call(svc, "POST", "/arm", {"mode": "home"})
    assert call(svc, "POST", "/approvals", {"action": "disarm"})[0] == 403          # phone can't ask
    status, payload = call(svc, "POST", "/approvals", {"action": "disarm"}, host=True)
    assert status == 200
    approval_id = payload["approval"]["id"]
    assert call(svc, "POST", f"/approvals/{approval_id}/approve", {"ts": 1, "signature": "good"}, host=True)[0] == 403
    status, payload = call(svc, "POST", f"/approvals/{approval_id}/approve", {"ts": 1, "signature": "good"})
    assert status == 200 and payload["alarm"]["state"] == "disarmed"
    assert call(svc, "POST", f"/approvals/{approval_id}/approve", {"ts": 1, "signature": "good"})[0] == 410


def test_setup_endpoints_are_phone_only(svc):
    for path, body in (("/setup/credentials", {"access_id": "a", "secret": "b"}), ("/setup/pick", {"dev_id": "hub1"}),
                       ("/setup/proxy", {"board_id": "board1"}), ("/firmware/upgrade", {"firmware_id": 1})):
        assert call(svc, "POST", path, body, host=True)[0] == 403, path


def test_set_value_errors(svc):
    status, payload = call(svc, "POST", "/set", {"code": "alarm_volume", "value": "loud"}, host=True)
    assert status == 400
    status, payload = call(svc, "POST", "/set", {"code": "alarm_volume", "value": "low"}, host=True)
    assert status == 200 and payload["via"] == "esp32"


def test_history_and_unknown(svc):
    status, payload = call(svc, "GET", "/history?limit=5")
    assert status == 200 and isinstance(payload["events"], list)
    assert call(svc, "GET", "/nope")[0] == 404


def test_not_set_up_is_409(tmp_path):
    empty = DoorService(store=DoorStore(tmp_path), bridge=FakeBridge(), push=FakePush(), cloud=lambda: None,
                        approver=FakeApprover(), run=lambda fn: fn())
    status, payload = handle_door_request("POST", "/arm", {"mode": "away"}, host_signed=True, service=empty)
    assert status == 409 and "isn't set up" in payload["error"]
    assert handle_door_request("GET", "/state", None, service=empty)[0] == 200
