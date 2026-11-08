"""Tests for _send_homeassistant."""

import asyncio
import os
from unittest.mock import AsyncMock, MagicMock, patch

from tools.send_message_tool import (
    _send_homeassistant,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_aiohttp_resp(status, json_data=None, text_data=None):
    """Build a minimal async-context-manager mock for an aiohttp response."""
    resp = AsyncMock()
    resp.status = status
    resp.json = AsyncMock(return_value=json_data or {})
    resp.text = AsyncMock(return_value=text_data or "")
    return resp


def _make_aiohttp_session(resp):
    """Wrap a response mock in a session mock that supports async-with for post/put."""
    request_ctx = MagicMock()
    request_ctx.__aenter__ = AsyncMock(return_value=resp)
    request_ctx.__aexit__ = AsyncMock(return_value=False)

    session = MagicMock()
    session.post = MagicMock(return_value=request_ctx)
    session.put = MagicMock(return_value=request_ctx)

    session_ctx = MagicMock()
    session_ctx.__aenter__ = AsyncMock(return_value=session)
    session_ctx.__aexit__ = AsyncMock(return_value=False)
    return session_ctx, session


# ---------------------------------------------------------------------------
# _send_homeassistant
# ---------------------------------------------------------------------------


class TestSendHomeAssistant:
    def test_success(self):
        resp = _make_aiohttp_resp(200)
        session_ctx, session = _make_aiohttp_session(resp)

        with patch("aiohttp.ClientSession", return_value=session_ctx), \
             patch.dict(os.environ, {"HASS_URL": "", "HASS_TOKEN": ""}, clear=False):
            extra = {"url": "https://hass.example.com"}
            result = asyncio.run(_send_homeassistant("hass-tok", extra, "mobile_app_phone", "alert!"))

        assert result == {"success": True, "platform": "homeassistant", "chat_id": "mobile_app_phone"}
        session.post.assert_called_once()
        call_kwargs = session.post.call_args
        assert call_kwargs[0][0] == "https://hass.example.com/api/services/notify/notify"
        assert call_kwargs[1]["headers"]["Authorization"] == "Bearer hass-tok"
        assert call_kwargs[1]["json"] == {"message": "alert!", "target": "mobile_app_phone"}

    def test_http_error(self):
        resp = _make_aiohttp_resp(401, text_data="Unauthorized")
        session_ctx, _ = _make_aiohttp_session(resp)

        with patch("aiohttp.ClientSession", return_value=session_ctx):
            result = asyncio.run(_send_homeassistant(
                "bad-tok", {"url": "https://hass.example.com"},
                "target", "msg"
            ))

        assert "error" in result
        assert "401" in result["error"]
        assert "Unauthorized" in result["error"]

    def test_missing_config(self):
        with patch.dict(os.environ, {"HASS_URL": "", "HASS_TOKEN": ""}, clear=False):
            result = asyncio.run(_send_homeassistant("", {}, "target", "msg"))

        assert "error" in result
        assert "HASS_URL" in result["error"] or "not configured" in result["error"]

    def test_env_var_fallback(self):
        resp = _make_aiohttp_resp(200)
        session_ctx, session = _make_aiohttp_session(resp)

        with patch("aiohttp.ClientSession", return_value=session_ctx), \
             patch.dict(os.environ, {"HASS_URL": "https://hass.env.com", "HASS_TOKEN": "env-tok"}, clear=False):
            result = asyncio.run(_send_homeassistant("", {}, "notify_target", "hi"))

        assert result["success"] is True
        url = session.post.call_args[0][0]
        assert "hass.env.com" in url
