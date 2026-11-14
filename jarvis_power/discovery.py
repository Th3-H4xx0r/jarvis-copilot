"""Finding the built-in Power integrations and checking each one is well-formed.

Every package under ``jarvis_power/integrations/`` whose name doesn't start with
``_`` is one Power integration (so ``_template`` is never loaded). Each package
defines exactly one :class:`PowerIntegration` subclass.
"""
from __future__ import annotations

import importlib
import pkgutil
import re
import threading
from typing import Optional

from jarvis_power.base import (JARVIS_RULES, KINDS, NATIVE_PIECES, PLATFORMS, PROCESSES,
                               PowerError, PowerIntegration)

PACKAGE = "jarvis_power.integrations"
_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
_lock = threading.Lock()
_cache: Optional[dict[str, PowerIntegration]] = None


def integrations() -> dict[str, PowerIntegration]:
    """Every Power integration, by id, in a stable order."""
    global _cache
    with _lock:
        if _cache is None:
            _cache = _discover()
        return dict(_cache)


def get(integration_id: str) -> PowerIntegration:
    found = integrations().get(integration_id)
    if found is None:
        raise PowerError(f"no Power integration named {integration_id!r}")
    return found


def reset() -> None:
    global _cache
    with _lock:
        _cache = None


def _discover() -> dict[str, PowerIntegration]:
    package = importlib.import_module(PACKAGE)
    out: dict[str, PowerIntegration] = {}
    for info in sorted(pkgutil.iter_modules(package.__path__), key=lambda i: i.name):
        if info.name.startswith("_") or not info.ispkg:
            continue
        module = importlib.import_module(f"{PACKAGE}.{info.name}")
        classes = [obj for obj in vars(module).values()
                   if isinstance(obj, type) and issubclass(obj, PowerIntegration)
                   and obj is not PowerIntegration and obj.__module__ == module.__name__]
        if len(classes) != 1:
            raise PowerError(f"{module.__name__} must define exactly one PowerIntegration "
                             f"subclass (found {len(classes)})")
        instance = classes[0]()
        if instance.id in out:
            raise PowerError(f"two Power integrations use the id {instance.id!r}")
        out[instance.id] = instance
    return out


def validate(p: PowerIntegration) -> list[str]:
    """Every problem with ``p``, as readable lines. Empty means well-formed."""
    from jarvis_power.surfaces import CATALOG

    problems: list[str] = []
    who = p.id or type(p).__name__
    if not _ID_RE.match(p.id or ""):
        problems.append(f"{who}: id must be lowercase letters, digits and -")
    for field in ("name", "icon", "summary"):
        if not str(getattr(p, field, "") or "").strip():
            problems.append(f"{who}: {field} is required")
    unknown_process = set(p.processes) - set(PROCESSES)
    if unknown_process:
        problems.append(f"{who}: unknown processes {sorted(unknown_process)} (webui, gateway)")

    seen: set[str] = set()
    for s in p.settings:
        if s.key in seen:
            problems.append(f"{who}: duplicate setting key {s.key!r}")
        seen.add(s.key)
        if s.kind not in KINDS:
            problems.append(f"{who}: setting {s.key!r} has unknown kind {s.kind!r}")
            continue
        if s.jarvis not in JARVIS_RULES:
            problems.append(f"{who}: setting {s.key!r} jarvis rule must be allow, ask or never")
        if s.kind == "picker" and not s.options:
            problems.append(f"{who}: picker setting {s.key!r} needs options")
        if s.kind != "secret" and s.default is not None:
            try:
                s.coerce(s.default)
            except PowerError as exc:
                problems.append(f"{who}: setting {s.key!r} default is invalid: {exc}")

    for name in p.toolsets:
        if not _toolset_exists(name):
            problems.append(f"{who}: toolset {name!r} is not a known toolset")
    for surface in p.surfaces:
        if surface not in CATALOG:
            problems.append(f"{who}: surface {surface!r} is not in jarvis_power.surfaces.CATALOG")
    for link in p.links:
        if link.platform not in PLATFORMS:
            problems.append(f"{who}: link {link.target!r} has unknown platform {link.platform!r}")
    for platform, pieces in dict(p.native).items():
        if platform not in PLATFORMS or not set(pieces) <= set(NATIVE_PIECES):
            problems.append(f"{who}: native must map ios/mac/web to card/page/settings")
    for prefix in (*p.route_prefixes, *p.route_exempt):
        if not prefix.startswith("/"):
            problems.append(f"{who}: route {prefix!r} must start with /")

    try:
        ui = p.ui()
    except (OSError, ValueError) as exc:
        problems.append(f"{who}: ui.json can't be read: {exc}")
        ui = None
    if ui is not None:
        problems.extend(f"{who}: ui.json: {e}" for e in _validate_ui(p, ui))
    return problems


def _validate_ui(p: PowerIntegration, ui: dict) -> list[str]:
    """Check the card/page trees with the regular integrations' validator.

    A Power integration has no stored scripts: its actions are methods. Declared
    actions stand in for scripts, so a control naming an undeclared action is
    caught exactly as an undefined script would be.
    """
    from jarvis_registry.ui import validate_ui

    if not isinstance(ui, dict) or "presentations" not in ui:
        return ["must be an object with presentations"]
    doc = {
        "schema": 1,
        "version": 1,
        "presentations": ui["presentations"],
        "scripts": {"load": {"code": "pass"}, **{a: {"code": "pass"} for a in p.actions}},
    }
    errors, _warnings = validate_ui(doc)
    return errors


def _toolset_exists(name: str) -> bool:
    try:
        import model_tools  # noqa: F401  — registers built-in and plugin tools
        from toolsets import validate_toolset
        return validate_toolset(name)
    except Exception:
        return False
