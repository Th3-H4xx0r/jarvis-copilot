"""Photon: Jarvis on iMessage through photon.codes — messages in and out, alerts,
coding notifications.

Off: the gateway's Photon adapter is disconnected (and not started at boot), sends
through Photon are refused, and its setup screens hide. Its PHOTON_* keys stay.
"""
from __future__ import annotations

import asyncio
import logging
import os

from jarvis_power import PowerIntegration, Setting

logger = logging.getLogger(__name__)
_SECRET = {"PHOTON_PROJECT_SECRET", "PHOTON_SIDECAR_TOKEN"}
_FIELDS = (
    ("PHOTON_PROJECT_ID", "Project ID"),
    ("PHOTON_PROJECT_SECRET", "Project secret"),
    ("PHOTON_NOTIFY_TARGET", "Your iMessage handle"),
    ("PHOTON_SIDECAR_URL", "Sidecar URL"),
    ("PHOTON_SIDECAR_TOKEN", "Sidecar token"),
    ("PHOTON_ALLOWED_USERS", "Allowed senders"),
)


class Photon(PowerIntegration):
    id = "photon"
    name = "Photon"
    icon = "message.fill"
    summary = "Jarvis on iMessage: messages in and out, alerts and coding notifications."
    processes = ("gateway",)
    route_prefixes = ("/api/integrations/photon",)
    surfaces = ("ios.more.photon", "web.settings.photon", "mac.settings.photon")
    # App only: the sidecar URL, allowed senders and handle decide who reaches Jarvis.
    settings = tuple(Setting(key, label, "secret" if key in _SECRET else "text", default="",
                             jarvis="never")
                     for key, label in _FIELDS)

    def read_settings(self) -> dict:
        from jarvis_power.stores import env_get
        return {key: env_get(key) or "" for key, _ in _FIELDS}

    def write_settings(self, changes: dict) -> None:
        from jarvis_power.stores import env_set
        for key, value in changes.items():
            env_set(key, value or None)

    def status_line(self) -> str:
        target = os.getenv("PHOTON_NOTIFY_TARGET", "").strip()
        return f"Messages {target}" if target else "No iMessage handle set"

    def state(self) -> dict:
        handle = os.getenv("PHOTON_NOTIFY_TARGET", "").strip()
        return {"status": self.status_line(), "handle": handle or "Not set"}

    # ── the gateway adapter ─────────────────────────────────────────────────
    def _runner_and_loop(self):
        from gateway.run import _gateway_runner_ref
        from jarvis_power.manager import manager_for
        return _gateway_runner_ref(), manager_for("gateway").loop

    def stop(self, process: str) -> None:
        from gateway.config import Platform
        runner, loop = self._runner_and_loop()
        if runner is None or loop is None:
            return
        platform = Platform("photon")

        async def detach():
            runner._failed_platforms.pop(platform, None)
            adapter = runner.adapters.pop(platform, None)
            runner.delivery_router.adapters = runner.adapters
            if adapter is not None:
                await adapter.disconnect()

        asyncio.run_coroutine_threadsafe(detach(), loop).result(timeout=30)

    def start(self, process: str) -> None:
        from gateway.config import Platform, load_gateway_config
        runner, loop = self._runner_and_loop()
        platform = Platform("photon")
        if runner is None or loop is None:
            return
        if platform in runner.adapters or platform in runner._failed_platforms:
            return                                # connected, or the reconnect watcher owns it
        pconfig = load_gateway_config().platforms.get(platform)
        if pconfig is None or not pconfig.enabled:
            return                                # not configured: nothing to connect

        async def attach() -> bool:
            adapter = runner._create_adapter(platform, pconfig)
            if adapter is None:
                return True
            adapter.set_message_handler(runner._handle_message)
            adapter.set_fatal_error_handler(runner._handle_adapter_fatal_error)
            adapter.set_session_store(runner.session_store)
            adapter.set_busy_session_handler(runner._handle_active_session_busy_message)
            adapter.set_session_liveness_check(runner._running_agent_is_stale)
            if not await runner._connect_adapter_with_timeout(adapter, platform):
                return False
            runner.adapters[platform] = adapter
            runner.delivery_router.adapters = runner.adapters
            return True

        if not asyncio.run_coroutine_threadsafe(attach(), loop).result(timeout=90):
            raise RuntimeError("the Photon sidecar didn't connect")
