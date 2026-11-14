"""Power integrations: switching on/off and changing settings, with Face ID where it matters."""
from __future__ import annotations

import pytest

from jarvis_power import PowerError, schedules, state, switch
from jarvis_power import approvals as approvals_mod

from .conftest import recording


@pytest.fixture()
def jobs(monkeypatch):
    """A fake cron store: id -> {integration, enabled}."""
    store = {}
    monkeypatch.setattr(schedules, "_list_jobs",
                        lambda: [{"id": k, **v} for k, v in store.items()])
    monkeypatch.setattr(schedules, "_set_enabled",
                        lambda job_id, enabled: store[job_id].update(enabled=enabled))
    return store


def test_protected_off_creates_approval_and_waits(fake_pkg, reg, calls, approvals):
    fake_pkg({"alpha": recording(protected=True)})
    state.ensure_all()
    out = switch.request_enabled("alpha", False, by="app")
    assert out["ok"] is False and out["pending"]["command"] == "off:alpha"
    assert approvals == [out["pending"]]
    assert state.is_on("alpha") is True
    with pytest.raises(Exception):
        approvals_mod.approve(out["pending"]["id"], {"ts": 1, "signature": "bad"})
    assert state.is_on("alpha") is True
    approvals_mod.approve(out["pending"]["id"], {"ts": 1, "signature": "good"})
    state.reset_cache()
    assert state.is_on("alpha") is False
    with pytest.raises(Exception):
        approvals_mod.approve(out["pending"]["id"], {"ts": 1, "signature": "good"})


def test_protected_on_needs_no_approval(fake_pkg, reg, calls, approvals):
    fake_pkg({"alpha": recording(protected=True)})
    state.ensure_all()
    state.write_enabled("alpha", False, by="app")
    out = switch.request_enabled("alpha", True, by="jarvis")
    assert out["ok"] is True and out["row"]["enabled"] is True


@pytest.mark.parametrize("by", ["app", "web", "mac", "jarvis"])
def test_can_switch_off_reason_blocks(fake_pkg, reg, calls, approvals, by):
    fake_pkg({"alpha": recording(protected=True, extra='''
    def can_switch_off(self):
        return "Disarm the alarm first"
''')})
    state.ensure_all()
    with pytest.raises(PowerError, match="Disarm the alarm first"):
        switch.request_enabled("alpha", False, by=by)
    assert state.is_on("alpha") is True
    assert approvals == []


def test_jarvis_setting_rules(fake_pkg, reg, calls, approvals):
    fake_pkg({"alpha": recording()})
    state.ensure_all()
    with pytest.raises(PowerError, match="can only be changed in the app"):
        switch.request_settings("alpha", {"locked": True}, by="jarvis")
    pending = switch.request_settings("alpha", {"careful": True}, by="jarvis")
    assert pending["ok"] is False and pending["pending"]["command"].startswith("settings:alpha:")
    assert state.stored_settings("alpha").get("careful") is None
    done = switch.request_settings("alpha", {"free": True}, by="jarvis")
    assert done["ok"] is True and state.stored_settings("alpha")["free"] is True
    approvals_mod.approve(pending["pending"]["id"], {"ts": 1, "signature": "good"})
    assert state.stored_settings("alpha")["careful"] is True
    # The app is the person: every rule is theirs to change directly.
    out = switch.request_settings("alpha", {"locked": True, "careful": False}, by="app")
    assert out["ok"] is True
    assert state.stored_settings("alpha") == {"free": True, "careful": False, "locked": True}


def test_settings_are_validated(fake_pkg, reg, calls, approvals):
    fake_pkg({"alpha": recording()})
    state.ensure_all()
    with pytest.raises(PowerError, match="on or off"):
        switch.request_settings("alpha", {"free": "yes"}, by="app")
    with pytest.raises(PowerError, match="no setting"):
        switch.request_settings("alpha", {"nope": 1}, by="app")


def test_schedules_paused_and_restored(fake_pkg, reg, calls, approvals, jobs):
    fake_pkg({"alpha": recording()})
    state.ensure_all()
    jobs["a1"] = {"integration": "alpha", "enabled": True}
    jobs["a2"] = {"integration": "alpha", "enabled": False}
    jobs["b1"] = {"integration": "other", "enabled": True}
    switch.request_enabled("alpha", False, by="app")
    assert [jobs[k]["enabled"] for k in ("a1", "a2", "b1")] == [False, False, True]
    assert state.doc("alpha")["paused_jobs"] == ["a1"]
    switch.request_enabled("alpha", True, by="app")
    assert [jobs[k]["enabled"] for k in ("a1", "a2", "b1")] == [True, False, True]
    assert state.doc("alpha")["paused_jobs"] == []


def test_switching_to_same_state_is_a_no_op(fake_pkg, reg, calls, approvals, jobs):
    fake_pkg({"alpha": recording()})
    state.ensure_all()
    before = state.doc("alpha")["changed_at"]
    out = switch.request_enabled("alpha", True, by="app")
    assert out["ok"] is True
    assert state.doc("alpha")["changed_at"] == before
