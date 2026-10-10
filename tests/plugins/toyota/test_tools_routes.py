"""The toyota_* tools and /api/car routes on top of the car and account."""
import json

import pytest

import plugins.toyota.tools as tools
from plugins.toyota.commands import SERVICES
from plugins.toyota.ha import HAError, HAUnreachable
from toolsets import TOOLSETS
from webui.api.car_routes import handle_car_request

from .fake_ha import DEVICE, FakeHA, signed_in_ha


@pytest.fixture
def use_ha(monkeypatch):
    def use(ha):
        monkeypatch.setattr(tools, "HAClient", lambda: ha)
        return ha
    return use


def test_the_toolset_lists_exactly_the_plugin_tools():
    assert TOOLSETS["toyota"]["tools"] == [name for name, *_ in tools.TOOLS]
    assert tools.COMMAND_SCHEMA["parameters"]["properties"]["command"]["enum"] == list(SERVICES)


@pytest.mark.parametrize("name", ["unlock", "lock", "horn", "start", "hazards_off"])
def test_command_tool_sends_face_id_approvals_and_runs_nothing(use_ha, monkeypatch, name):
    ha = use_ha(signed_in_ha())
    asked = []
    monkeypatch.setattr(tools, "_request_approval", lambda command: asked.append(command) or {"ok": True})
    out = json.loads(tools._handle_command({"command": name}))
    assert out["pending_approval"] is True and "Face ID" in out["message"]
    assert asked == [name] and ha.calls == []


def test_command_tool_reports_an_approval_that_could_not_be_sent(use_ha, monkeypatch):
    use_ha(signed_in_ha())
    monkeypatch.setattr(tools, "_request_approval", lambda command: {"_error": "webui down"})
    assert json.loads(tools._handle_command({"command": "unlock"}))["error"] == "webui down"


def test_command_tool_stops_the_car_at_once(use_ha, monkeypatch):
    ha = use_ha(signed_in_ha())
    monkeypatch.setattr(tools, "_request_approval", lambda command: pytest.fail("stop needs no approval"))
    assert json.loads(tools._handle_command({"command": "stop"}))["result"] == "Stopped"
    assert ha.services() == [("engine_stop", {"vehicle": DEVICE})]


def test_tools_say_sign_in_first_when_signed_out(use_ha):
    use_ha(FakeHA())
    assert "Sign in with Toyota" in json.loads(tools._handle_status({}))["error"]
    assert "Sign in with Toyota" in json.loads(tools._handle_command({"command": "stop"}))["error"]


def test_status_and_climate_tools(use_ha):
    ha = use_ha(signed_in_ha())
    assert json.loads(tools._handle_status({}))["range_mi"] == 353
    assert ha.services() == []
    assert json.loads(tools._handle_climate({"action": "get"}))["climate"]["temp"] == 68


def test_routes_state_signed_out_and_signed_in():
    status, payload = handle_car_request("GET", "/state", None, ha=FakeHA())
    assert status == 200 and payload == {"account": {"state": "signed_out"}, "car": None}
    status, payload = handle_car_request("GET", "/state", None, ha=signed_in_ha())
    assert status == 200 and payload["car"]["odometer_mi"] == 63


@pytest.fixture
def phone_keys(tmp_path):
    from plugins.toyota.approver import Approvals, Approver

    from .test_approver import Phone

    import time

    phone = Phone()
    keys = Approver(tmp_path / "approver.json")
    phone.register_on(keys, int(time.time()))
    return phone, keys, Approvals()


def signed(phone, command, nonce=None):
    import time
    import uuid

    nonce = nonce or uuid.uuid4().hex
    ts = int(time.time())
    return {"command": command, "nonce": nonce, "ts": ts, "signature": phone.sign(command, nonce, ts)}


def test_routes_run_a_command_only_with_a_face_id_signature(phone_keys):
    phone, keys, waiting = phone_keys
    ha = signed_in_ha()
    status, payload = handle_car_request("POST", "/command", {"command": "unlock"}, ha=ha, approver=keys)
    assert status == 400 and payload["code"] == "bad_request" and ha.services() == []
    proof = signed(phone, "unlock")
    status, payload = handle_car_request("POST", "/command", proof, ha=ha, approver=keys)
    assert status == 200 and payload["result"] == "Unlocked"
    status, payload = handle_car_request("POST", "/command", proof, ha=ha, approver=keys)
    assert status == 403 and payload["code"] == "replayed"
    status, payload = handle_car_request("POST", "/command", {**signed(phone, "lock"), "command": "unlock"},
                                         ha=ha, approver=keys)
    assert status == 403 and payload["code"] == "bad_signature"
    assert handle_car_request("POST", "/command", {"command": "stop"}, ha=ha, approver=keys)[0] == 200
    status, payload = handle_car_request("POST", "/command", signed(phone, "lock"), ha=FakeHA(), approver=keys)
    assert status == 409 and "Sign in" in payload["error"]


def test_routes_register_the_phone_key_once(tmp_path):
    from plugins.toyota.approver import Approver

    from .test_approver import Phone

    import time

    keys = Approver(tmp_path / "approver.json")
    first, second = Phone(), Phone()
    now = int(time.time())
    proof = {"public_key": first.public, "ts": now, "signature": first.sign_register(first.public, now)}
    assert handle_car_request("GET", "/approver", None, ha=FakeHA(), approver=keys)[1] == {"registered": False, "public_key": None}
    status, payload = handle_car_request("POST", "/approver", proof, ha=FakeHA(), approver=keys, host_signed=True)
    assert status == 403 and payload["code"] == "forbidden", "the agent's loopback can't register a key"
    assert handle_car_request("POST", "/approver", {"public_key": first.public}, ha=FakeHA(), approver=keys)[0] == 400
    assert handle_car_request("POST", "/approver", proof, ha=FakeHA(), approver=keys)[0] == 200
    other = {"public_key": second.public, "ts": now, "signature": second.sign_register(second.public, now)}
    status, payload = handle_car_request("POST", "/approver", other, ha=FakeHA(), approver=keys)
    assert status == 403 and keys.registered() == first.public


def test_jarvis_approvals_wait_for_face_id_then_run(phone_keys):
    phone, keys, waiting = phone_keys
    ha, told = signed_in_ha(), []
    kw = dict(ha=ha, approver=keys, approvals=waiting, notify=told.append)
    assert handle_car_request("POST", "/approvals", {"command": "unlock"}, **kw)[0] == 403, "only Jarvis asks"
    status, payload = handle_car_request("POST", "/approvals", {"command": "unlock"}, host_signed=True, **kw)
    approval = payload["approval"]
    assert status == 200 and told == [approval] and ha.services() == []
    assert handle_car_request("GET", "/approvals", None, **kw)[1]["approvals"][0]["id"] == approval["id"]
    forged = signed(phone, "unlock")      # a signature for a different nonce than the approval's id
    status, _ = handle_car_request("POST", f"/approvals/{approval['id']}/approve", forged, **kw)
    assert status == 403 and ha.services() == []
    proof = signed(phone, "unlock", nonce=approval["id"])
    status, _ = handle_car_request("POST", f"/approvals/{approval['id']}/approve", proof, host_signed=True, **kw)
    assert status == 403, "the agent can't answer its own approval"
    status, payload = handle_car_request("POST", f"/approvals/{approval['id']}/approve", proof, **kw)
    assert status == 200 and payload["result"] == "Unlocked"
    assert handle_car_request("POST", f"/approvals/{approval['id']}/approve", proof, **kw)[0] == 410
    assert handle_car_request("GET", "/approvals", None, **kw)[1]["approvals"] == []


def test_jarvis_approvals_can_be_denied_and_stop_needs_none(phone_keys):
    phone, keys, waiting = phone_keys
    kw = dict(ha=signed_in_ha(), approver=keys, approvals=waiting, notify=lambda item: None)
    approval = handle_car_request("POST", "/approvals", {"command": "horn"}, host_signed=True, **kw)[1]["approval"]
    assert handle_car_request("POST", f"/approvals/{approval['id']}/deny", {}, host_signed=True, **kw)[0] == 403
    assert handle_car_request("POST", f"/approvals/{approval['id']}/deny", {}, **kw) == (200, {"ok": True})
    proof = signed(phone, "horn", nonce=approval["id"])
    status, payload = handle_car_request("POST", f"/approvals/{approval['id']}/approve", proof, **kw)
    assert status == 410 and payload["code"] == "gone"
    assert handle_car_request("POST", "/approvals", {"command": "stop"}, host_signed=True, **kw)[0] == 400
    assert handle_car_request("POST", "/approvals", {"command": "unlock"}, ha=FakeHA(), approver=keys,
                              approvals=waiting, notify=lambda item: None, host_signed=True)[0] == 409


def test_routes_sign_in_steps_and_errors():
    ha = FakeHA()
    ha.reply("POST", "/api/config/config_entries/flow", {"type": "form", "step_id": "user", "flow_id": "f1"})
    ha.reply("POST", "/api/config/config_entries/flow/f1",
             {"type": "form", "step_id": "otp", "flow_id": "f1"},
             {"type": "form", "step_id": "otp", "flow_id": "f1", "errors": {"base": "otp_not_logged_in"}})
    assert handle_car_request("POST", "/signin", {"email": "p@x.com", "password": "pw"}, ha=ha) == \
        (200, {"ok": True, "step": "code", "flow_id": "f1"})
    status, payload = handle_car_request("POST", "/signin/code", {"flow_id": "f1", "code": "0"}, ha=ha)
    assert status == 400 and "code" in payload["error"]


def test_routes_map_home_assistant_failures(phone_keys):
    phone, keys, _ = phone_keys
    down = signed_in_ha()
    down.reply("WS", "call_service", HAError("Remote Connect isn't active"))
    assert handle_car_request("POST", "/command", signed(phone, "lock"), ha=down, approver=keys) == \
        (502, {"ok": False, "error": "Remote Connect isn't active"})
    gone = signed_in_ha()
    gone.reply("WS", "call_service", HAUnreachable("Home Assistant isn't reachable"))
    assert handle_car_request("POST", "/command", signed(phone, "lock"), ha=gone, approver=keys)[0] == 503
    offline = FakeHA()
    offline.reply("GET", "/api/config/config_entries/flow_handlers", HAUnreachable("Home Assistant isn't reachable"))
    assert handle_car_request("POST", "/command", {"command": "stop"}, ha=offline)[0] == 503, \
        "Home Assistant down is 503, not 'sign in'"
    assert handle_car_request("GET", "/nope", None, ha=FakeHA())[0] == 404
    assert handle_car_request("PUT", "/state", None, ha=FakeHA())[0] == 405
    assert handle_car_request("POST", "/climate", {"temp": 200}, ha=signed_in_ha())[0] == 400


def test_a_command_toyota_has_not_confirmed_is_pending_not_unreachable(phone_keys):
    from plugins.toyota.ha import HATimeout

    phone, keys, _ = phone_keys
    slow = signed_in_ha()
    slow.reply("WS", "call_service", HATimeout("Home Assistant didn't answer within 75 s"))
    status, payload = handle_car_request("POST", "/command", signed(phone, "start"), ha=slow, approver=keys)
    assert status == 504 and "check the car" in payload["error"]
