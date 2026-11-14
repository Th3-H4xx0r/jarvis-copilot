"""Power integrations: what refuses while an integration is off, and what never changes mid-chat."""
from __future__ import annotations

import json

import pytest

from jarvis_power import gate, state

from .conftest import simple

ROUTED = simple(id="alpha", name="Alpha", extra='''
    route_prefixes = ("/api/alpha", "/api/alpha/deep")
    route_exempt = ("/api/alpha/approvals",)
    toolsets = ("fake_power_ts",)
''')


@pytest.fixture()
def alpha(fake_pkg, reg, monkeypatch):
    from jarvis_power import discovery
    monkeypatch.setattr(discovery, "_toolset_exists", lambda name: True)
    fake_pkg({"alpha": ROUTED})
    state.ensure_all()
    return "alpha"


def test_route_blocked_only_when_off_and_not_exempt(alpha):
    assert gate.route_block("/api/alpha/state") is None
    state.write_enabled("alpha", False, by="app")
    blocked = gate.route_block("/api/alpha/state")
    assert blocked == {"error": "Alpha is switched off", "power_off": "alpha"}
    assert gate.route_block("/api/alpha/deep/x")["power_off"] == "alpha"
    assert gate.route_block("/api/alpha/approvals/123/approve") is None
    assert gate.route_block("/api/alphabet") is None          # a prefix is a path segment
    assert gate.route_block("/api/power/alpha") is None
    assert gate.route_block("/api/other") is None


def test_tool_call_refused_while_off(alpha):
    from tools.registry import ToolRegistry

    ran = []
    r = ToolRegistry()
    r.register(name="fake_power_tool", toolset="fake_power_ts",
               schema={"name": "fake_power_tool", "description": "x",
                       "parameters": {"type": "object", "properties": {}}},
               handler=lambda args, **kw: ran.append(1) or json.dumps({"ok": True}))
    assert json.loads(r.dispatch("fake_power_tool", {})) == {"ok": True}
    state.write_enabled("alpha", False, by="app")
    out = json.loads(r.dispatch("fake_power_tool", {}))
    assert out == {"error": "Alpha is switched off"}
    assert ran == [1]


def test_existing_session_keeps_toolsets_new_session_drops(alpha):
    assert gate.session_off_toolsets("S1") == []
    state.write_enabled("alpha", False, by="app")
    assert gate.session_off_toolsets("S1") == []               # its first answer sticks
    assert gate.session_off_toolsets("S2") == ["fake_power_ts"]
    assert gate.session_off_toolsets(None) == ["fake_power_ts"]
    state.write_enabled("alpha", True, by="app")
    assert gate.session_off_toolsets("S2") == ["fake_power_ts"]  # switching on waits for a new chat too
    gate.remember_session("S3", ["fake_power_ts"])
    assert gate.session_off_toolsets("S3") == ["fake_power_ts"]


def test_off_skills_hidden(alpha, monkeypatch):
    from jarvis_registry import integrations
    monkeypatch.setattr(integrations, "skills_for",
                        lambda space: [{"name": "alpha-skill"}] if space == "alpha" else [])
    assert gate.off_skill_names() == set()
    state.write_enabled("alpha", False, by="app")
    assert gate.off_skill_names() == {"alpha-skill"}
    from agent.skill_utils import get_disabled_skill_names
    assert "alpha-skill" in get_disabled_skill_names()


def test_gated_hook_noop_while_off(alpha):
    hits = []
    hook = gate.gated("alpha", lambda **kw: hits.append(kw) or "ctx")
    assert hook(x=1) == "ctx"
    state.write_enabled("alpha", False, by="app")
    assert hook(x=2) is None
    assert hits == [{"x": 1}]
