"""Tests for the Photon (iMessage) platform-plugin adapter.

Loaded via ``_plugin_adapter_loader`` so this lives under
``plugin_adapter_photon`` in ``sys.modules`` and cannot collide with sibling
platform-plugin tests on the same xdist worker. Everything routes through the
``platform_registry`` — the adapter modifies no core files.
"""

from __future__ import annotations

import asyncio
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from gateway.config import PlatformConfig
from tests.gateway._plugin_adapter_loader import load_plugin_adapter

_photon = load_plugin_adapter("photon")

PhotonAdapter = _photon.PhotonAdapter
check_requirements = _photon.check_requirements
validate_config = _photon.validate_config
is_connected = _photon.is_connected
register = _photon.register
_env_enablement = _photon._env_enablement
_standalone_send = _photon._standalone_send
MAX_MESSAGE_LENGTH = _photon.MAX_MESSAGE_LENGTH


def _run(coro):
    return asyncio.get_event_loop().run_until_complete(coro)


@pytest.fixture(autouse=True)
def _clear_photon_env(monkeypatch):
    """Each test starts from a clean Photon environment."""
    for var in (
        "PHOTON_PROJECT_ID", "PHOTON_PROJECT_SECRET", "PHOTON_SIDECAR_URL",
        "PHOTON_SIDECAR_TOKEN", "PHOTON_NOTIFY_TARGET", "PHOTON_HOME_CHANNEL",
        "PHOTON_ALLOWED_USERS", "PHOTON_ALLOW_ALL_USERS",
    ):
        monkeypatch.delenv(var, raising=False)


# ---------------------------------------------------------------------------
# Platform enum + requirements
# ---------------------------------------------------------------------------


def test_platform_enum_resolves_via_plugin_scan():
    from gateway.config import Platform
    p = Platform("photon")
    assert p.value == "photon"
    assert Platform("photon") is p


class TestRequirements:
    def test_false_when_httpx_unavailable(self, monkeypatch):
        monkeypatch.setenv("PHOTON_PROJECT_ID", "pid")
        monkeypatch.setattr(_photon, "HTTPX_AVAILABLE", False)
        assert check_requirements() is False

    def test_false_when_unconfigured(self, monkeypatch):
        monkeypatch.setattr(_photon, "HTTPX_AVAILABLE", True)
        assert check_requirements() is False

    def test_true_with_project_id(self, monkeypatch):
        monkeypatch.setattr(_photon, "HTTPX_AVAILABLE", True)
        monkeypatch.setenv("PHOTON_PROJECT_ID", "pid")
        assert check_requirements() is True

    def test_true_with_sidecar_url_only(self, monkeypatch):
        monkeypatch.setattr(_photon, "HTTPX_AVAILABLE", True)
        monkeypatch.setenv("PHOTON_SIDECAR_URL", "http://127.0.0.1:9999")
        assert check_requirements() is True

    def test_validate_config_from_extra(self):
        assert validate_config(PlatformConfig(enabled=True, extra={})) is False
        assert validate_config(
            PlatformConfig(enabled=True, extra={"project_id": "pid"})
        ) is True

    def test_is_connected_from_env(self, monkeypatch):
        monkeypatch.setenv("PHOTON_PROJECT_ID", "pid")
        assert is_connected(PlatformConfig(enabled=True, extra={})) is True


# ---------------------------------------------------------------------------
# env_enablement
# ---------------------------------------------------------------------------


class TestEnvEnablement:
    def test_none_when_unconfigured(self):
        assert _env_enablement() is None

    def test_seeds_extra_and_home_channel(self, monkeypatch):
        monkeypatch.setenv("PHOTON_PROJECT_ID", "pid")
        monkeypatch.setenv("PHOTON_SIDECAR_TOKEN", "tok")
        monkeypatch.setenv("PHOTON_NOTIFY_TARGET", "+15555550123")
        seed = _env_enablement()
        assert seed["project_id"] == "pid"
        assert seed["sidecar_token"] == "tok"
        assert seed["notify_target"] == "+15555550123"
        assert seed["home_channel"]["chat_id"] == "+15555550123"
        assert seed["sidecar_url"].startswith("http")


# ---------------------------------------------------------------------------
# Adapter outbound
# ---------------------------------------------------------------------------


class TestAdapterSend:
    def _make_adapter(self, **extra):
        base = {"sidecar_url": "http://127.0.0.1:8787", "sidecar_token": "tok"}
        base.update(extra)
        return PhotonAdapter(PlatformConfig(enabled=True, extra=base))

    def test_send_fails_without_http_client(self):
        adapter = self._make_adapter()
        result = _run(adapter.send("+15555550123", "hi"))
        assert result.success is False

    def test_send_posts_to_sidecar(self):
        adapter = self._make_adapter()
        mock_resp = MagicMock(status_code=200)
        mock_resp.json.return_value = {"id": "m1"}
        adapter._http_client = AsyncMock()
        adapter._http_client.post = AsyncMock(return_value=mock_resp)

        result = _run(adapter.send("+15555550123", "Hello iMessage!"))
        assert result.success is True
        assert result.message_id == "m1"
        url = adapter._http_client.post.call_args[0][0]
        body = adapter._http_client.post.call_args.kwargs["json"]
        assert url.endswith("/send")
        assert body["address"] == "+15555550123"
        assert body["text"] == "Hello iMessage!"
        # Auth token rides as a header.
        assert adapter._http_client.post.call_args.kwargs["headers"]["X-Photon-Token"] == "tok"

    def test_send_uses_notify_target_when_chat_id_blank(self):
        adapter = self._make_adapter(notify_target="+15555550999")
        mock_resp = MagicMock(status_code=200)
        mock_resp.json.return_value = {}
        adapter._http_client = AsyncMock()
        adapter._http_client.post = AsyncMock(return_value=mock_resp)

        result = _run(adapter.send("", "ping"))
        assert result.success is True
        body = adapter._http_client.post.call_args.kwargs["json"]
        assert body["address"] == "+15555550999"

    def test_send_image_posts_attachment(self):
        adapter = self._make_adapter()
        mock_resp = MagicMock(status_code=200)
        mock_resp.json.return_value = {"id": "img1"}
        adapter._http_client = AsyncMock()
        adapter._http_client.post = AsyncMock(return_value=mock_resp)

        result = _run(adapter.send_image("+15555550123", "https://x/y.png", "caption"))
        assert result.success is True
        body = adapter._http_client.post.call_args.kwargs["json"]
        assert body["attachments"][0]["url"] == "https://x/y.png"
        assert body["text"] == "caption"

    def test_send_handles_http_error(self):
        adapter = self._make_adapter()
        mock_resp = MagicMock(status_code=500)
        mock_resp.text = "boom"
        adapter._http_client = AsyncMock()
        adapter._http_client.post = AsyncMock(return_value=mock_resp)

        result = _run(adapter.send("+15555550123", "hi"))
        assert result.success is False
        assert "500" in result.error

    def test_send_image_accepts_base_kwargs(self):
        # Core callers pass reply_to + metadata — the override must not TypeError.
        adapter = self._make_adapter()
        mock_resp = MagicMock(status_code=200)
        mock_resp.json.return_value = {"id": "i"}
        adapter._http_client = AsyncMock()
        adapter._http_client.post = AsyncMock(return_value=mock_resp)

        result = _run(adapter.send_image(
            "+1", "https://x/y.png", caption="c", reply_to="r", metadata={"thread": 1}))
        assert result.success is True

    def test_send_image_file_validates_and_attaches(self, monkeypatch):
        adapter = self._make_adapter()
        monkeypatch.setattr(adapter, "validate_media_delivery_path", lambda p: p)
        mock_resp = MagicMock(status_code=200)
        mock_resp.json.return_value = {}
        adapter._http_client = AsyncMock()
        adapter._http_client.post = AsyncMock(return_value=mock_resp)

        result = _run(adapter.send_image_file("+1", "/tmp/a.png", caption="hi", metadata={}))
        assert result.success is True
        body = adapter._http_client.post.call_args.kwargs["json"]
        assert body["attachments"][0]["path"] == "/tmp/a.png"

    def test_send_image_file_rejects_unsafe_path(self, monkeypatch):
        adapter = self._make_adapter()
        monkeypatch.setattr(adapter, "validate_media_delivery_path", lambda p: None)
        result = _run(adapter.send_image_file("+1", "/etc/passwd"))
        assert result.success is False

    def test_send_non_json_2xx_is_success(self):
        # A 2xx with an unparseable body must NOT be reported as a failure.
        adapter = self._make_adapter()
        mock_resp = MagicMock(status_code=200)
        mock_resp.json.side_effect = ValueError("not json")
        adapter._http_client = AsyncMock()
        adapter._http_client.post = AsyncMock(return_value=mock_resp)

        result = _run(adapter.send("+1", "hi"))
        assert result.success is True
        assert result.message_id


# ---------------------------------------------------------------------------
# Adapter inbound
# ---------------------------------------------------------------------------


class TestAdapterInbound:
    def _make_adapter(self):
        return PhotonAdapter(PlatformConfig(
            enabled=True, extra={"sidecar_url": "http://127.0.0.1:8787"}))

    def test_on_message_builds_event_and_dedupes(self):
        adapter = self._make_adapter()
        with patch.object(adapter, "handle_message", new_callable=AsyncMock) as hm:
            msg = {"id": "evt1", "spaceId": "sp1", "handle": "+15555550123",
                   "text": "yo jarvis", "platform": "imessage",
                   "timestamp": "2026-06-27T00:00:00Z"}
            _run(adapter._on_message(dict(msg)))
            _run(adapter._on_message(dict(msg)))  # duplicate id → ignored
            assert hm.await_count == 1
            event = hm.await_args[0][0]
            assert event.text == "yo jarvis"
            # Reply routes back to the space; auth/display use the handle.
            assert event.source.chat_id == "sp1"
            assert event.source.user_id == "+15555550123"

    def test_on_message_skips_empty_text(self):
        adapter = self._make_adapter()
        with patch.object(adapter, "handle_message", new_callable=AsyncMock) as hm:
            _run(adapter._on_message({"id": "e", "handle": "+1", "text": "  "}))
            assert hm.await_count == 0


# ---------------------------------------------------------------------------
# Standalone send (cron / Code Master iMessage notify path)
# ---------------------------------------------------------------------------


class _FakeAsyncClient:
    last = {}

    def __init__(self, *a, **k):
        pass

    async def __aenter__(self):
        return self

    async def __aexit__(self, *a):
        return False

    async def post(self, url, headers=None, json=None):
        _FakeAsyncClient.last = {"url": url, "headers": headers or {}, "json": json or {}}
        resp = MagicMock(status_code=200)
        resp.content = b"{}"
        resp.json.return_value = {"id": "s1"}
        return resp


class TestStandaloneSend:
    def test_success_posts_to_sidecar(self):
        fake_httpx = MagicMock()
        fake_httpx.AsyncClient = _FakeAsyncClient
        pconfig = PlatformConfig(enabled=True, extra={
            "sidecar_url": "http://127.0.0.1:8787", "sidecar_token": "tok"})
        with patch.object(_photon, "httpx", fake_httpx):
            res = _run(_standalone_send(pconfig, "+15555550123", "build done"))
        assert res["success"] is True
        assert res["message_id"] == "s1"
        assert _FakeAsyncClient.last["json"]["address"] == "+15555550123"
        assert _FakeAsyncClient.last["json"]["text"] == "build done"

    def test_media_files_become_attachments(self):
        fake_httpx = MagicMock()
        fake_httpx.AsyncClient = _FakeAsyncClient
        pconfig = PlatformConfig(enabled=True, extra={"sidecar_url": "http://127.0.0.1:8787"})
        with patch.object(_photon, "httpx", fake_httpx):
            res = _run(_standalone_send(
                pconfig, "+1555", "see this", media_files=["/tmp/a.png", "/tmp/b.png"]))
        assert res["success"] is True
        atts = _FakeAsyncClient.last["json"]["attachments"]
        assert [a["path"] for a in atts] == ["/tmp/a.png", "/tmp/b.png"]

    def test_no_recipient_errors(self):
        res = _run(_standalone_send(SimpleNamespace(extra={}), "", "hi"))
        assert "error" in res


# ---------------------------------------------------------------------------
# Plugin registration
# ---------------------------------------------------------------------------


def test_register_creates_valid_entry():
    captured = {}

    class _Ctx:
        def register_platform(self, **kw):
            captured.update(kw)

    register(_Ctx())
    assert captured["name"] == "photon"
    assert captured["label"]
    assert captured["standalone_sender_fn"] is _standalone_send
    assert captured["cron_deliver_env_var"] == "PHOTON_NOTIFY_TARGET"
    assert captured["allowed_users_env"] == "PHOTON_ALLOWED_USERS"
    assert captured["allow_all_env"] == "PHOTON_ALLOW_ALL_USERS"
    # Factory builds a real adapter.
    adapter = captured["adapter_factory"](PlatformConfig(enabled=True, extra={}))
    assert isinstance(adapter, PhotonAdapter)
