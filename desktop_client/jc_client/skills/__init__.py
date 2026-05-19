"""Skill registry for the desktop client.

A "skill" is a function the server can invoke remotely. Each module
registers its skills via the ``@skill`` decorator. At service startup
we import ``common`` plus the platform-specific module so the resulting
registry reflects what this machine can actually do.

Naming rule: skills MUST be cross-platform-stable. ``open_app(name)``
takes the same shape on every OS even if its implementation differs.
The agent should never need to know which platform is on the other
end of the bridge to call a skill.
"""
from __future__ import annotations

import inspect
import logging
import platform
import sys
import threading
from typing import Any, Callable

log = logging.getLogger(__name__)

# name -> {"name", "description", "input_schema", "fn", "destructive"}
_REGISTRY: dict[str, dict] = {}
_REGISTRY_LOCK = threading.Lock()


def skill(
    name: str,
    description: str,
    input_schema: dict | None = None,
    *,
    destructive: bool = False,
):
    """Decorator: register a function as a remotely-callable skill.

    Args:
        name: stable identifier the agent uses to invoke this skill.
        description: short human-readable summary. Surfaces in the
            agent's tool list, so write it like a tool description.
        input_schema: JSON Schema for the args object. Defaults to
            ``{"type":"object"}`` (any shape accepted).
        destructive: marks the skill as a side-effectful action. v1
            doesn't gate these client-side (per the no-confirmation
            choice) but the marker is sent in the manifest so the
            agent / server-side ACL can treat them differently.
    """
    schema = input_schema or {"type": "object"}

    def deco(fn: Callable[..., Any]) -> Callable[..., Any]:
        with _REGISTRY_LOCK:
            _REGISTRY[name] = {
                "name": name,
                "description": description,
                "input_schema": schema,
                "fn": fn,
                "destructive": destructive,
            }
        return fn

    return deco


def all_manifest(disabled: list[str] | None = None) -> list[dict]:
    """Manifest sent to the server. Excludes locally-disabled skills.

    Each entry is a dict with name/description/input_schema/destructive
    (no fn). Matches what the server's device_bridge expects.
    """
    skip = set(disabled or [])
    out = []
    with _REGISTRY_LOCK:
        for name, s in _REGISTRY.items():
            if name in skip:
                continue
            out.append(
                {
                    "name": s["name"],
                    "description": s["description"],
                    "input_schema": s["input_schema"],
                    "destructive": s["destructive"],
                }
            )
    out.sort(key=lambda s: s["name"])
    return out


def invoke(name: str, args: dict | None = None) -> Any:
    """Execute a registered skill. Returns whatever the impl returns.

    Raises:
        KeyError: skill is not registered.
        TypeError: args don't match the skill signature.
    """
    with _REGISTRY_LOCK:
        entry = _REGISTRY.get(name)
    if not entry:
        raise KeyError(f"unknown skill: {name!r}")
    fn = entry["fn"]
    args = args or {}
    # Reject extra args so a typo on the agent side surfaces loudly
    # instead of getting silently dropped.
    sig = inspect.signature(fn)
    allowed = set(sig.parameters.keys())
    unknown = set(args) - allowed
    if unknown and not any(
        p.kind is inspect.Parameter.VAR_KEYWORD for p in sig.parameters.values()
    ):
        raise TypeError(
            f"skill {name!r} got unexpected args: {sorted(unknown)}"
        )
    return fn(**args)


def has_skill(name: str) -> bool:
    with _REGISTRY_LOCK:
        return name in _REGISTRY


def registered_names() -> list[str]:
    with _REGISTRY_LOCK:
        return sorted(_REGISTRY)


# ── Auto-load on import ────────────────────────────────────────────────────

def _platform_module_name() -> str:
    sysname = sys.platform
    if sysname == "darwin":
        return "jc_client.skills.mac"
    if sysname == "win32":
        return "jc_client.skills.windows"
    if sysname.startswith("linux"):
        return "jc_client.skills.linux"
    return ""


def load_all(allow_shell: bool = False) -> None:
    """Import the skill modules. Called once from service startup.

    ``allow_shell`` gates the ``run_shell`` skill; when False, ``common``
    skips registering it.
    """
    import jc_client.skills.common as _common  # noqa: F401  (registers via decorator)

    if allow_shell:
        _common._register_run_shell()  # explicit opt-in

    mod = _platform_module_name()
    if mod:
        try:
            __import__(mod)
        except Exception as exc:
            log.warning("Failed to load platform skills %s: %s", mod, exc)
    log.info(
        "Loaded %d skills on %s",
        len(_REGISTRY),
        platform.platform(),
    )
