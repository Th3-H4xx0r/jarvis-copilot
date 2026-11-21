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
    assert {"lighting_state_set", "lighting_map_set", "lighting_probe", "lighting_status", "lighting_setup"} <= names


def test_setup_skill_runs_the_step_with_the_engine(monkeypatch):
    from jc_client.pc_lighting import setup
    e = FakeEngine()
    skills.set_engine(e)
    seen = {}
    monkeypatch.setattr(setup, "run_step", lambda step, sensor_driver, engine=None: seen.update(
        step=step, sensor_driver=sensor_driver, engine=engine) or {"id": step, "state": "done", "detail": ""})
    out = skills.lighting_setup(step="detect", sensor_driver=False)
    assert out["state"] == "done" and seen == {"step": "detect", "sensor_driver": False, "engine": e}


class _Led:
    pass


class _Zone:
    def __init__(self, n):
        self.leds = [_Led() for _ in range(n)]
        self.name = "ARGB"
        self.got = None

    def set_colors(self, colors, fast=False):
        if len(colors) != len(self.leds):        # openrgb-python 0.3.8 raises on a mismatch
            raise IndexError("colour count must match the zone")
        self.got = colors


def _device_0_3_8():
    zd = [SimpleNamespace(leds_min=0, leds_max=300), SimpleNamespace(leds_min=1, leds_max=1)]
    return SimpleNamespace(name="ASRock Polychrome USB", zones=[_Zone(40), _Zone(1)],
                           metadata=SimpleNamespace(location="HID: 26CE:01A2"),
                           data=SimpleNamespace(zones=zd), set_mode=lambda m: None)


def test_driver_reads_0_3_8_location_and_zone_limits():
    d = driver.Driver("127.0.0.1:6742")
    d._client = SimpleNamespace(devices=[_device_0_3_8()])
    (c,) = d.controllers()
    assert c["location"] == "HID: 26CE:01A2"
    assert c["zones"][0]["resizable"] is True and c["zones"][0]["max"] == 300
    assert c["zones"][1]["resizable"] is False


def test_driver_write_fits_each_frame_to_the_live_zone():
    d = driver.Driver("127.0.0.1:6742")
    dev = _device_0_3_8()
    d._client = SimpleNamespace(devices=[dev])
    d.write({(0, 0): [(255, 0, 0)] * 48, (0, 1): []})
    assert len(dev.zones[0].got) == 40 and len(dev.zones[1].got) == 1


def test_address_parsing():
    assert driver.parse_address("127.0.0.1:6742") == ("127.0.0.1", 6742)
    assert driver.parse_address("rtxpc") == ("rtxpc", 6742)
    assert driver.parse_address("") == ("127.0.0.1", 6742)
    assert driver.parse_address("http://10.0.0.5:7000/") == ("10.0.0.5", 7000)
