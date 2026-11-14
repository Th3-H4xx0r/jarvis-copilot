"""What a Power integration is: the class each one subclasses, and its settings.

A Power integration is a built-in feature (written into the server and the apps)
that shows up on the Integrations tab with a Power tag, a switch and a settings
form. Each one is a package under ``jarvis_power/integrations/<dir>/`` holding one
subclass of :class:`PowerIntegration`. The class *declares* what the feature owns —
routes, toolsets, background work, settings, the screens devices must hide — and
the framework does the generic work (state, gating, start/stop, telling devices).

See docs/power-integrations/README.md for the full guide.
"""
from __future__ import annotations

import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Literal, Optional

SettingKind = Literal["toggle", "text", "number", "picker", "secret"]
JarvisRule = Literal["allow", "ask", "never"]
KINDS = ("toggle", "text", "number", "picker", "secret")
JARVIS_RULES = ("allow", "ask", "never")
PROCESSES = ("webui", "gateway")
PLATFORMS = ("ios", "mac", "web")
NATIVE_PIECES = ("card", "page", "settings")


class PowerError(Exception):
    """A Power integration was asked for something it can't do. The text is shown to people."""


@dataclass(frozen=True)
class Setting:
    """One field on a Power integration's settings form.

    ``jarvis`` is what Jarvis may do with it from chat: ``allow`` (change it),
    ``ask`` (change it only after Face ID on the iPhone) or ``never`` (app only).
    """

    key: str
    label: str
    kind: SettingKind
    default: Any = None
    help: str = ""
    options: tuple[tuple[str, str], ...] = ()
    min: Optional[float] = None
    max: Optional[float] = None
    unit: str = ""
    jarvis: JarvisRule = "allow"

    def schema(self) -> dict:
        """The form field as devices draw it. A secret's default is never sent."""
        out: dict[str, Any] = {"key": self.key, "label": self.label, "kind": self.kind,
                               "help": self.help, "jarvis": self.jarvis}
        if self.kind != "secret":
            out["default"] = self.default
        if self.options:
            out["options"] = [{"value": v, "label": label} for v, label in self.options]
        if self.min is not None:
            out["min"] = self.min
        if self.max is not None:
            out["max"] = self.max
        if self.unit:
            out["unit"] = self.unit
        return out

    def coerce(self, value: Any) -> Any:
        """``value`` as this field stores it, or :class:`PowerError` saying what's wrong."""
        if self.kind == "toggle":
            if isinstance(value, bool):
                return value
            raise PowerError(f"{self.label} must be on or off")
        if self.kind == "number":
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
                raise PowerError(f"{self.label} must be a number")
            if self.min is not None and value < self.min:
                raise PowerError(f"{self.label} must be at least {self.min:g}")
            if self.max is not None and value > self.max:
                raise PowerError(f"{self.label} must be at most {self.max:g}")
            return value
        if self.kind == "picker":
            allowed = [v for v, _ in self.options]
            if value not in allowed:
                raise PowerError(f"{self.label} must be one of {', '.join(map(str, allowed))}")
            return value
        # text and secret
        if value is None and self.kind == "secret":
            return None                      # clears a secret
        if not isinstance(value, str):
            raise PowerError(f"{self.label} must be text")
        return value


@dataclass(frozen=True)
class Link:
    """An existing screen the integration's page offers to open on one platform."""

    platform: Literal["ios", "mac", "web"]
    target: str
    label: str


class PowerIntegration:
    """Subclass this once per Power integration. Every attribute is optional except
    the four identity strings.

    Lifecycle: the framework seeds ``enabled`` once from :meth:`seed_enabled`, then
    the Power switch is the only switch. While off, its routes answer 409, its tool
    calls are refused, its toolsets are left out of NEW chats, its hooks don't fire,
    its schedules are paused and devices hide its ``surfaces``. :meth:`stop` must end
    ALL of its background work in that process; :meth:`start` must bring it back.
    """

    # ── identity ────────────────────────────────────────────────────────────
    id: str = ""                     # stable; also its registry space id
    name: str = ""
    icon: str = ""                   # same icon vocabulary as regular integrations
    summary: str = ""

    # ── behaviour ───────────────────────────────────────────────────────────
    default_enabled: bool = True
    protected: bool = False          # switching off needs Face ID on the iPhone
    adopt_space: bool = False        # reuse an existing registry space with this id (else power-<id>)
    processes: tuple[str, ...] = ()  # where start()/stop() run: "webui", "gateway"
    toolsets: tuple[str, ...] = ()   # its agent tools; refused while off, dropped from new chats
    route_prefixes: tuple[str, ...] = ()   # webui paths it owns; 409 while off
    route_exempt: tuple[str, ...] = ()     # paths under those prefixes that stay open while off
    surfaces: tuple[str, ...] = ()   # device places hidden while off (ids in jarvis_power.surfaces)
    links: tuple[Link, ...] = ()     # existing screens its page offers to open
    native: dict = {}                # platform -> {"card","page","settings"} drawn natively
    settings: tuple[Setting, ...] = ()
    actions: tuple[str, ...] = ()    # action names its card/page may run (see action())

    # ── hooks the framework calls ───────────────────────────────────────────
    def seed_enabled(self) -> bool:
        """Its state the first time the framework sees it. Mirror today's reality."""
        return self.default_enabled

    def can_switch_off(self) -> Optional[str]:
        """A reason it can't be switched off right now (shown as-is), or None."""
        return None

    def start(self, process: str) -> None:
        """Begin its background work in ``process`` ("webui" or "gateway")."""

    def stop(self, process: str) -> None:
        """End ALL of its background work in ``process``."""

    def read_settings(self) -> dict:
        """Current settings values. Default: kept in its power document."""
        from jarvis_power import state
        return state.stored_settings(self.id)

    def write_settings(self, changes: dict) -> None:
        """Store already-validated changes. Override to keep a feature's existing store."""
        from jarvis_power import state
        state.store_settings(self.id, changes)

    def status_line(self) -> str:
        """The one line under its name on its card."""
        return ""

    def state(self) -> dict:
        """The view state its JSON card/page binds to."""
        return {}

    def action(self, name: str, event: dict) -> dict:
        """Run one card/page action. Same result as a UI action script:
        ``{"state"?: dict, "toast"?: str, "error"?: str}``."""
        return {"error": "no such action"}

    def ui(self) -> Optional[dict]:
        """Its card/page trees, from ``ui.json`` beside its module."""
        module = sys.modules.get(type(self).__module__)
        path = Path(getattr(module, "__file__", "") or "").parent / "ui.json"
        if not path.is_file():
            return None
        return json.loads(path.read_text(encoding="utf-8"))

    def hooks(self) -> dict[str, Callable]:
        """Plugin lifecycle hooks (``pre_llm_call`` …) it adds; they only fire while it's on."""
        return {}

    def __repr__(self) -> str:
        return f"<PowerIntegration {self.id}>"
