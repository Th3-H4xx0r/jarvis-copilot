"""Photon (iMessage) provider setup — read/write the integration's credentials.

Backs the WebUI and mobile "Photon provider setup" screens. Photon ships as a
bundled gateway *platform* plugin (``plugins/platforms/photon``), which auto-loads
and self-gates on ``check_requirements()`` — so configuring it is purely a matter
of writing the ``PHOTON_*`` env vars. No ``plugins.enabled`` step is required.

We reuse :func:`api.providers._write_env_file`, the same atomic, lock-guarded
writer the LLM-provider key UI uses, so values land in ``~/.jarviscopilot/.env``
*and* ``os.environ`` (the latter lets the webui's own Code Master iMessage
notification path work immediately, before any gateway restart).

Secrets are never returned to the client — GET reports only whether each secret is
set; POST updates a secret only when a non-empty value is supplied (so re-saving
the form without re-typing a secret preserves it).
"""

from __future__ import annotations

import os
from typing import Any, Dict

# (env var, json key, is_secret, required, label) — the form's field order.
_FIELDS = [
    ("PHOTON_PROJECT_ID", "project_id", False, True,
     "Project ID"),
    ("PHOTON_PROJECT_SECRET", "project_secret", True, True,
     "Project secret"),
    ("PHOTON_NOTIFY_TARGET", "notify_target", False, False,
     "Your iMessage handle (default notification recipient)"),
    ("PHOTON_SIDECAR_URL", "sidecar_url", False, False,
     "Sidecar URL"),
    ("PHOTON_SIDECAR_TOKEN", "sidecar_token", True, False,
     "Sidecar token"),
    ("PHOTON_ALLOWED_USERS", "allowed_users", False, False,
     "Allowed inbound handles (comma-separated)"),
]

_DEFAULT_SIDECAR_URL = "http://127.0.0.1:8799"


def _field_meta() -> list:
    """Describe the form so the UIs can render labels/secret flags generically."""
    return [
        {"key": key, "label": label, "secret": secret, "required": required}
        for (_env, key, secret, required, label) in _FIELDS
    ]


def probe_sidecar() -> Dict[str, Any]:
    """Best-effort health probe of the running sidecar. Never raises / hangs.

    Lets the setup screen warn when the sidecar is unreachable or — the silent
    footgun — running in MOCK mode (no creds picked up yet), where sends look
    successful but nothing is delivered. Resolves URL+token from the process env
    (which the just-written .env populated)."""
    url = (os.getenv("PHOTON_SIDECAR_URL", "").strip() or _DEFAULT_SIDECAR_URL).rstrip("/")
    token = os.getenv("PHOTON_SIDECAR_TOKEN", "").strip()
    try:
        import httpx

        headers = {"X-Photon-Token": token} if token else {}
        r = httpx.get(f"{url}/health", headers=headers, timeout=2.0)
        if r.status_code == 401:
            return {"reachable": True, "ok": False, "error": "token mismatch (401)"}
        if r.status_code >= 300:
            return {"reachable": True, "ok": False, "error": f"HTTP {r.status_code}"}
        data = r.json()
        return {
            "reachable": True,
            "ok": True,
            "mock": bool(data.get("mock")),
            "connected": bool(data.get("connected")),
        }
    except Exception as e:
        return {"reachable": False, "ok": False, "error": str(e)[:120]}


def get_photon_config(probe: bool = True) -> Dict[str, Any]:
    """Current Photon config for the setup screen. Secrets are masked."""
    out: Dict[str, Any] = {"fields": _field_meta()}
    for env, key, secret, _required, _label in _FIELDS:
        val = os.getenv(env, "").strip()
        if secret:
            out[key] = ""              # never leak the secret
            out[f"{key}_set"] = bool(val)
        else:
            # Surface the effective sidecar URL default so the field isn't blank.
            if key == "sidecar_url" and not val:
                val = _DEFAULT_SIDECAR_URL
            out[key] = val
    out["configured"] = bool(os.getenv("PHOTON_PROJECT_ID", "").strip())
    if probe:
        out["sidecar"] = probe_sidecar()
    return out


def set_photon_config(body: Dict[str, Any]) -> Dict[str, Any]:
    """Persist supplied Photon fields. Returns ``{ok, configured}`` or an error.

    - Non-secret fields are written as given (empty string clears them).
    - Secret fields are written only when a non-empty value is supplied;
      an absent/blank secret leaves the stored value untouched.
    - Required fields (project id/secret) must end up set (either newly
      supplied, or — for the secret — already present).
    """
    if not isinstance(body, dict):
        return {"ok": False, "error": "invalid body"}

    updates: Dict[str, str | None] = {}
    for env, key, secret, _required, _label in _FIELDS:
        if key not in body:
            continue
        raw = body.get(key)
        val = "" if raw is None else str(raw).strip()
        if "\n" in val or "\r" in val:
            return {"ok": False, "error": f"{key} must not contain newlines"}
        if secret:
            if val:                    # only overwrite a secret when one is typed
                updates[env] = val
        else:
            updates[env] = val or None  # empty clears a non-secret field

    # Validate required fields against the post-write state.
    project_id = updates.get("PHOTON_PROJECT_ID")
    if "PHOTON_PROJECT_ID" in updates:
        if not project_id:
            return {"ok": False, "error": "Project ID is required"}
    elif not os.getenv("PHOTON_PROJECT_ID", "").strip():
        return {"ok": False, "error": "Project ID is required"}

    secret_supplied = bool(updates.get("PHOTON_PROJECT_SECRET"))
    if not secret_supplied and not os.getenv("PHOTON_PROJECT_SECRET", "").strip():
        return {"ok": False, "error": "Project secret is required"}

    if not updates:
        return {"ok": True, "configured": bool(os.getenv("PHOTON_PROJECT_ID", "").strip())}

    try:
        from api.providers import _get_hermes_home, _write_env_file

        env_path = _get_hermes_home() / ".env"
        _write_env_file(env_path, updates)
    except Exception as exc:  # pragma: no cover - filesystem/permission errors
        return {"ok": False, "error": f"Failed to save Photon config: {exc}"}

    return {"ok": True, "configured": bool(os.getenv("PHOTON_PROJECT_ID", "").strip())}


def reload_sidecar() -> bool:
    """Make the running sidecar pick up freshly-saved creds WITHOUT a manual
    restart. Tries the sidecar's in-process POST /reload first (works however it
    was started); falls back to a systemd restart. Best-effort; never raises."""
    url = (os.getenv("PHOTON_SIDECAR_URL", "").strip() or _DEFAULT_SIDECAR_URL).rstrip("/")
    token = os.getenv("PHOTON_SIDECAR_TOKEN", "").strip()
    headers = {"X-Photon-Token": token} if token else {}
    try:
        import httpx

        r = httpx.post(f"{url}/reload", headers=headers, timeout=20.0)
        if r.status_code < 300:
            return True
    except Exception:
        pass
    # Sidecar unreachable (not running yet, or token changed) → try systemd.
    try:
        import subprocess
        import time

        subprocess.run(
            ["systemctl", "restart", "jarviscopilot-photon-sidecar"],
            timeout=20, capture_output=True,
        )
        time.sleep(1.5)  # let it boot before the caller probes
        return True
    except Exception:
        return False
