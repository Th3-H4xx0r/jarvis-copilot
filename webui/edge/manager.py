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

        # 1. WebUI must be bound to loopback so nginx is the only ingress.
        host = (os.getenv("HERMES_WEBUI_HOST") or "127.0.0.1").strip().lower()
        loopback = host in ("127.0.0.1", "::1", "localhost")
        checks.append({
            "name": "origin_bound_to_loopback",
            "ok": loopback,
            "detail": f"HERMES_WEBUI_HOST={host}"
            + ("" if loopback else " — bind to 127.0.0.1 so only nginx can reach the WebUI"),
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
            st = installer.install(tool)
            return {"ok": st.installed, "tool": st.__dict__}

    def configure(self, body: Dict[str, Any]) -> Dict[str, Any]:
        """Persist settings + token. Validates routes before saving."""
        with self._lock:
            updates = {k: v for k, v in body.items() if k != "token"}
            if "domain" in updates or "routes" in updates:
                domain = updates.get("domain", state.load_settings().get("domain", ""))
                routes = updates.get("routes", state.load_settings().get("routes", {}))
                ok, msg = config_render.validate_routes(domain, routes)
                if not ok:
                    return {"ok": False, "error": msg}
            new_settings = state.save_settings(updates)
            if "token" in body:
                state.set_token(body.get("token") or "")
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
