"""What clients see of Power integrations: rows for /api/power, cards, UI."""
from __future__ import annotations

from jarvis_power import discovery, state


def row(integration_id: str) -> dict:
    p = discovery.get(integration_id)
    body = state.doc(integration_id)
    return {
        "id": p.id,
        "name": p.name,
        "icon": p.icon,
        "summary": p.summary,
        "enabled": bool(body.get("enabled", True)) if body else True,
        "protected": p.protected,
        "error": body.get("error"),
        "space": state.space_id_for(p.id),
    }
