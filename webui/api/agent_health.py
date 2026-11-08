"""JarvisCopilot agent/gateway heartbeat payload helpers (#716, #1879).

The WebUI process is not always paired with a long-running JarvisCopilot gateway. Some
setups use WebUI only, while self-hosted messaging deployments run a separate
JarvisCopilot gateway daemon that records runtime metadata in the JarvisCopilot home.
This module turns those existing safe runtime signals into a small UI-facing
heartbeat without shelling out or adding psutil as a hard dependency.

Cross-container note (#1879): ``gateway.status.get_running_pid()`` uses
``fcntl.flock`` and ``os.kill(pid, 0)``, both of which require the caller to
share a PID namespace with the gateway process. In multi-container deployments
where the WebUI runs separately from ``jarviscopilot`` and only a JarvisCopilot data
volume is shared, those checks always return ``None`` and the dashboard
incorrectly shows "Gateway not running". To stay accurate without forcing a
``pid: "service:jarviscopilot"`` compose workaround, we accept a recent
``updated_at`` timestamp on ``gateway_state.json`` (combined with
``gateway_state == "running"``) as an equivalent live-process signal.  Older
gateway builds do not refresh that file periodically, so a stale
``gateway_state == "running"`` record is treated as inconclusive rather than a
confirmed outage.
"""

from __future__ import annotations

import importlib
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

_GATEWAY_PID_FILE = "gateway.pid"
_GATEWAY_RUNTIME_STATUS_FILE = "gateway_state.json"


# Two cron ticks (~60s each). Chosen to avoid false negatives during brief
# gateway restarts while still surfacing a true outage within a couple of
# minutes. Override is intentionally not exposed: keep the check deterministic
# and identical across deployments so support diagnostics are reproducible.
GATEWAY_FRESHNESS_THRESHOLD_S: float = 120.0


def _checked_at() -> str:
    return datetime.now(timezone.utc).isoformat()


def _state_age_s(runtime_status, state: str, now: datetime | None) -> float | None:
    """Seconds since ``gateway_state.json`` reported ``state``; None when it reports
    another state or has no usable ``updated_at``.

    The timestamp is the ISO-8601 that gateway/status.py writes. A naive one
    could mean anything across containers / hosts, so it is refused rather than
    assumed UTC. Unparseable input is never fresh."""
    if not isinstance(runtime_status, dict) or runtime_status.get("gateway_state") != state:
        return None
    raw_updated_at = runtime_status.get("updated_at")
    if not isinstance(raw_updated_at, str) or not raw_updated_at:
        return None
    try:
        updated_at = datetime.fromisoformat(raw_updated_at)
    except (TypeError, ValueError):
        return None
    if updated_at.tzinfo is None:
        return None
    return ((now or datetime.now(timezone.utc)) - updated_at).total_seconds()


def _runtime_status_is_fresh(
    runtime_status: dict[str, Any] | None,
    *,
    now: datetime | None = None,
    threshold_s: float = GATEWAY_FRESHNESS_THRESHOLD_S,
) -> bool:
    """The gateway self-reported ``running`` within ``threshold_s``: the
    cross-container liveness signal when ``get_running_pid()`` returns None only
    because of PID-namespace isolation (#1879).

    Clock skew between containers can make the age slightly negative; a future
    timestamp within the threshold still counts, a wildly-future one does not."""
    age_s = _state_age_s(runtime_status, "running", now)
    return age_s is not None and abs(age_s) <= threshold_s


def _runtime_status_is_stale(
    runtime_status: dict[str, Any] | None,
    state: str,
    *,
    now: datetime | None = None,
    threshold_s: float = GATEWAY_FRESHNESS_THRESHOLD_S,
) -> bool:
    """The gateway last reported ``state`` longer ago than ``threshold_s``.

    A stale ``stopped`` root file is a gateway the user no longer runs, e.g.
    only profile-scoped gateways (#1944). A stale ``running`` file is older
    gateway builds that only write on lifecycle changes, read from another
    container: not enough information, rather than "down"."""
    age_s = _state_age_s(runtime_status, state, now)
    return age_s is not None and age_s > threshold_s


def _gateway_status_module():
    """Load gateway.status lazily so tests and WebUI-only installs stay isolated."""
    return importlib.import_module("gateway.status")


def _gateway_root_pid_path() -> Path | None:
    """Return the root JarvisCopilot gateway PID path.

    Gateway runtime files are root-level singletons.  A profile-scoped WebUI
    process may have HERMES_HOME=<root>/profiles/<name>, but gateway.pid,
    gateway.lock, and gateway_state.json still live under <root>.
    """
    try:
        from jarviscopilot_constants import get_default_hermes_root
        return get_default_hermes_root() / _GATEWAY_PID_FILE
    except Exception:
        return None


def _read_runtime_status_path(path: Path) -> dict[str, Any] | None:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None
    if isinstance(payload, dict):
        return payload
    return None


def _read_gateway_runtime_status(gateway_status: Any, pid_path: Path | None) -> dict[str, Any] | None:
    read_runtime_status = gateway_status.read_runtime_status
    if pid_path is not None:
        try:
            return read_runtime_status(pid_path=pid_path)
        except TypeError:
            try:
                return read_runtime_status(pid_path)
            except TypeError:
                if getattr(gateway_status, "__name__", "") == "gateway.status" or hasattr(
                    gateway_status,
                    "_read_json_file",
                ):
                    runtime_status_file = str(
                        getattr(gateway_status, "_RUNTIME_STATUS_FILE", _GATEWAY_RUNTIME_STATUS_FILE)
                    )
                    runtime_status = _read_runtime_status_path(pid_path.with_name(runtime_status_file))
                    if runtime_status is not None:
                        return runtime_status
    return read_runtime_status()


def _gateway_running_pid(gateway_status: Any, pid_path: Path | None) -> int | None:
    get_running_pid = gateway_status.get_running_pid
    if pid_path is not None:
        try:
            return get_running_pid(pid_path=pid_path, cleanup_stale=False)
        except TypeError:
            try:
                return get_running_pid(pid_path, cleanup_stale=False)
            except TypeError:
                pass
    try:
        return get_running_pid(cleanup_stale=False)
    except TypeError:
        # Older agent versions may not expose cleanup_stale. Keep compatibility.
        return get_running_pid()


def _runtime_detail_subset(runtime_status: dict[str, Any] | None) -> dict[str, Any]:
    """Return only non-sensitive runtime fields for the browser.

    gateway.status records argv/PID metadata so the CLI can validate process
    identity. The WebUI alert only needs health semantics, never raw command
    lines, paths, environment, or tokens.
    """
    if not isinstance(runtime_status, dict):
        return {}

    details: dict[str, Any] = {}
    gateway_state = runtime_status.get("gateway_state")
    if isinstance(gateway_state, str) and gateway_state:
        details["gateway_state"] = gateway_state

    updated_at = runtime_status.get("updated_at")
    if isinstance(updated_at, str) and updated_at:
        details["updated_at"] = updated_at

    try:
        details["active_agents"] = max(0, int(runtime_status.get("active_agents") or 0))
    except (TypeError, ValueError):
        pass

    platforms = runtime_status.get("platforms")
    if isinstance(platforms, dict):
        details["platform_count"] = len(platforms)
        states: dict[str, int] = {}
        for payload in platforms.values():
            if not isinstance(payload, dict):
                continue
            state = payload.get("state")
            if isinstance(state, str) and state:
                states[state] = states.get(state, 0) + 1
        if states:
            details["platform_states"] = states

    return details


def build_agent_health_payload() -> dict[str, Any]:
    """Return `{alive, checked_at, details}` for the JarvisCopilot gateway/agent.

    `alive` is intentionally tri-state:
      * True: a gateway runtime signal says the process is alive.
      * False: gateway metadata exists, but no live gateway process owns it.
      * None: no gateway metadata/status is available, so this WebUI setup is
        probably not configured with a separate gateway process.
    """
    checked_at = _checked_at()

    def payload(alive, state, reason=None, details=None):
        out = {"state": state}
        if reason:
            out["reason"] = reason
        return {"alive": alive, "checked_at": checked_at, "details": {**out, **(details or {})}}

    try:
        gateway_status = _gateway_status_module()
    except Exception as exc:
        return payload(None, "unknown", "gateway_status_unavailable", {"error": type(exc).__name__})

    gateway_pid_path = _gateway_root_pid_path()
    try:
        runtime_status = _read_gateway_runtime_status(gateway_status, gateway_pid_path)
    except Exception:
        runtime_status = None
    try:
        running_pid = _gateway_running_pid(gateway_status, gateway_pid_path)
    except Exception:
        running_pid = None

    safe_details = _runtime_detail_subset(runtime_status)
    if running_pid is not None:
        return payload(True, "alive", None, safe_details)
    # Cross-container fallback (#1879), trusted only when the gateway itself says
    # "running", so a crash without cleanup still surfaces as down.
    if _runtime_status_is_fresh(runtime_status):
        return payload(True, "alive", "cross_container_freshness", safe_details)
    if _runtime_status_is_stale(runtime_status, "stopped"):
        return payload(None, "unknown", "gateway_stale_stopped_state", safe_details)
    if _runtime_status_is_stale(runtime_status, "running"):
        return payload(None, "unknown", "gateway_stale_running_state", safe_details)
    if isinstance(runtime_status, dict):
        return payload(False, "down", "gateway_not_running", safe_details)
    return payload(None, "unknown", "gateway_not_configured")
