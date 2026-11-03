"""Steel cloud browser provider — plugin form.

Steel (https://steel.dev) runs real Chrome in the cloud and gives every session a
live view that can be embedded read-only or interactive, which is what the chat's
browser card shows (watch, take over, hand back).

REST (https://api.steel.dev/v1, header ``Steel-Api-Key``)::

    POST /sessions                  → {id, websocketUrl, debugUrl, sessionViewerUrl, ...}
    POST /sessions/{id}/release     → {success, ...}

CDP: ``websocketUrl`` from the create reply, or
``wss://connect.steel.dev?apiKey=<key>&sessionId=<id>``; the key is added when the
reply's URL doesn't carry it.

Live view: ``debugUrl`` + ``?interactive=false`` (watch) or
``?interactive=true&showControls=true`` (take over). Steel does not authenticate
debug URLs, so they only ever leave the server through the signed-in web/phone API.

Config::

    browser:
      cloud_provider: "steel"

Env::

    STEEL_API_KEY=...                 # Settings → Providers → Tool keys
    STEEL_BASE_URL=...                # default https://api.steel.dev/v1
    STEEL_SESSION_TIMEOUT_MS=900000   # default 15 min (the free plan's maximum)
    STEEL_SOLVE_CAPTCHA=false
    STEEL_BLOCK_ADS=true
"""

from __future__ import annotations

import logging
import os
import uuid
from typing import Any, Dict, Optional
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

import httpx

from agent.browser_provider import BrowserProvider

logger = logging.getLogger(__name__)

_DEFAULT_BASE_URL = "https://api.steel.dev/v1"
_CONNECT_URL = "wss://connect.steel.dev"
_DEFAULT_TIMEOUT_MS = 15 * 60 * 1000


def _with_query(url: str, **params: str) -> str:
    """``url`` with ``params`` set in its query string (existing keys replaced)."""
    parts = urlsplit(url)
    query = dict(parse_qsl(parts.query, keep_blank_values=True))
    query.update(params)
    return urlunsplit((parts.scheme, parts.netloc, parts.path, urlencode(query), parts.fragment))


def _env_flag(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


class SteelBrowserProvider(BrowserProvider):
    """Steel cloud browser backend with a live view."""

    @property
    def name(self) -> str:
        return "steel"

    @property
    def display_name(self) -> str:
        return "Steel"

    def is_available(self) -> bool:
        return bool(self._api_key())

    # ------------------------------------------------------------------
    # Config
    # ------------------------------------------------------------------

    @staticmethod
    def _api_key() -> str:
        return (os.environ.get("STEEL_API_KEY") or "").strip()

    @staticmethod
    def _base_url() -> str:
        return (os.environ.get("STEEL_BASE_URL") or _DEFAULT_BASE_URL).strip().rstrip("/")

    def _headers(self) -> Dict[str, str]:
        key = self._api_key()
        if not key:
            raise ValueError("Steel needs STEEL_API_KEY (Settings → Providers → Tool keys).")
        return {"Steel-Api-Key": key, "Content-Type": "application/json"}

    @staticmethod
    def _timeout_ms() -> int:
        raw = (os.environ.get("STEEL_SESSION_TIMEOUT_MS") or "").strip()
        try:
            value = int(raw) if raw else _DEFAULT_TIMEOUT_MS
        except ValueError:
            logger.warning("Invalid STEEL_SESSION_TIMEOUT_MS %r; using the default", raw)
            value = _DEFAULT_TIMEOUT_MS
        return value if value > 0 else _DEFAULT_TIMEOUT_MS

    # ------------------------------------------------------------------
    # URLs
    # ------------------------------------------------------------------

    def cdp_url_for(self, data: Dict[str, Any]) -> str:
        """The CDP websocket for a create reply, carrying the API key."""
        key = self._api_key()
        session_id = str(data.get("id") or "")
        ws = str(data.get("websocketUrl") or "").strip()
        if not ws:
            return _with_query(_CONNECT_URL, apiKey=key, sessionId=session_id)
        if "apiKey=" not in ws:
            ws = _with_query(ws, apiKey=key)
        return ws

    @staticmethod
    def live_urls_for(data: Dict[str, Any]) -> Dict[str, Optional[str]]:
        """Read-only and interactive live-view URLs (None when Steel gave none)."""
        base = str(data.get("debugUrl") or data.get("debuggerUrl") or "").strip()
        if base:
            return {
                "live_url": _with_query(base, interactive="false", showControls="false"),
                "live_interactive_url": _with_query(base, interactive="true", showControls="true"),
            }
        viewer = str(data.get("sessionViewerUrl") or "").strip() or None
        return {"live_url": viewer, "live_interactive_url": None}

    # ------------------------------------------------------------------
    # Session lifecycle
    # ------------------------------------------------------------------

    def create_session(self, task_id: str) -> Dict[str, object]:
        headers = self._headers()
        body: Dict[str, Any] = {
            "timeout": self._timeout_ms(),
            "blockAds": _env_flag("STEEL_BLOCK_ADS", True),
            "solveCaptcha": _env_flag("STEEL_SOLVE_CAPTCHA", False),
            "dimensions": {"width": 1280, "height": 800},
        }
        try:
            response = httpx.post(f"{self._base_url()}/sessions", headers=headers, json=body, timeout=30)
        except httpx.HTTPError as exc:
            raise RuntimeError(f"Steel API connection failed: {exc}") from exc
        if response.status_code >= 400:
            raise RuntimeError(
                f"Failed to create Steel session: {response.status_code} {response.text[:300]}"
            )
        data = response.json()
        if not isinstance(data, dict) or not data.get("id"):
            raise RuntimeError(f"Steel returned no session id: {str(data)[:200]}")

        live = self.live_urls_for(data)
        session_name = f"steel_{task_id}_{uuid.uuid4().hex[:8]}"
        logger.info("Created Steel session %s (%s)", data["id"], session_name)
        return {
            "session_name": session_name,
            "bb_session_id": str(data["id"]),
            "cdp_url": self.cdp_url_for(data),
            "features": {"steel": True, "live_view": bool(live["live_url"])},
            "live_url": live["live_url"],
            "live_interactive_url": live["live_interactive_url"],
            "viewer_url": data.get("sessionViewerUrl"),
        }

    def _release(self, session_id: str, timeout: float) -> bool:
        response = httpx.post(
            f"{self._base_url()}/sessions/{session_id}/release",
            headers=self._headers(),
            json={},
            timeout=timeout,
        )
        if response.status_code in {200, 201, 204}:
            return True
        logger.warning(
            "Failed to release Steel session %s: HTTP %s - %s",
            session_id, response.status_code, response.text[:200],
        )
        return False

    def close_session(self, session_id: str) -> bool:
        if not self._api_key():
            logger.warning("Cannot release Steel session %s — no STEEL_API_KEY", session_id)
            return False
        try:
            return self._release(session_id, timeout=10)
        except Exception as exc:
            logger.error("Exception releasing Steel session %s: %s", session_id, exc)
            return False

    def emergency_cleanup(self, session_id: str) -> None:
        if not self._api_key():
            return
        try:
            self._release(session_id, timeout=5)
        except Exception as exc:
            logger.debug("Emergency release of Steel session %s failed: %s", session_id, exc)

    def get_setup_schema(self) -> Dict[str, Any]:
        return {
            "name": "Steel",
            "badge": "free tier",
            "tag": "Cloud Chrome with a live view you can watch and take over",
            "env_vars": [
                {
                    "key": "STEEL_API_KEY",
                    "prompt": "Steel API key",
                    "url": "https://app.steel.dev",
                },
            ],
            "post_setup": "agent_browser",
        }
