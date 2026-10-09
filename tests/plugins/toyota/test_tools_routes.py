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


def test_command_tool_asks_before_unlocking_without_touching_home_assistant(use_ha):
    ha = use_ha(signed_in_ha())
    out = json.loads(tools._handle_command({"command": "unlock"}))
    assert out["needs_confirmation"] is True and ha.calls == []


def test_command_tool_after_a_yes(use_ha):
    ha = use_ha(signed_in_ha())
    out = json.loads(tools._handle_command({"command": "start", "confirmed": True}))
    assert out["result"] == "Started"
    assert ("/api/services/toyota_na/engine_start", {"vehicle": DEVICE}) in ha.posts()


def test_tools_say_sign_in_first_when_signed_out(use_ha):
    use_ha(FakeHA())
    assert "Sign in with Toyota" in json.loads(tools._handle_status({}))["error"]
    assert "Sign in with Toyota" in json.loads(tools._handle_command({"command": "lock"}))["error"]


def test_status_and_climate_tools(use_ha):
    ha = use_ha(signed_in_ha())
    assert json.loads(tools._handle_status({}))["range_mi"] == 353
    assert not ha.posts("/api/services/toyota_na/refresh")
    json.loads(tools._handle_status({"refresh": True}))
    assert ha.posts("/api/services/toyota_na/refresh")
    assert json.loads(tools._handle_climate({"action": "get"}))["climate"]["temp"] == 68


def test_routes_state_signed_out_and_signed_in():
    status, payload = handle_car_request("GET", "/state", None, ha=FakeHA())
    assert status == 200 and payload == {"account": {"state": "signed_out"}, "car": None}
    status, payload = handle_car_request("GET", "/state", None, ha=signed_in_ha())
    assert status == 200 and payload["car"]["odometer_mi"] == 63


def test_routes_gate_unlock_and_refuse_commands_while_signed_out():
    ha = signed_in_ha()
    status, payload = handle_car_request("POST", "/command", {"command": "unlock"}, ha=ha)
    assert status == 200 and payload["needs_confirmation"] is True and ha.calls == []
    status, payload = handle_car_request("POST", "/command", {"command": "unlock", "confirmed": True}, ha=ha)
    assert status == 200 and payload["result"] == "Unlocked"
    status, payload = handle_car_request("POST", "/command", {"command": "lock"}, ha=FakeHA())
    assert status == 409 and "Sign in" in payload["error"]


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


def test_routes_map_home_assistant_failures():
    down = signed_in_ha()
    down.reply("POST", "/api/services/toyota_na/door_lock", HAError("Remote Connect isn't active", 500))
    assert handle_car_request("POST", "/command", {"command": "lock"}, ha=down) == \
        (502, {"ok": False, "error": "Remote Connect isn't active"})
    gone = signed_in_ha()
    gone.reply("POST", "/api/services/toyota_na/door_lock", HAUnreachable("Home Assistant isn't reachable"))
    assert handle_car_request("POST", "/command", {"command": "lock"}, ha=gone)[0] == 503
    assert handle_car_request("GET", "/nope", None, ha=FakeHA())[0] == 404
    assert handle_car_request("PUT", "/state", None, ha=FakeHA())[0] == 405
    assert handle_car_request("POST", "/climate", {"temp": 200}, ha=signed_in_ha())[0] == 400
