"""JarvisCopilot edge-exposure subsystem.

Manages a Cloudflare Tunnel (``cloudflared``) plus a local ``nginx`` reverse
proxy so the operator can safely expose the WebUI (and other localhost-bound
JarvisCopilot services) to the public internet behind Cloudflare Access.

Design goals:
- Server-owned routing: JarvisCopilot renders both the cloudflared ingress
  config and the nginx wildcard vhost (``config_render``).
- Full lifecycle: detect/install the binaries (``installer``) and
  start/stop/status them (``supervisor``), preferring native service managers
  (systemd / launchd) and falling back to a supervised subprocess.
- Safety gate: never bring the tunnel UP while the origin is still exposed in
  an unsafe configuration (``manager.preflight``).

Secrets (the cloudflared tunnel token) live in the active profile's state dir
with ``0600`` perms and are never returned to the UI un-masked.
"""

from .manager import EdgeManager, get_manager

__all__ = ["EdgeManager", "get_manager"]
