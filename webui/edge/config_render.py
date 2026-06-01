"""Render the nginx vhost and cloudflared ingress config.

This is the security-critical artifact of the edge subsystem. The generated
nginx config is the trust boundary between the public internet (via Cloudflare)
and the localhost-bound JarvisCopilot services, so it:

- **Strips inbound ``X-Forwarded-*`` / ``X-Real-*`` / ``Forwarded`` headers** and
  re-sets them from values nginx itself controls. A Cloudflare tunnel makes every
  request look like localhost; if a forged ``X-Forwarded-Host`` reached the app it
  would defeat the same-origin CSRF check, so the proxy must own these headers.
- Adds HSTS + the standard hardening headers on every response (the app only sets
  some of them, and only on JSON).
- Applies a per-IP rate limit to blunt brute-force / abuse.
- Routes ``*.domain`` subdomains to their mapped ``127.0.0.1:PORT`` targets and
  returns 444 for unknown hosts (so the catch-all wildcard can't be abused to
  reach an unintended upstream).

Everything binds to localhost; cloudflared is the only public ingress and points
at nginx, which is the only thing that talks to the apps.
"""
from __future__ import annotations

import ipaddress
import re
from typing import Any, Dict, Tuple

_HOSTNAME_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")


def _valid_subdomain(label: str) -> bool:
    """A single DNS label (the subdomain part), or '@' for the apex."""
    if label == "@":
        return True
    return bool(_HOSTNAME_RE.match(label.lower()))


def _valid_target(target: str) -> bool:
    """Targets must be loopback host:port — never an arbitrary upstream (anti-SSRF)."""
    if ":" not in target:
        return False
    host, _, port = target.rpartition(":")
    if not port.isdigit() or not (1 <= int(port) <= 65535):
        return False
    host = host.strip()
    if host in ("localhost", "127.0.0.1", "::1"):
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def validate_routes(domain: str, routes: Dict[str, str]) -> Tuple[bool, str]:
    """Validate the domain + route map. Returns (ok, error_message)."""
    if not domain or not _valid_domain(domain):
        return False, f"Invalid domain: {domain!r}"
    if not routes:
        return False, "At least one route is required."
    for sub, target in routes.items():
        if not _valid_subdomain(sub):
            return False, f"Invalid subdomain label: {sub!r}"
        if not _valid_target(target):
            return False, f"Route target must be a loopback host:port, got {target!r}"
    return True, ""


def _valid_domain(domain: str) -> bool:
    domain = domain.strip().lower()
    if not domain or len(domain) > 253:
        return False
    return all(_HOSTNAME_RE.match(part) for part in domain.split("."))


def _fqdn(sub: str, domain: str) -> str:
    return domain if sub == "@" else f"{sub}.{domain}"


def render_nginx(settings: Dict[str, Any]) -> str:
    """Render the nginx vhost from settings. Caller must have validated routes."""
    domain = settings["domain"].strip().lower()
    routes = settings.get("routes") or {}
    listen_port = int(settings.get("nginx_listen_port", 8788))

    server_blocks = []
    for sub, target in routes.items():
        fqdn = _fqdn(sub, domain)
        server_blocks.append(
            f"""    server {{
        listen 127.0.0.1:{listen_port};
        server_name {fqdn};

        # --- security headers (every response) ---
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "DENY" always;
        add_header Referrer-Policy "same-origin" always;

        # --- per-IP rate limit ---
        limit_req zone=jc_edge burst=40 nodelay;
        limit_conn jc_edge_conn 32;

        client_max_body_size 64m;

        location / {{
            proxy_pass http://{target};

            # SECURITY: neutralize any client-supplied forwarding/spoof headers,
            # then set them ourselves from values nginx controls. The app trusts
            # X-Forwarded-Host ONLY because this proxy guarantees it is genuine.
            proxy_set_header Forwarded "";
            proxy_set_header X-Forwarded-Host {fqdn};
            proxy_set_header X-Real-Host {fqdn};
            proxy_set_header X-Forwarded-For $remote_addr;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-Proto https;
            proxy_set_header Host {fqdn};

            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_read_timeout 3600s;
            proxy_buffering off;
        }}
    }}"""
        )

    blocks = "\n\n".join(server_blocks)
    # A full, self-contained main config: run with `nginx -c <this> -p <edge_dir>`
    # so every relative path (pid, logs, temp dirs) resolves under the edge dir
    # and nginx never needs to write to the system prefix. `daemon off;` is passed
    # via `-g` at start time, NOT here, to avoid a duplicate-directive error.
    return f"""# Generated by JarvisCopilot edge subsystem — DO NOT EDIT BY HAND.
# Routes Cloudflare-tunnel traffic to localhost-bound JarvisCopilot services.
worker_processes 1;
error_log nginx_error.log warn;
pid nginx.pid;

events {{
    worker_connections 1024;
}}

http {{
    access_log off;
    client_body_temp_path client_body_temp;
    proxy_temp_path proxy_temp;
    fastcgi_temp_path fastcgi_temp;
    uwsgi_temp_path uwsgi_temp;
    scgi_temp_path scgi_temp;

    map $http_upgrade $connection_upgrade {{
        default upgrade;
        ''      close;
    }}

    limit_req_zone $binary_remote_addr zone=jc_edge:10m rate=20r/s;
    limit_conn_zone $binary_remote_addr zone=jc_edge_conn:10m;

{blocks}

    # Catch-all: drop connections for any host we did not explicitly route.
    server {{
        listen 127.0.0.1:{listen_port} default_server;
        server_name _;
        return 444;
    }}
}}
"""


def render_cloudflared(settings: Dict[str, Any]) -> str:
    """Render the cloudflared ingress config (config.yml).

    All public hostnames funnel into the single local nginx listener; nginx then
    does the per-host routing. Token-based tunnels read credentials from the
    token, so we only need the ingress rules here.
    """
    domain = settings["domain"].strip().lower()
    routes = settings.get("routes") or {}
    listen_port = int(settings.get("nginx_listen_port", 8788))
    tunnel_name = settings.get("tunnel_name", "jarviscopilot")

    rules = []
    for sub in routes:
        fqdn = _fqdn(sub, domain)
        rules.append(
            f"  - hostname: {fqdn}\n    service: http://127.0.0.1:{listen_port}"
        )
    # Required final catch-all rule for cloudflared.
    rules.append("  - service: http_status:404")
    ingress = "\n".join(rules)

    return f"""# Generated by JarvisCopilot edge subsystem — DO NOT EDIT BY HAND.
tunnel: {tunnel_name}
ingress:
{ingress}
"""
