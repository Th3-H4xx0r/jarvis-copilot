"""The PC's lighting engine: renders the lighting state onto OpenRGB, mirrors nothing (the phone runs the
same maths), pauses for games when told to, and never busy-loops a static colour."""
from types import SimpleNamespace

import pytest

from jc_client.pc_lighting import engine as eng


class FakeDriver:
    def __init__(self, address="127.0.0.1:6742", fail=False):
        self.address = address
        self.writes = []
        self.resized = []
        self.fail = fail
        self.connected = 0
        self.direct = 0

    def connect(self):
        self.connected += 1
        if self.fail:
            raise ConnectionRefusedError("OpenRGB isn't answering")

    def controllers(self):
        return [{"index": 0, "name": "ASRock Polychrome USB", "location": "HID: 26CE:01A2",
                 "zones": [{"index": 0, "name": "ARGB 1", "leds": 20, "resizable": True},
                           {"index": 1, "name": "ARGB 2", "leds": 10, "resizable": True}]}]

    def set_direct(self):
        self.direct += 1

    def write(self, frames):
        if self.fail:
            raise OSError("device gone")
        self.writes.append(frames)

    def resize(self, controller, zone, leds):
        self.resized.append((controller, zone, leds))


class Clock:
    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t


def _state(effect="static", **kw):
    p = {"effect": effect, "color": "#ff0000", "speed": 5}
    st = {"on": True, "brightness": 100, "t0": 1000.0, "frozen_at": None, "still_in_games": False,
          "parts": {k: dict(p) for k in ("top", "rear", "bottom", "cooler", "strip")}}
    st.update(kw)
    return st


MAP = {"version": 1, "rev": 3, "zones": [{"controller": 0, "zone": 0, "leds": 20}],
       "segments": [{"part": "top", "index": 0, "controller": 0, "zone": 0, "start": 0, "count": 20,
                     "ring_start_deg": 0, "clockwise": True}]}


@pytest.fixture
def rig(tmp_path):
    sent, drivers, clock, game = [], [], Clock(), {"s": SimpleNamespace(on=False, reason="", anticheat=False)}

    def factory(address):
        d = FakeDriver(address)
        drivers.append(d)
        return d

    e = eng.Engine(sent.append, driver_factory=factory, clock=clock, game_state=lambda: game["s"],
                   store_path=tmp_path / "pc_lighting.json")
    return SimpleNamespace(e=e, sent=sent, drivers=drivers, clock=clock, game=game, tmp=tmp_path)


def _events(rig):
    return [f["data"] for f in rig.sent if f.get("name") == "pc_lighting_state"]


def test_connects_to_report_controllers_before_any_map_without_touching_the_lights(rig):
    rig.e.tick()                                   # fresh start: no state, no map yet (calibration needs the zones)
    assert rig.drivers and rig.drivers[0].connected == 1
    assert rig.drivers[0].direct == 0 and rig.drivers[0].writes == []
    assert _events(rig)[-1]["controllers"][0]["name"] == "ASRock Polychrome USB"


def test_a_report_lost_while_offline_is_sent_again_on_the_next_tick(tmp_path):
    sent, up = [], {"ok": False}

    def send(frame):
        if up["ok"]:
            sent.append(frame)
        return up["ok"]

    e = eng.Engine(send, driver_factory=FakeDriver, clock=Clock(),
                   game_state=lambda: SimpleNamespace(on=False, reason="", anticheat=False), store_path=tmp_path / "s.json")
    e.tick()                                  # connects and reports, but the link to the server isn't up yet
    assert sent == []
    up["ok"] = True
    e.tick()
    assert sent and sent[-1]["data"]["controllers"]


def test_a_grb_connector_gets_its_channels_swapped(rig):
    m = {"version": 1, "rev": 5, "zones": [{"controller": 0, "zone": 0, "leds": 20, "order": "grb"}],
         "segments": [{"part": "top", "index": 0, "controller": 0, "zone": 0, "start": 0, "count": 20}]}
    rig.e.set_map(m)
    rig.e.set_state(_state(), rev=1, address="127.0.0.1:6742")   # static red
    rig.e.tick()
    assert rig.drivers[0].writes[-1][(0, 0)][0] == (0, 255, 0)  # the fan shows red


def test_probes_send_raw_colours_for_the_colour_test(rig):
    m = {"version": 1, "rev": 5, "zones": [{"controller": 0, "zone": 0, "leds": 20, "order": "grb"}],
         "segments": [{"part": "top", "index": 0, "controller": 0, "zone": 0, "start": 0, "count": 20}]}
    rig.e.set_map(m)
    rig.e.set_state(_state(), rev=1, address="127.0.0.1:6742")
    rig.e.tick()
    rig.e.probe({"controller": 0, "zone": 0, "led": 0, "color": "#ff0000"})
    assert rig.drivers[0].writes[-1][(0, 0)][0] == (255, 0, 0)


def test_a_colour_change_never_waits_for_a_slow_write(tmp_path):
    import threading, time as _t

    class Slow(FakeDriver):
        def write(self, frames):
            _t.sleep(0.4)                       # his ASRock over USB takes a while per full-board frame
            super().write(frames)

    e = eng.Engine(lambda f: True, driver_factory=Slow, clock=_t.time,
                   game_state=lambda: SimpleNamespace(on=False, reason="", anticheat=False), store_path=tmp_path / "s.json")
    e.set_map(MAP)
    e.set_state(_state("rainbow"), rev=1, address="127.0.0.1:6742")
    th = threading.Thread(target=e.tick); th.start()
    _t.sleep(0.05)                              # the tick is now inside its slow write
    t0 = _t.time()
    e.set_state(_state("static"), rev=2)
    assert _t.time() - t0 < 0.1
    th.join()


def test_an_older_state_never_replaces_a_newer_one(rig):
    rig.e.set_state(_state("rainbow"), rev=5, address="127.0.0.1:6742")
    rig.e.set_state(_state("static"), rev=4)
    assert rig.e.status()["state_rev"] == 5


def test_nothing_is_written_without_a_map(rig):
    rig.e.set_state(_state(), rev=1, address="127.0.0.1:6742")
    rig.e.tick()
    assert not rig.drivers or not rig.drivers[0].writes


def test_static_writes_once_then_only_on_change(rig):
    rig.e.set_map(MAP)
    rig.e.set_state(_state(), rev=1, address="127.0.0.1:6742")
    for _ in range(5):
        rig.clock.t += 0.1
        rig.e.tick()
    assert len(rig.drivers[0].writes) == 1
    rig.e.set_state(_state(color_change=True), rev=2)
    rig.e.tick()
    assert len(rig.drivers[0].writes) == 2


def test_animated_effect_writes_at_most_thirty_times_a_second(rig):
    rig.e.set_map(MAP)
    rig.e.set_state(_state("rainbow"), rev=1, address="127.0.0.1:6742")
    for _ in range(100):          # one second in 10 ms steps
        rig.clock.t += 0.01
        rig.e.tick()
    assert 25 <= len(rig.drivers[0].writes) <= 31


def test_switching_off_stops_writes_and_reports_stopped(rig):
    rig.e.set_map(MAP)
    rig.e.set_state(_state("rainbow"), rev=1, address="127.0.0.1:6742")
    rig.e.tick()
    rig.e.set_enabled(False)
    n = len(rig.drivers[0].writes)
    for _ in range(10):
        rig.clock.t += 0.05
        rig.e.tick()
    assert len(rig.drivers[0].writes) == n
    assert _events(rig)[-1]["engine"] == "stopped"


def test_game_freezes_the_frame_when_told_to_and_resumes(rig):
    rig.e.set_map(MAP)
    rig.e.set_state(_state("rainbow", still_in_games=True), rev=1, address="127.0.0.1:6742")
    rig.e.tick()
    rig.game["s"] = SimpleNamespace(on=True, reason="in a game", anticheat=False)
    rig.clock.t += 0.1
    rig.e.tick()
    frozen = rig.drivers[0].writes[-1]
    n = len(rig.drivers[0].writes)
    for _ in range(20):
        rig.clock.t += 0.1
        rig.e.tick()
    assert len(rig.drivers[0].writes) == n            # frozen: nothing new to write
    assert rig.drivers[0].writes[-1] == frozen
    paused = [d["paused_for_game"] for d in _events(rig)]
    assert paused.count(True) == 1
    rig.game["s"] = SimpleNamespace(on=False, reason="", anticheat=False)
    rig.clock.t += 0.1
    rig.e.tick()
    rig.clock.t += 0.1
    rig.e.tick()
    assert len(rig.drivers[0].writes) > n
    assert _events(rig)[-1]["paused_for_game"] is False


def test_effects_keep_running_in_games_when_not_told_to_freeze(rig):
    rig.e.set_map(MAP)
    rig.e.set_state(_state("rainbow"), rev=1, address="127.0.0.1:6742")
    rig.game["s"] = SimpleNamespace(on=True, reason="in a game", anticheat=False)
    for _ in range(10):
        rig.clock.t += 0.05
        rig.e.tick()
    assert len(rig.drivers[0].writes) >= 9


def test_driver_failure_reports_error_and_retries_every_ten_seconds(tmp_path):
    sent, clock, made = [], Clock(), []

    def factory(address):
        d = FakeDriver(address, fail=True)
        made.append(d)
        return d

    e = eng.Engine(sent.append, driver_factory=factory, clock=clock,
                   game_state=lambda: SimpleNamespace(on=False, reason="", anticheat=False),
                   store_path=tmp_path / "s.json")
    e.set_map(MAP)
    e.set_state(_state(), rev=1, address="127.0.0.1:6742")
    e.tick()
    last = [f["data"] for f in sent if f.get("name") == "pc_lighting_state"][-1]
    assert last["engine"] == "error" and "OpenRGB" in last["error"]
    attempts = sum(d.connected for d in made)
    clock.t += 5
    e.tick()
    assert sum(d.connected for d in made) == attempts
    clock.t += 6
    e.tick()
    assert sum(d.connected for d in made) == attempts + 1


def test_reconnect_tries_at_once_after_a_failure(tmp_path):
    sent, clock, made = [], Clock(), []

    def factory(address):
        d = FakeDriver(address, fail=len(made) == 0)
        made.append(d)
        return d

    e = eng.Engine(sent.append, driver_factory=factory, clock=clock,
                   game_state=lambda: SimpleNamespace(on=False, reason="", anticheat=False),
                   store_path=tmp_path / "s.json")
    e.set_map(MAP)
    e.set_state(_state(), rev=1, address="127.0.0.1:6742")
    e.tick()
    assert e.status()["engine"] == "error"
    e.reconnect()                                   # OpenRGB was just started: don't wait 10 s
    assert e.status()["engine"] == "running" and e.status()["controllers"]


def test_probe_lights_one_led_and_pauses_until_cleared(rig):
    rig.e.set_map(MAP)
    rig.e.set_state(_state("rainbow"), rev=1, address="127.0.0.1:6742")
    rig.e.tick()
    out = rig.e.probe({"controller": 0, "zone": 0, "led": 5})
    assert out["ok"] is True
    frame = rig.drivers[0].writes[-1]
    assert frame[(0, 0)][5] == (255, 255, 255)
    assert sum(1 for c in frame[(0, 0)] if c != (0, 0, 0)) == 1
    assert frame[(0, 1)] == [(0, 0, 0)] * 10          # every other zone dark
    n = len(rig.drivers[0].writes)
    rig.clock.t += 0.5
    rig.e.tick()
    assert len(rig.drivers[0].writes) == n           # engine paused while probing
    rig.e.probe({"clear": True})
    rig.clock.t += 0.1
    rig.e.tick()
    assert len(rig.drivers[0].writes) > n


def test_probe_resize_goes_to_the_driver(rig):
    rig.e.set_map(MAP)
    rig.e.set_state(_state(), rev=1, address="127.0.0.1:6742")
    rig.e.tick()
    rig.e.probe({"controller": 0, "zone": 1, "resize": 300, "led": 299})
    assert rig.drivers[0].resized == [(0, 1, 300)]
    assert len(rig.drivers[0].writes[-1][(0, 1)]) == 300


def test_every_change_emits_one_state_event_with_revisions(rig):
    rig.e.set_map(MAP)
    rig.e.set_state(_state(), rev=7, address="127.0.0.1:6742")
    evs = _events(rig)
    assert len(evs) == 2
    assert evs[-1]["state_rev"] == 7 and evs[-1]["map_version"] == 3


def test_state_and_map_survive_a_restart(rig):
    rig.e.set_map(MAP)
    rig.e.set_state(_state(), rev=4, address="127.0.0.1:6742")
    again = eng.Engine(lambda f: None, driver_factory=FakeDriver, clock=rig.clock,
                       game_state=lambda: SimpleNamespace(on=False, reason="", anticheat=False),
                       store_path=rig.tmp / "pc_lighting.json")
    st = again.status()
    assert st["state_rev"] == 4 and st["map_version"] == 3


def test_switched_off_survives_a_restart(rig):
    rig.e.set_map(MAP)
    rig.e.set_state(_state("rainbow"), rev=1, address="127.0.0.1:6742")
    rig.e.set_enabled(False)
    again = eng.Engine(lambda f: None, driver_factory=FakeDriver, clock=rig.clock,
                       game_state=lambda: SimpleNamespace(on=False, reason="", anticheat=False),
                       store_path=rig.tmp / "pc_lighting.json")
    assert again.status()["engine"] == "stopped"


def test_set_map_resizes_resizable_zones_to_the_calibrated_size(rig):
    rig.e.set_state(_state(), rev=1, address="127.0.0.1:6742")
    rig.e.tick()
    rig.e.set_map({"version": 1, "rev": 4, "zones": [{"controller": 0, "zone": 0, "leds": 48}],
                   "segments": [{"part": "top", "index": 0, "controller": 0, "zone": 0, "start": 0, "count": 48}]})
    rig.e.tick()
    assert (0, 0, 48) in rig.drivers[0].resized


def test_a_probe_expires_after_a_minute_and_a_new_state_clears_it(rig):
    rig.e.set_map(MAP)
    rig.e.set_state(_state("rainbow"), rev=1, address="127.0.0.1:6742")
    rig.e.tick()
    rig.e.probe({"controller": 0, "zone": 0, "led": 2})
    n = len(rig.drivers[0].writes)
    rig.clock.t += 61
    rig.e.tick()
    assert len(rig.drivers[0].writes) > n          # expired: rendering again
    rig.e.probe({"controller": 0, "zone": 0, "led": 2})
    rig.e.set_state(_state("rainbow"), rev=2)
    n = len(rig.drivers[0].writes)
    rig.clock.t += 0.1
    rig.e.tick()
    assert len(rig.drivers[0].writes) > n          # a new state ends calibration's probe


def test_measure_lights_every_controller_zone(rig):
    rig.e.set_state(_state(), rev=1, address="127.0.0.1:6742")
    rig.e.tick()
    rig.e.measure(seconds=0.1)
    frames = [f for f in rig.drivers[0].writes if f]
    assert frames and set(frames[-1]) == {(0, 0), (0, 1)}
    assert any(c != (0, 0, 0) for c in frames[-1][(0, 0)])


def test_measure_returns_a_cpu_percentage(rig):
    rig.e.set_map(MAP)
    rig.e.set_state(_state(), rev=1, address="127.0.0.1:6742")
    pct = rig.e.measure(seconds=0.2)
    assert isinstance(pct, float) and pct >= 0.0
