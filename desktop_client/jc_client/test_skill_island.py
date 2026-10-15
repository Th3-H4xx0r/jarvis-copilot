"""`jarvis_island`: Jarvis opens the Mac app's notch island on a tab
("show me my music", "open the agents")."""
from __future__ import annotations

import pytest

from jc_client.skills import _REGISTRY
from jc_client.skills import island


@pytest.fixture
def sent(monkeypatch):
    out = []
    monkeypatch.setattr(island, "_app_running", lambda: True)
    island.set_broadcast(out.append)
    yield out
    island.set_broadcast(None)


def test_registered():
    assert "jarvis_island" in _REGISTRY
    tabs = _REGISTRY["jarvis_island"]["input_schema"]["properties"]["tab"]["enum"]
    assert {"agents", "chat", "services", "music", "mail", "recap"} <= set(tabs)


def test_opens_the_tab(sent):
    assert island.jarvis_island(tab="music") == {"ok": True, "tab": "music"}
    assert sent == [{"type": "island", "tab": "music"}]


def test_chat_can_carry_a_draft(sent):
    island.jarvis_island(tab="chat", text="Summarise this window")
    assert sent[-1] == {"type": "island", "tab": "chat", "text": "Summarise this window"}


def test_refuses_unknown_tabs_and_a_missing_app(sent, monkeypatch):
    with pytest.raises(ValueError):
        island.jarvis_island(tab="settings")
    monkeypatch.setattr(island, "_app_running", lambda: False)
    out = island.jarvis_island(tab="agents")
    assert out["ok"] is False and "Jarvis app" in out["error"]
