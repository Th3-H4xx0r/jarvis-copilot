"""Orchestration + the safety gate for the edge subsystem.

``EdgeManager`` ties together state, config rendering, installation, and process
supervision, and exposes the high-level operations the API layer calls:
``status`` / ``configure`` / ``enable`` / ``disable`` / ``install`` / ``logs``.

The safety gate (:meth:`preflight`) is the reason exposure code lives next to
the security fixes: the tunnel will not come UP unless the origin is in a safe
state (bound to loopback, the forwarded-host CSRF fix present, nginx config
valid). This implements the operator's "hard gate on exposure" decision.
"""
from __future__ import annotations

import os
import threading
from pathlib import Path
from typing import Any, Dict, List

from . import config_render, installer, state, supervisor


class EdgeManager:
    def __init__(self) -> None:
        self._lock = threading.RLock()

    # ── paths ────────────────────────────────────────────────────────────────
    def _nginx_conf(self) -> Path:
        return state._edge_dir() / "nginx.conf"

    def _cloudflared_conf(self) -> Path:
        return state._edge_dir() / "cloudflared.yml"

    # ── preflight safety gate ─────────────────────────────────────────────────
    def preflight(self) -> Dict[str, Any]:
        """Return {ok, checks:[{name, ok, detail}]}. ok=False blocks 'enable'."""
        checks: List[Dict[str, Any]] = []

        # 1. WebUI must be bound to loopback so nginx is the only ingress — OR
        #    the operator has acknowledged the origin is otherwise protected
        #    (e.g. a container with no published ports / a host firewall).
        host = (os.getenv("HERMES_WEBUI_HOST") or "127.0.0.1").strip().lower()
        loopback = host in ("127.0.0.1", "::1", "localhost")
        acked = bool(state.load_settings().get("loopback_ack"))
        if loopback:
            detail = f"HERMES_WEBUI_HOST={host}"
        elif acked:
            detail = f"HERMES_WEBUI_HOST={host} — acknowledged as protected (container/firewall)"
        else:
            detail = (f"HERMES_WEBUI_HOST={host} — bind to 127.0.0.1 so only nginx can reach "
                      "the WebUI, or acknowledge it's protected by your container/firewall")
        checks.append({
            "name": "origin_bound_to_loopback",
            "ok": loopback or acked,
            "detail": detail,
            # let the UI offer a one-click ack only when this is the blocker
            "ackable": (not loopback) and (not acked),
        })

        # 2. The forwarded-host CSRF fix must be present in routes.py (the proxy
        #    sets X-Forwarded-Host; the app must only trust it on opt-in).
        fix_present = self._csrf_fix_present()
        checks.append({
            "name": "forwarded_host_csrf_fix",
            "ok": fix_present,
            "detail": "routes._check_csrf gates X-Forwarded-Host on HERMES_WEBUI_TRUST_FORWARDED_HOST"
            if fix_present else "CSRF fix not detected in webui/api/routes.py",
        })

        # 3. Domain + routes configured and valid.
        s = state.load_settings()
        ok_routes, msg = config_render.validate_routes(s.get("domain", ""), s.get("routes", {}))
        checks.append({
            "name": "routes_valid",
            "ok": ok_routes,
            "detail": msg or "domain + routes valid",
        })

        # 4. Token present.
        checks.append({
            "name": "tunnel_token_set",
            "ok": state.has_token(),
            "detail": "token configured" if state.has_token() else "paste the cloudflared tunnel token",
        })

        return {"ok": all(c["ok"] for c in checks), "checks": checks}

    @staticmethod
    def _csrf_fix_present() -> bool:
        try:
            routes = Path(__file__).resolve().parent.parent / "api" / "routes.py"
            txt = routes.read_text(encoding="utf-8", errors="replace")
            return "HERMES_WEBUI_TRUST_FORWARDED_HOST" in txt
        except OSError:
            return False

    # ── status ────────────────────────────────────────────────────────────────
    def status(self) -> Dict[str, Any]:
        with self._lock:
            return {
                "settings": state.public_settings(),
                "tools": {
                    "cloudflared": installer.status("cloudflared").__dict__,
                    "nginx": installer.status("nginx").__dict__,
                },
                "processes": {
                    "cloudflared": supervisor.proc_status("cloudflared").__dict__,
                    "nginx": supervisor.proc_status("nginx").__dict__,
                },
                "preflight": self.preflight(),
            }

    # ── operations ─────────────────────────────────────────────────────────────
    def install(self, tool: str) -> Dict[str, Any]:
        with self._lock:
            try:
                st = installer.install(tool)
            except Exception as exc:
                # Surface the reason (no package manager, sudo needed, download
                # failed, …) to the UI instead of a generic 500 — the operator
                # may only be able to debug this through the web panel.
                return {"ok": False, "error": str(exc), "tool": installer.status(tool).__dict__}
            return {"ok": st.installed, "tool": st.__dict__}

    def configure(self, body: Dict[str, Any]) -> Dict[str, Any]:
        """Persist settings + secrets. Validates routes before saving.

        Secret fields (``token``, ``cf_service_client_secret``) are written to
        their 0600 files, NOT the settings json. ``cf_service_client_id`` is a
        non-secret settings field.
        """
        with self._lock:
            _SECRET_KEYS = {"token", "cf_service_client_secret"}
            updates = {k: v for k, v in body.items() if k not in _SECRET_KEYS}
            if "domain" in updates or "routes" in updates:
                domain = updates.get("domain", state.load_settings().get("domain", ""))
                routes = updates.get("routes", state.load_settings().get("routes", {}))
                ok, msg = config_render.validate_routes(domain, routes)
                if not ok:
                    return {"ok": False, "error": msg}
            new_settings = state.save_settings(updates)
            if "token" in body:
                state.set_token(body.get("token") or "")
            if "cf_service_client_secret" in body:
                state.set_cf_service_secret(body.get("cf_service_client_secret") or "")
            # Clearing the client id disables the token — drop the orphan secret
            # file too so no dead secret lingers on disk.
            if "cf_service_client_id" in updates and not updates.get("cf_service_client_id"):
                state.set_cf_service_secret("")
            return {"ok": True, "settings": state.public_settings(), "_raw": new_settings}

    def _write_configs(self) -> None:
        s = state.load_settings()
        self._nginx_conf().write_text(config_render.render_nginx(s), encoding="utf-8")
        self._cloudflared_conf().write_text(config_render.render_cloudflared(s), encoding="utf-8")

    def enable(self) -> Dict[str, Any]:
        """Safety-gated bring-up: preflight → render → nginx -t → start both."""
        with self._lock:
            pf = self.preflight()
            if not pf["ok"]:
                failed = [c for c in pf["checks"] if not c["ok"]]
                return {"ok": False, "error": "preflight failed", "checks": failed}

            self._write_configs()

            ok, out = supervisor.test_nginx(str(self._nginx_conf()))
            if not ok:
                return {"ok": False, "error": "nginx config test failed", "detail": out}

            supervisor.start_nginx(str(self._nginx_conf()))
            supervisor.start_cloudflared(str(self._cloudflared_conf()), state.get_token())
            state.save_settings({"enabled": True})
            return {"ok": True, "status": self.status()}

    def disable(self) -> Dict[str, Any]:
        with self._lock:
            supervisor.stop("cloudflared")
            supervisor.stop("nginx")
            state.save_settings({"enabled": False})
            return {"ok": True, "status": self.status()}

    def autostart_if_enabled(self) -> Dict[str, Any]:
        """Re-launch nginx + cloudflared on server startup if the tunnel was
        left enabled (settings.enabled) and they aren't already running.

        Process state lives in pidfiles, not across reboots, so without this the
        tunnel silently stays down after a server restart. Best-effort: never
        raises (startup must not be blocked).
        """
        with self._lock:
            s = state.load_settings()
            if not s.get("enabled"):
                return {"ok": True, "skipped": "not enabled"}
            started = []
            try:
                ok_routes, _ = config_render.validate_routes(s.get("domain", ""), s.get("routes", {}))
                if not ok_routes:
                    return {"ok": False, "error": "routes invalid; not autostarting"}
                self._write_configs()
                if not supervisor.proc_status("nginx").running:
                    ok, out = supervisor.test_nginx(str(self._nginx_conf()))
                    if not ok:
                        return {"ok": False, "error": "nginx config test failed", "detail": out}
                    supervisor.start_nginx(str(self._nginx_conf()))
                    started.append("nginx")
                if state.has_token() and not supervisor.proc_status("cloudflared").running:
                    supervisor.start_cloudflared(str(self._cloudflared_conf()), state.get_token())
                    started.append("cloudflared")
            except Exception as exc:
                return {"ok": False, "error": str(exc), "started": started}
            return {"ok": True, "started": started}

    def start_service(self, name: str) -> Dict[str, Any]:
        """Start a single service (nginx or cloudflared) from the UI.

        Renders fresh configs first. nginx is config-tested before start;
        cloudflared requires a token. Routes must be valid for either.
        """
        if name not in ("nginx", "cloudflared"):
            return {"ok": False, "error": "unknown service"}
        with self._lock:
            s = state.load_settings()
            ok_routes, msg = config_render.validate_routes(s.get("domain", ""), s.get("routes", {}))
            if not ok_routes:
                return {"ok": False, "error": msg}
            self._write_configs()
            try:
                if name == "nginx":
                    ok, out = supervisor.test_nginx(str(self._nginx_conf()))
                    if not ok:
                        return {"ok": False, "error": "nginx config test failed", "detail": out}
                    supervisor.start_nginx(str(self._nginx_conf()))
                else:
                    if not state.has_token():
                        return {"ok": False, "error": "paste the cloudflared tunnel token first"}
                    supervisor.start_cloudflared(str(self._cloudflared_conf()), state.get_token())
            except Exception as exc:
                return {"ok": False, "error": str(exc)}
            # Mark the tunnel "enabled" so it auto-starts after a server restart.
            # Starting EITHER service via the UI counts as intent-to-run; without
            # this, per-service Start didn't set enabled and autostart was skipped.
            state.save_settings({"enabled": True})
            return {"ok": True, "status": self.status()}

    def stop_service(self, name: str) -> Dict[str, Any]:
        if name not in ("nginx", "cloudflared"):
            return {"ok": False, "error": "unknown service"}
        with self._lock:
            supervisor.stop(name)
            # If BOTH services are now stopped, clear the enabled flag so we don't
            # auto-resurrect a tunnel the operator deliberately took fully down.
            other = "cloudflared" if name == "nginx" else "nginx"
            if not supervisor.proc_status(other).running:
                state.save_settings({"enabled": False})
            return {"ok": True, "status": self.status()}

    def cf_service_token_for_pairing(self) -> Dict[str, str]:
        """Return {client_id, client_secret} to embed in a pairing payload.

        Both empty when unconfigured — pairing then omits the field.
        """
        return state.get_cf_service_token()

    def diagnose(self) -> Dict[str, Any]:
        """Self-test the routing chain from INSIDE the container (where loopback
        works), since the operator usually can't shell in.

        Checks, in order: nginx listening on its loopback port → nginx /healthz
        responds → each route's app target accepts a connection. Returns a list
        of {name, ok, detail} so the UI can show exactly where the chain breaks.
        """
        import socket
        import http.client

        s = state.load_settings()
        port = int(s.get("nginx_listen_port", 8788))
        routes = s.get("routes") or {}
        checks: List[Dict[str, Any]] = []

        def tcp_ok(host: str, p: int, timeout: float = 2.0) -> bool:
            try:
                with socket.create_connection((host, p), timeout=timeout):
                    return True
            except OSError:
                return False

        # 1. nginx process + listener (IPv4)
        ng_running = supervisor.proc_status("nginx").running
        listening = tcp_ok("127.0.0.1", port)
        checks.append({
            "name": "nginx_listening",
            "ok": ng_running and listening,
            "detail": (f"127.0.0.1:{port} accepting connections" if listening
                       else f"nothing accepting on 127.0.0.1:{port}"
                       + ("" if ng_running else " (nginx process not running — Start it)")),
        })

        # 1b. nginx must ALSO answer on the IPv6 loopback. cloudflared's service
        #     URL uses "localhost", which often resolves to ::1 first — if nginx
        #     only bound 127.0.0.1 the tunnel 502s ("Host Error") even though the
        #     IPv4 check above is green. This check catches that mismatch.
        v6 = tcp_ok("::1", port)
        # localhost as cloudflared actually resolves it (whichever family wins)
        try:
            lh = tcp_ok("localhost", port)
        except OSError:
            lh = False
        checks.append({
            "name": "nginx_localhost_ipv6",
            "ok": (v6 or lh),
            "detail": (f"localhost:{port} reachable (cloudflared uses this)" if (v6 or lh)
                       else f"[::1]:{port} refused — cloudflared connects to localhost (often IPv6) "
                            f"and will 502. Restart nginx so it binds the new [::1] listener."),
        })

        # 2. nginx /healthz answers (proves nginx itself is serving)
        health_ok, health_detail = False, "could not reach nginx /healthz"
        if listening:
            try:
                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
                conn.request("GET", "/healthz")
                resp = conn.getresponse()
                body = resp.read(200).decode("utf-8", "replace").strip()
                health_ok = resp.status == 200
                health_detail = f"HTTP {resp.status}: {body}" if health_ok else f"HTTP {resp.status}"
                conn.close()
            except Exception as exc:
                health_detail = str(exc)
        checks.append({"name": "nginx_healthz", "ok": health_ok, "detail": health_detail})

        # 2b. END-TO-END: replicate cloudflared's EXACT request — GET / to nginx
        #     with Host: <route fqdn> — which hits the route server block and its
        #     proxy_pass to the app (NOT the catch-all /healthz). This is what a
        #     502 "Host Error" actually exercises. Any 2xx/3xx/4xx from nginx
        #     means the chain works (the app answered); a 502 here means nginx
        #     couldn't reach the app upstream.
        domain = (s.get("domain") or "").strip().lower()
        for sub in (routes or {}):
            fqdn = domain if sub == "@" else f"{sub}.{domain}"
            e2e_ok, e2e_detail = False, "could not reach nginx"
            if listening:
                try:
                    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
                    conn.request("GET", "/", headers={"Host": fqdn})
                    resp = conn.getresponse()
                    resp.read(200)
                    # nginx reached the app for anything that isn't a gateway error.
                    e2e_ok = resp.status not in (502, 503, 504)
                    e2e_detail = (f"nginx→app returned HTTP {resp.status} (chain works)"
                                  if e2e_ok else
                                  f"nginx returned HTTP {resp.status} — its upstream "
                                  f"{(routes or {}).get(sub)} failed. Is that app serving HTTP on that exact addr? "
                                  f"Check the nginx log below for the connect() error.")
                    conn.close()
                except Exception as exc:
                    e2e_detail = f"{exc} (this is the real failure cloudflared hits)"
            checks.append({"name": f"end_to_end:{fqdn}", "ok": e2e_ok, "detail": e2e_detail})

        # 3. each route's app target reachable (parse optional http(s):// prefix)
        for sub, target in routes.items():
            _scheme, host, tp = config_render._parse_target(target)
            ok = tp.isdigit() and tcp_ok(host or "127.0.0.1", int(tp))
            checks.append({
                "name": f"route:{sub} → {target}",
                "ok": ok,
                "detail": ("app is accepting connections" if ok
                           else f"nothing accepting on {host}:{tp} — is that app running on this host?"),
            })

        # 4. cloudflared running (the public side)
        cf = supervisor.proc_status("cloudflared").running
        checks.append({
            "name": "cloudflared_running",
            "ok": cf,
            "detail": "tunnel connector is up" if cf else "cloudflared not running — Start it",
        })

        hint = ("All green here means the in-container chain works. If "
                "jarvis.<domain> still fails, the issue is on Cloudflare's side: "
                "confirm the Public Hostname points at http://localhost:" + str(port)
                + " and that Access isn't blocking you.")
        return {"ok": all(c["ok"] for c in checks), "checks": checks, "hint": hint}

    def logs(self, name: str, lines: int = 100) -> Dict[str, Any]:
        if name not in ("cloudflared", "nginx"):
            return {"ok": False, "error": "unknown process"}
        return {"ok": True, "name": name, "log": supervisor.tail_log(name, lines)}


_MANAGER: EdgeManager | None = None
_MANAGER_LOCK = threading.Lock()


def get_manager() -> EdgeManager:
    global _MANAGER
    with _MANAGER_LOCK:
        if _MANAGER is None:
            _MANAGER = EdgeManager()
        return _MANAGER
