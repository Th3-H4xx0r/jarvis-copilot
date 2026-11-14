"""Fixes from the whole-branch code and security reviews (2026-11-14)."""
from __future__ import annotations

import threading

import pytest

from jarvis_power import PowerError, approvals as approvals_mod, discovery, gate, state, switch
from jarvis_power.base import Setting

from .conftest import recording, simple


# ── user data that merely uses the word "power" is not a Power space ─────────
def test_user_power_document_is_not_a_power_space(fake_pkg, reg):
    meter = reg.space("energy", name="Energy")
    meter.put("power", {"watts": 342})
    fake_pkg({"alpha": simple()})
    state.ensure_all()
    assert not state.is_power_space("energy")
    from jarvis_registry import integrations
    assert "energy" in [r["id"] for r in integrations.overview()]
    from tools import registry_tools
    import json
    assert json.loads(registry_tools._h_put({"space": "energy", "key": "power",
                                             "body": {"watts": 1}})).get("ok") is True


def test_legacy_power_doc_is_migrated(fake_pkg, reg):
    fake_pkg({"alpha": simple()})
    reg.space("alpha", name="Alpha").put("power", {"enabled": False, "settings": {}, "changed_at": 1.0,
                                                   "changed_by": "seed", "paused_jobs": [], "error": None})
    state.ensure_all()
    assert state.is_on("alpha") is False
    assert reg.open("alpha").get("power") is None


# ── a crashed home lookup (SystemExit) never escapes the gates ───────────────
def test_snapshot_survives_system_exit(fake_pkg, reg, monkeypatch):
    fake_pkg({"alpha": simple()})
    def boom(_id):
        raise SystemExit(1)
    monkeypatch.setattr(state, "doc", boom)
    state.reset_cache()
    assert state.is_on("alpha") is True


# ── concurrent switches never lose paused schedules ──────────────────────────
def test_concurrent_offs_keep_paused_jobs(fake_pkg, reg, monkeypatch):
    from jarvis_power import schedules
    store = {"j1": {"integration": "alpha", "enabled": True}}
    gate_ev = threading.Event()

    def slow_list():
        gate_ev.wait(0.2)
        return [{"id": k, **v} for k, v in store.items()]

    monkeypatch.setattr(schedules, "_list_jobs", slow_list)
    monkeypatch.setattr(schedules, "_set_enabled", lambda j, e: store[j].update(enabled=e))
    fake_pkg({"alpha": recording()})
    state.ensure_all()
    threads = [threading.Thread(target=switch.request_enabled, args=("alpha", False, "app")) for _ in range(2)]
    for t in threads:
        t.start()
    gate_ev.set()
    for t in threads:
        t.join()
    assert state.doc("alpha")["paused_jobs"] == ["j1"]
    switch.request_enabled("alpha", True, "app")
    assert store["j1"]["enabled"] is True


# ── approvals ────────────────────────────────────────────────────────────────
def test_approve_rechecks_can_switch_off(fake_pkg, reg, approvals):
    fake_pkg({"alpha": recording(protected=True, extra='''
    armed = False

    def can_switch_off(self):
        return "Disarm the alarm first" if type(self).armed else None
''')})
    state.ensure_all()
    out = switch.request_enabled("alpha", False, by="web")
    type(discovery.get("alpha")).armed = True
    with pytest.raises(PowerError, match="Disarm the alarm first"):
        approvals_mod.approve(out["pending"]["id"], {"ts": 1, "signature": "good"})
    assert state.is_on("alpha") is True


def test_settings_approval_names_the_change(fake_pkg, reg, approvals):
    fake_pkg({"alpha": recording()})
    state.ensure_all()
    a = switch.request_settings("alpha", {"careful": True}, by="jarvis")["pending"]
    b = switch.request_settings("alpha", {"careful": False}, by="jarvis")["pending"]
    assert a["command"].startswith("settings:alpha:") and a["command"] != b["command"]
    assert "Careful" in a["detail"] and "on" in a["detail"]


def test_rows_report_pending_from_the_server(fake_pkg, reg, approvals):
    from jarvis_power import api
    fake_pkg({"alpha": recording(protected=True)})
    state.ensure_all()
    assert api.row("alpha")["pending"] is False
    out = switch.request_enabled("alpha", False, by="app")
    assert api.row("alpha")["pending"] is True
    approvals_mod.deny(out["pending"]["id"])
    assert api.row("alpha")["pending"] is False


# ── Jarvis can never set secrets or rules marked never ───────────────────────
def test_jarvis_cannot_set_secrets(fake_pkg, reg, approvals):
    fake_pkg({"alpha": simple(extra='''
    from jarvis_power import Setting as _S
    settings = (_S("token", "Token", "secret"),)
''')})
    state.ensure_all()
    with pytest.raises(PowerError, match="only be changed in the app"):
        switch.request_settings("alpha", {"token": "x"}, by="jarvis")
    assert switch.request_settings("alpha", {"token": "x"}, by="app")["ok"] is True


def test_car_and_photon_endpoints_are_app_only():
    discovery.reset()
    for pid in ("car", "photon"):
        p = discovery.get(pid)
        assert all(s.jarvis == "never" for s in p.settings), pid


def test_numbers_reject_nan():
    s = Setting("n", "N", "number", default=1)
    with pytest.raises(PowerError):
        s.coerce(float("nan"))
    with pytest.raises(PowerError):
        s.coerce(float("inf"))


# ── the route gate normalises paths ──────────────────────────────────────────
def test_route_gate_collapses_slashes(fake_pkg, reg, monkeypatch):
    monkeypatch.setattr(discovery, "_toolset_exists", lambda name: True)
    fake_pkg({"alpha": simple(extra='route_prefixes = ("/api/integrations/x/health/run",)')})
    state.ensure_all()
    state.write_enabled("alpha", False, by="app")
    assert gate.route_block("/api/integrations//x/health/run")["power_off"] == "alpha"
    assert gate.route_block("/api/integrations/x/health//run")["power_off"] == "alpha"
    assert gate.route_block("/api/integrations/x/health/run/")["power_off"] == "alpha"


# ── registry.db is protected from file tools and the terminal ────────────────
def test_registry_db_is_protected_state():
    from agent.file_safety import PROTECTED_STATE_PATHS
    assert "registry.db" in PROTECTED_STATE_PATHS
    assert "power_sessions.db" in PROTECTED_STATE_PATHS
