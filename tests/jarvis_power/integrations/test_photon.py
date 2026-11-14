"""Photon as a Power integration: off means no adapter and no sends, whatever the env says."""
from __future__ import annotations

import asyncio

from jarvis_power import discovery, state


def test_photon_not_enabled_when_off_even_with_env(reg, monkeypatch):
    monkeypatch.setenv("PHOTON_PROJECT_ID", "proj")
    discovery.reset()
    state.ensure_all()
    from plugins.platforms.photon import adapter
    assert adapter.check_requirements() is (adapter.HTTPX_AVAILABLE is True)
    state.write_enabled("photon", False, by="app")
    assert adapter.check_requirements() is False


def test_send_message_photon_refused_while_off(reg, monkeypatch):
    monkeypatch.setenv("PHOTON_PROJECT_ID", "proj")
    discovery.reset()
    state.ensure_all()
    state.write_enabled("photon", False, by="app")
    from plugins.platforms.photon import adapter
    out = asyncio.run(adapter._standalone_send(None, "+15550001111", "hi"))
    assert out == {"error": "Photon is switched off"}


def test_photon_seeds_on(reg, monkeypatch):
    monkeypatch.delenv("PHOTON_PROJECT_ID", raising=False)
    discovery.reset()
    assert discovery.get("photon").seed_enabled() is True
