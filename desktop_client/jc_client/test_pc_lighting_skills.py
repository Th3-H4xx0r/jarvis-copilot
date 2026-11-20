"""The lighting skills the server calls (server-only) and the OpenRGB address parsing."""
from types import SimpleNamespace

from jc_client.pc_lighting import driver, skills


class FakeEngine:
    def __init__(self):
        self.calls = []

    def set_state(self, state, rev=None, address=None, enabled=True):
        self.calls.append(("state", state, rev, address, enabled))
        return {"engine": "running"}

    def set_map(self, m):
        self.calls.append(("map", m))
        return {"engine": "running"}

    def probe(self, args):
        self.calls.append(("probe", args))
        return {"ok": True}

    def status(self):
        return {"engine": "running"}


def test_state_set_passes_everything_to_the_engine():
    e = FakeEngine()
    skills.set_engine(e)
    out = skills.lighting_state_set(state={"on": True}, rev=3, address="127.0.0.1:6742", enabled=False)
    assert e.calls == [("state", {"on": True}, 3, "127.0.0.1:6742", False)]
    assert out["engine"] == "running"


def test_probe_drops_unset_arguments():
    e = FakeEngine()
    skills.set_engine(e)
    skills.lighting_probe(controller=0, zone=1, led=4)
    assert e.calls == [("probe", {"controller": 0, "zone": 1, "led": 4})]


def test_skills_without_an_engine_say_so():
    skills.set_engine(None)
    out = skills.lighting_status()
    assert out["ok"] is False and "lighting" in out["error"].lower()


def test_register_adds_the_four_server_only_skills():
    from jc_client import skills as registry
    skills.register()
    names = {s["name"] for s in registry.list_skills()} if hasattr(registry, "list_skills") else set(registry._REGISTRY)
    assert {"lighting_state_set", "lighting_map_set", "lighting_probe", "lighting_status"} <= names


def test_address_parsing():
    assert driver.parse_address("127.0.0.1:6742") == ("127.0.0.1", 6742)
    assert driver.parse_address("rtxpc") == ("rtxpc", 6742)
    assert driver.parse_address("") == ("127.0.0.1", 6742)
    assert driver.parse_address("http://10.0.0.5:7000/") == ("10.0.0.5", 7000)
