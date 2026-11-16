"""PC Stats store: rollups, history, energy, retention, sessions, dashboards."""
import pytest

from api.pc_stats_catalog import default_dashboards, validate_dashboard
from api.pc_stats_store import Conflict, PcStatsStore

DAY = 86400.0


class Clock:
    def __init__(self, t=1_800_000_000.0):
        self.t = t

    def __call__(self):
        return self.t


@pytest.fixture
def rig(tmp_path):
    clock = Clock()
    return PcStatsStore(tmp_path, clock=clock), clock


def _samples(t0, n, step=10, **r):
    return [{"t": t0 + i * step, "r": dict(r), "game": None} for i in range(n)]


def test_ingest_rolls_up_and_history_picks_finest_table(rig):
    s, clock = rig
    t0 = clock.t - 600
    s.ingest("pc", _samples(t0, 60, step=10, **{"gpu.temp": 60.0}), [])
    s.ingest("pc", [{"t": t0 + 5, "r": {"gpu.temp": 80.0}}], [])
    pts = s.history("pc", "gpu.temp", t0, clock.t, points=1000)
    assert len(pts) >= 59                      # 10-second table for a recent range
    first = pts[0]
    assert first[2] == 60.0 and first[3] == 80.0 and first[1] == 70.0
    # An old range comes from the hourly table.
    s.ingest("pc", [{"t": clock.t - 100 * DAY, "r": {"gpu.temp": 50.0}}], [])
    old = s.history("pc", "gpu.temp", clock.t - 101 * DAY, clock.t - 99 * DAY)
    assert old and old[0][1] == 50.0


def test_unknown_keys_dropped_dynamic_fans_kept(rig):
    s, clock = rig
    s.ingest("pc", [{"t": clock.t, "r": {"bogus.key": 1, "fan.cpu_fan": 1200, "temp.dimm_1": 40}}], [])
    latest = s.latest("pc")
    assert latest["r"] == {"fan.cpu_fan": 1200.0, "temp.dimm_1": 40.0}


def test_latest_marks_estimated(rig):
    s, clock = rig
    s.ingest("pc", [{"t": clock.t, "r": {"power.total": 400}, "game": "cod.exe"}], ["power.total"])
    assert s.latest("pc") == {"t": clock.t, "r": {"power.total": 400.0}, "game": "cod.exe",
                              "estimated": ["power.total"]}


def test_energy_integrates_power_total_by_day(rig):
    s, clock = rig
    import datetime as dt
    noon = dt.datetime.fromtimestamp(clock.t).replace(hour=12, minute=0, second=0, microsecond=0).timestamp()
    clock.t = noon + 3 * 3600
    s.ingest("pc", _samples(noon, 720, step=10, **{"power.total": 500.0}), [])   # 2 h at 500 W
    buckets = s.energy("pc", "day", price=0.2)
    today = buckets[-1]
    assert today["kwh"] == pytest.approx(1.0, rel=0.02)
    assert today["cost"] == pytest.approx(0.2, rel=0.02)


def test_retention_prunes_10s_after_7_days(rig):
    s, clock = rig
    s.ingest("pc", [{"t": clock.t - 8 * DAY, "r": {"cpu.load": 10}}], [])
    s.prune()
    assert s.history("pc", "cpu.load", clock.t - 8 * DAY - 10, clock.t - 8 * DAY + 10) != []   # 1-minute table still has it
    import sqlite3
    with sqlite3.connect(str(s._db)) as db:
        assert db.execute("SELECT COUNT(*) FROM s10").fetchone()[0] == 0
        assert db.execute("SELECT COUNT(*) FROM m1").fetchone()[0] == 1


def test_sessions_upsert_newest_first(rig):
    s, _ = rig
    s.add_sessions("pc", [{"id": "a", "start": 100, "exe": "cod.exe"}, {"id": "b", "start": 200, "exe": "x"}])
    s.add_sessions("pc", [{"id": "a", "start": 100, "exe": "cod.exe", "fps_avg": 120}])
    out = s.sessions("pc")
    assert [x["id"] for x in out] == ["b", "a"] and out[1]["fps_avg"] == 120


def test_defaults_seeded_and_valid(rig):
    s, _ = rig
    names = [d["name"] for d in s.dashboards()]
    assert names == ["Overview", "Gaming", "Power"]
    for d in default_dashboards():
        assert validate_dashboard(d) == []


def test_validate_rejects_overlap_unknown_kind_offgrid_badcolor():
    base = {"id": "x", "name": "X", "auto": None}
    w = lambda **k: {"id": k.pop("id", "a"), "kind": "number", "x": 0, "y": 0, "w": 2, "h": 2, "readings": ["cpu.load"], "style": {}, **k}
    assert validate_dashboard({**base, "widgets": [w(), w(id="b", x=1)]})                 # overlap
    assert validate_dashboard({**base, "widgets": [w(kind="pie")]})                      # unknown kind
    assert validate_dashboard({**base, "widgets": [w(x=11)]})                            # off the grid
    assert validate_dashboard({**base, "widgets": [w(style={"color": "blue"})]})         # bad colour
    assert validate_dashboard({**base, "widgets": [w(readings=["nope"])]})               # unknown reading
    assert validate_dashboard({**base, "widgets": [w(), w(id="b", x=2)]}) == []


def test_put_stale_rev_conflicts(rig):
    s, _ = rig
    d = s.dashboard("overview")
    saved = s.put_dashboard({**d, "name": "Main"}, rev=d["rev"])
    assert saved["rev"] == d["rev"] + 1
    with pytest.raises(Conflict) as e:
        s.put_dashboard({**d, "name": "Stale"}, rev=d["rev"])
    assert e.value.current["name"] == "Main"
    with pytest.raises(ValueError):
        s.put_dashboard({**d, "widgets": [{"id": "z", "kind": "pie"}]}, rev=None)
    with pytest.raises(Conflict):                      # no rev over an existing one
        s.put_dashboard({**d, "name": "Clobber"}, rev=None)
    assert s.dashboard("overview")["name"] == "Main"


def test_only_one_gaming_dashboard(rig):
    s, _ = rig
    o = s.dashboard("overview")
    s.put_dashboard({**o, "auto": "game"}, rev=o["rev"])
    assert [d["id"] for d in s.dashboards() if d.get("auto") == "game"] == ["overview"]


def test_new_defaults_replace_only_unedited(rig, monkeypatch):
    s, _ = rig
    s.dashboards()
    o = s.dashboard("overview")
    s.put_dashboard({**o, "name": "Mine"}, rev=o["rev"])          # edited: keep it
    import api.pc_stats_store as store_mod
    import sqlite3
    with sqlite3.connect(str(s._db)) as db:
        db.execute("UPDATE meta SET v='1' WHERE k='defaults'")
    fresh = [dict(d, name=d["name"] + " v3") for d in store_mod.default_dashboards()]
    monkeypatch.setattr(store_mod, "default_dashboards", lambda: fresh)
    monkeypatch.setattr(store_mod, "DEFAULTS_VERSION", 3)
    names = {d["id"]: d["name"] for d in s.dashboards()}
    assert names["overview"] == "Mine" and names["gaming"] == "Gaming v3"


def test_defaults_are_valid_and_wildcards_known():
    from api.pc_stats_catalog import default_dashboards, reading_info, validate_dashboard
    for d in default_dashboards():
        assert validate_dashboard(d) == []
    assert reading_info("temp.*")["unit"] == "°C" and reading_info("fan.*")["unit"] == "rpm"
    assert reading_info("fan.fan_1")["label"] == "Fan 1"
    assert reading_info("gpu.*") is None
