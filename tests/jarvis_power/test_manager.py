"""Power integrations: the per-process manager that starts and stops background work."""
from __future__ import annotations

from jarvis_power import state
from jarvis_power.manager import PowerManager

from .conftest import recording


def test_boot_starts_only_enabled_for_process(fake_pkg, reg, calls):
    fake_pkg({
        "alpha": recording(id="alpha"),
        "beta": recording(id="beta", name="Beta", processes=("gateway",)),
        "gamma": recording(id="gamma", name="Gamma"),
    })
    state.ensure_all()
    state.write_enabled("gamma", False, by="app")
    PowerManager("webui").reconcile()
    assert calls == [("alpha", "start", "webui")]


def test_manager_is_idempotent_under_flapping(fake_pkg, reg, calls):
    fake_pkg({"alpha": recording()})
    state.ensure_all()
    m = PowerManager("webui")
    m.reconcile()
    for enabled in (False, True, False, True, False):
        state.write_enabled("alpha", enabled, by="app")
        m.reconcile()
        m.reconcile()                    # a second pass with nothing new does nothing
    whats = [what for _id, what, _p in calls]
    assert whats == ["start", "stop", "start", "stop", "start", "stop"]


def test_start_failure_is_recorded_and_isolated(fake_pkg, reg, calls):
    from tests.jarvis_power import recorder

    fake_pkg({"alpha": recording(id="alpha"), "beta": recording(id="beta", name="Beta")})
    state.ensure_all()
    recorder.FAIL.add(("alpha", "start"))
    m = PowerManager("webui")
    m.reconcile()
    assert ("beta", "start", "webui") in calls
    assert "boom" in (state.doc("alpha")["error"] or "")
    assert state.doc("beta")["error"] is None
    recorder.FAIL.clear()
    m.reconcile()                        # a failed start is retried
    assert state.doc("alpha")["error"] is None


def test_poll_publishes_on_change(fake_pkg, reg, calls):
    fake_pkg({"alpha": recording()})
    state.ensure_all()
    seen = []
    m = PowerManager("webui", on_change=lambda v: seen.append(v))
    m.tick()
    m.tick()
    assert len(seen) == 1                # first sight of the state
    state.write_enabled("alpha", False, by="app")
    m.tick()
    assert len(seen) == 2 and ("alpha", "stop", "webui") in calls
