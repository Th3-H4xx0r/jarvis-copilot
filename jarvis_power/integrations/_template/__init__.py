"""TEMPLATE — copy this folder to ``jarvis_power/integrations/<your_dir>/`` and rename.

A folder whose name starts with ``_`` is never loaded, so this one stays inert.
Everything below is optional except id/name/icon/summary. Read
docs/power-integrations/README.md before you start: it has the full checklist
(surfaces, device gates, tests, deploy order).
"""
from __future__ import annotations

from jarvis_power import PowerIntegration, Setting


class TemplatePower(PowerIntegration):
    # Identity. `id` is permanent: it is also the registry space id and what every
    # device checks (`PowerState.isOn("template")`).
    id = "template"
    name = "Template"
    icon = "bolt"
    summary = "What this does, in one plain sentence."

    # On by default for a new install. Override seed_enabled() to mirror an existing
    # feature's current on/off the first time the framework sees it.
    default_enabled = True
    # True → switching it off (from any device or by Jarvis) needs Face ID on the iPhone.
    protected = False

    # Where start()/stop() run: "webui" (the web server) and/or "gateway".
    processes = ("webui",)
    # Its agent toolsets (keys in toolsets.TOOLSETS or plugin toolsets). While off,
    # their calls are refused at once and new chats don't get them.
    toolsets = ()
    # HTTP paths it owns; they answer 409 while off. route_exempt stays open.
    route_prefixes = ()
    route_exempt = ()
    # Device places that hide while it's off — each id must be in jarvis_power/surfaces.py.
    surfaces = ()
    # Its settings form. `jarvis` = what Jarvis may do from chat: allow / ask / never.
    settings = (
        Setting("enabled_extra", "Extra behaviour", "toggle", default=False,
                help="An example setting."),
    )
    # Actions its card/page buttons may run (see action()).
    actions = ("refresh",)

    def start(self, process: str) -> None:
        # Begin background work here (threads, workers, adapters). Keep handles on
        # self so stop() can end them.
        pass

    def stop(self, process: str) -> None:
        # End ALL background work started in start(). Off must really mean off.
        pass

    def status_line(self) -> str:
        return "Ready"

    def state(self) -> dict:
        # What ui.json binds to with {"$": "count"}.
        return {"count": 0}

    def action(self, name: str, event: dict) -> dict:
        if name == "refresh":
            return {"state": self.state(), "toast": "Refreshed"}
        return {"error": f"unknown action {name!r}"}
