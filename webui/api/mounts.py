"""Feature routers, each mounted once by path prefix for every HTTP method.

A mounted module exposes ``route(req)``. It returns False when the path is not
one of its own (the dispatcher then carries on to the routes in api/routes.py,
and finally a 404); anything else means it answered. Prefixes here own their
whole subtree, so the order of this list does not matter.
"""
import importlib
from functools import cached_property
from urllib.parse import parse_qs

from api import helpers
from api.helpers import j

MOUNTS = (
    ("/ota", "api.app_updates"),
    ("/api/app-updates", "api.app_updates"),
    ("/api/agent-notes", "api.agent_notes_routes"),
    ("/api/browser", "api.browser_routes"),
    ("/api/cache", "api.cache_config"),
    ("/api/car", "api.car_routes"),
    ("/api/coding", "api.coding_routes"),
    ("/api/compression", "api.compression_config"),
    ("/api/dashcam", "api.dashcam_routes"),
    ("/api/devices", "api.devices_routes"),
    ("/api/door", "api.door_routes"),
    ("/api/edge", "api.edge"),
    ("/api/harnesses", "api.harness_routes"),
    ("/api/island", "api.island_routes"),
    ("/api/jarvis-memory", "api.jarvis_memory_routes"),
    ("/api/kanban", "api.kanban_bridge"),
    ("/api/live", "api.live_ws"),
    ("/api/screen", "api.screen_share"),
    ("/api/speech", "api.speech_config"),
    ("/api/voice", "api.voice"),
    ("/api/widgets", "api.widget_routes"),
)


class Request:
    """One HTTP request as a mounted feature sees it. Everything is computed on first use."""

    def __init__(self, handler, parsed, method: str, prefix: str = ""):
        self.handler = handler
        self.parsed = parsed
        self.method = method
        self.prefix = prefix
        self.path = parsed.path

    @property
    def sub(self) -> str:
        """The path below the mount's prefix, e.g. ``/approver/button``."""
        return self.path[len(self.prefix):]

    @property
    def sub_with_query(self) -> str:
        return self.sub + (f"?{self.parsed.query}" if self.parsed.query else "")

    @cached_property
    def query(self) -> dict:
        return parse_qs(self.parsed.query)

    @cached_property
    def body(self):
        """The JSON body; read once and shared with api/routes.py. GET has none.

        Routes that stream a raw body (uploads) read ``handler.rfile`` themselves
        and never touch this."""
        return None if self.method == "GET" else helpers.read_body(self.handler)

    @cached_property
    def host_signed(self) -> bool:
        """Came over the host-signed loopback: the agent's own side, not a device."""
        from api.auth import check_host_signature
        return check_host_signature(self.handler)

    @cached_property
    def device(self) -> dict | None:
        """The paired device whose session cookie made this request, if any."""
        from api.auth import parse_cookie
        from api.pairing import find_device_by_session
        return find_device_by_session(parse_cookie(self.handler) or "")

    def reply(self, status: int, payload) -> bool:
        j(self.handler, payload, status=status)
        return True


def _owner(path: str):
    for prefix, module in MOUNTS:
        if path == prefix or path.startswith(prefix + "/"):
            return prefix, module
    return None, None


def dispatch(req: Request) -> bool:
    prefix, module = _owner(req.path)
    if module is None:
        return False
    req.prefix = prefix
    # Only False means "not mine": a route that replied may return None (j() does), as
    # server.py treats every handle_* result.
    return importlib.import_module(module).route(req) is not False
