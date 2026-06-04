"""Browser target selector for Jarvis.

A *browser target* chooses which engine the ``browser_*`` tools drive:

  - ``server``  — native headless ``agent-browser`` (default, zero-cost).
  - ``desktop`` — the user's real, visible Chrome via Playwright MCP
                  (headed, dedicated profile), with the existing
                  ``/browser connect`` CDP path as the live fallback.

This module holds only pure helpers (normalization, config read/write,
idempotent Playwright-MCP provisioning, and toolset-gating overrides) so it
stays small and unit-testable.  Side effects (launching Chrome, mutating the
session) live in ``cli.py``'s ``_handle_browser_command``.
"""

from __future__ import annotations

from typing import Any, Dict, Optional, Set, Tuple

from jarviscopilot_cli.config import cfg_get

VALID_TARGETS: Tuple[str, str] = ("server", "desktop")
DEFAULT_TARGET = "server"

PLAYWRIGHT_DESKTOP_SERVER_NAME = "playwright-desktop"
NATIVE_BROWSER_TOOLSET = "browser"


def normalize_browser_target(value: Any) -> str:
    """Return one of ``VALID_TARGETS``; unknown/empty → ``DEFAULT_TARGET``."""
    if not isinstance(value, str):
        return DEFAULT_TARGET
    v = value.strip().lower()
    return v if v in VALID_TARGETS else DEFAULT_TARGET


def get_browser_target(config: Optional[Dict[str, Any]] = None) -> str:
    """Read ``browser.target`` from config (loads it if not provided)."""
    if config is None:
        from jarviscopilot_cli.config import load_config
        config = load_config()
    return normalize_browser_target(
        cfg_get(config, "browser", "target", default=DEFAULT_TARGET)
    )


def set_browser_target(target: str) -> str:
    """Persist ``browser.target`` to config.yaml.  Returns the normalized value."""
    from jarviscopilot_cli.config import load_config, save_config
    norm = normalize_browser_target(target)
    config = load_config()
    config.setdefault("browser", {})["target"] = norm
    save_config(config)
    return norm


def playwright_desktop_profile_dir() -> str:
    """Dedicated profile dir for the Playwright MCP desktop browser.

    Deliberately SEPARATE from ``/browser connect``'s ``chrome-debug`` dir:
    Chrome refuses to open one ``--user-data-dir`` from two live processes, so
    the native CDP path and Playwright MCP must not share a profile.  Log in
    once in this profile; it persists.
    """
    from jarviscopilot_constants import get_hermes_home
    return str(get_hermes_home() / "playwright-profile")


def playwright_desktop_server_config(enabled: bool = True) -> Dict[str, Any]:
    """MCP server config that drives headed real Chrome via Playwright MCP."""
    return {
        "command": "npx",
        "args": [
            "@playwright/mcp@latest",
            "--browser", "chrome",
            "--user-data-dir", playwright_desktop_profile_dir(),
        ],
        "enabled": bool(enabled),
    }


def ensure_playwright_desktop_server(enabled: bool = True) -> bool:
    """Idempotently register/refresh the ``playwright-desktop`` MCP server.

    Returns True if config was written (added or ``enabled`` changed), False if
    it was already present with the desired command/args and enabled state.
    Never touches other servers.
    """
    from jarviscopilot_cli.config import load_config, save_config
    desired = playwright_desktop_server_config(enabled=enabled)
    config = load_config()
    servers = config.setdefault("mcp_servers", {})
    current = servers.get(PLAYWRIGHT_DESKTOP_SERVER_NAME)
    if current == desired:
        return False
    servers[PLAYWRIGHT_DESKTOP_SERVER_NAME] = desired
    save_config(config)
    return True


def browser_target_toolset_overrides(target: str) -> Tuple[Set[str], Set[str]]:
    """Return (enable, disable) toolset sets for the active target.

    desktop → use Playwright MCP, hide the native headless browser toolset.
    server  → use native browser, hide the Playwright desktop toolset.
    Keeping only ONE browser surface visible avoids confusing the model about
    which to use.
    """
    target = normalize_browser_target(target)
    if target == "desktop":
        return {PLAYWRIGHT_DESKTOP_SERVER_NAME}, {NATIVE_BROWSER_TOOLSET}
    return set(), {PLAYWRIGHT_DESKTOP_SERVER_NAME}


def apply_browser_target_gating(enabled_toolsets: Set[str], target: str) -> Set[str]:
    """Apply target overrides to a set of enabled toolset names.

    Fallback-safe — never leaves the model with zero browser tools:
      - ``desktop``: hide native ``browser`` ONLY when the Playwright desktop
        engine is actually present in the enabled set; otherwise keep native
        browser as a fallback (e.g. Playwright not provisioned / unavailable).
      - ``server``: hide ``playwright-desktop`` (no-op when it isn't present),
        keep native ``browser``.
    """
    target = normalize_browser_target(target)
    enabled = set(enabled_toolsets)
    if target == "desktop":
        if PLAYWRIGHT_DESKTOP_SERVER_NAME in enabled:
            enabled.discard(NATIVE_BROWSER_TOOLSET)
        return enabled
    enabled.discard(PLAYWRIGHT_DESKTOP_SERVER_NAME)
    return enabled


def browser_target_plan(target: str) -> Dict[str, Any]:
    """Pure description of what switching to ``target`` should do.

    The CLI executes this: persist the target, provision the Playwright server
    (enabled iff desktop), then run the ``delegate`` action.

      - ``desktop``: Playwright MCP owns the visible Chrome (its own profile);
        ``delegate`` is None — do NOT also run ``/browser connect`` (that would
        launch a second Chrome on a different profile/port and conflict).
      - ``server``: ``delegate`` is "disconnect" to clear any live CDP override
        so the native headless backend is truly active.
    """
    norm = normalize_browser_target(target)
    is_desktop = norm == "desktop"
    return {
        "target": norm,
        "delegate": None if is_desktop else "disconnect",
        "provision_enabled": is_desktop,
    }
