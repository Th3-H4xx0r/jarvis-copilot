"""Power integrations: the webui answers 409 for an off integration's routes."""
from __future__ import annotations

import sys
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import api.helpers as helpers  # noqa: E402
import api.routes as routes  # noqa: E402


def test_gate_409_body(monkeypatch):
    box = {}

    def fake_j(handler, body, status=200):
        box.update(body=body, status=status)
        return True

    monkeypatch.setattr(helpers, "j", fake_j)
    import jarvis_power.gate as gate
    monkeypatch.setattr(gate, "route_block",
                        lambda path: {"error": "Alpha is switched off", "power_off": "alpha"}
                        if path.startswith("/api/alpha") else None)
    assert routes.handle_get(object(), urlparse("/api/alpha/state")) is True
    assert box == {"body": {"error": "Alpha is switched off", "power_off": "alpha"}, "status": 409}
