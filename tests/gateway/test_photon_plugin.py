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


class _CapturingClient:
    """Fake httpx.AsyncClient — captures the POST and returns a set response.
    Used to assert the adapter's fresh-per-call client behavior."""
    response = None
    last: dict = {}

    def __init__(self, *a, **k):
        pass

    async def __aenter__(self):
        return self

    async def __aexit__(self, *a):
        return False

    async def post(self, url, headers=None, json=None):
        _CapturingClient.last = {"url": url, "headers": headers or {}, "json": json or {}}
        return _CapturingClient.response


def _patch_client(monkeypatch, *, status=200, payload=None, text="", json_error=False):
    resp = MagicMock(status_code=status)
    resp.text = text
    resp.content = b"{}"
    if json_error:
        resp.json.side_effect = ValueError("not json")
    else:
        resp.json.return_value = payload if payload is not None else {}
    _CapturingClient.response = resp
    _CapturingClient.last = {}
    monkeypatch.setattr(_photon.httpx, "AsyncClient", _CapturingClient)


class TestAdapterSend:
    def _make_adapter(self, **extra):
        base = {"sidecar_url": "http://127.0.0.1:8799", "sidecar_token": "tok"}
        base.update(extra)
        return PhotonAdapter(PlatformConfig(enabled=True, extra=base))

    def test_send_posts_to_sidecar(self, monkeypatch):
        adapter = self._make_adapter()
        _patch_client(monkeypatch, payload={"id": "m1"})
        result = _run(adapter.send("+15555550123", "Hello iMessage!"))
        assert result.success is True
        assert result.message_id == "m1"
        last = _CapturingClient.last
        assert last["url"].endswith("/send")
        assert last["json"]["address"] == "+15555550123"
        assert last["json"]["text"] == "Hello iMessage!"
        assert last["headers"]["X-Photon-Token"] == "tok"

    def test_send_uses_notify_target_when_chat_id_blank(self, monkeypatch):
        adapter = self._make_adapter(notify_target="+15555550999")
        _patch_client(monkeypatch)
        result = _run(adapter.send("", "ping"))
        assert result.success is True
        assert _CapturingClient.last["json"]["address"] == "+15555550999"

    def test_send_image_posts_attachment(self, monkeypatch):
        adapter = self._make_adapter()
        _patch_client(monkeypatch, payload={"id": "img1"})
        result = _run(adapter.send_image("+15555550123", "https://x/y.png", "caption"))
        assert result.success is True
        body = _CapturingClient.last["json"]
        assert body["attachments"][0]["url"] == "https://x/y.png"
        assert body["text"] == "caption"

    def test_send_handles_http_error(self, monkeypatch):
        adapter = self._make_adapter()
        _patch_client(monkeypatch, status=500, text="boom")
        result = _run(adapter.send("+15555550123", "hi"))
        assert result.success is False
        assert "500" in result.error

    def test_send_image_accepts_base_kwargs(self, monkeypatch):
        # Core callers pass reply_to + metadata — the override must not TypeError.
        adapter = self._make_adapter()
        _patch_client(monkeypatch, payload={"id": "i"})
        result = _run(adapter.send_image(
            "+1", "https://x/y.png", caption="c", reply_to="r", metadata={"thread": 1}))
        assert result.success is True

    def test_send_image_file_validates_and_attaches(self, monkeypatch):
        adapter = self._make_adapter()
        monkeypatch.setattr(adapter, "validate_media_delivery_path", lambda p: p)
        _patch_client(monkeypatch)
        result = _run(adapter.send_image_file("+1", "/tmp/a.png", caption="hi", metadata={}))
        assert result.success is True
        assert _CapturingClient.last["json"]["attachments"][0]["path"] == "/tmp/a.png"

    def test_send_image_file_rejects_unsafe_path(self, monkeypatch):
        adapter = self._make_adapter()
        monkeypatch.setattr(adapter, "validate_media_delivery_path", lambda p: None)
        result = _run(adapter.send_image_file("+1", "/etc/passwd"))
        assert result.success is False

    def test_send_non_json_2xx_is_success(self, monkeypatch):
        # A 2xx with an unparseable body must NOT be reported as a failure.
        adapter = self._make_adapter()
        _patch_client(monkeypatch, json_error=True)
        result = _run(adapter.send("+1", "hi"))
        assert result.success is True
        assert result.message_id


# ---------------------------------------------------------------------------
# Adapter outbound RETRY policy — the "sometimes no reply" hardening.
# A transient sidecar hiccup (503 reconnect window, 5xx, connection blip) must
# be retried so the reply still goes out; a 422 validation error must NOT be
# retried (re-POSTing it never succeeds and just delays the failure).
# ---------------------------------------------------------------------------


class _SequencingClient:
    """Fake httpx.AsyncClient that returns/raises a different result per POST,
    walking a shared script. Lets us assert retry-then-succeed and
    no-retry-on-422 without sleeping for real (backoff is patched to 0)."""

    script: list = []
    calls: int = 0

    def __init__(self, *a, **k):
        pass

    async def __aenter__(self):
        return self

    async def __aexit__(self, *a):
        return False

    async def post(self, url, headers=None, json=None):
        i = _SequencingClient.calls
        _SequencingClient.calls += 1
        item = _SequencingClient.script[min(i, len(_SequencingClient.script) - 1)]
        if isinstance(item, Exception):
            raise item
        return item


def _resp(status=200, payload=None, text=""):
    resp = MagicMock(status_code=status)
    resp.text = text
    resp.content = b"{}"
    resp.json.return_value = payload if payload is not None else {}
    return resp


def _patch_sequence(monkeypatch, script):
    _SequencingClient.script = list(script)
    _SequencingClient.calls = 0
    monkeypatch.setattr(_photon.httpx, "AsyncClient", _SequencingClient)
    # No real backoff sleeps in tests.
    monkeypatch.setattr(_photon.asyncio, "sleep", AsyncMock())


class TestAdapterSendRetry:
    def _make_adapter(self, **extra):
        base = {"sidecar_url": "http://127.0.0.1:8799", "sidecar_token": "tok"}
        base.update(extra)
        return PhotonAdapter(PlatformConfig(enabled=True, extra=base))

    def test_send_retries_transient_503_then_succeeds(self, monkeypatch):
        # 503 (sidecar mid-reconnect / mid-reload) is retryable; the next attempt
        # succeeds and the user gets their reply.
        adapter = self._make_adapter()
        _patch_sequence(monkeypatch, [
            _resp(status=503, text="reconnecting"),
            _resp(status=200, payload={"id": "m2"}),
        ])
        result = _run(adapter.send("+1", "hi"))
        assert result.success is True
        assert result.message_id == "m2"
        assert _SequencingClient.calls == 2  # retried exactly once

    def test_send_retries_5xx_then_succeeds(self, monkeypatch):
        adapter = self._make_adapter()
        _patch_sequence(monkeypatch, [
            _resp(status=500, text="boom"),
            _resp(status=502, text="bad gateway"),
            _resp(status=200, payload={"id": "ok"}),
        ])
        result = _run(adapter.send("+1", "hi"))
        assert result.success is True
        assert _SequencingClient.calls == 3

    def test_send_retries_connection_error_then_succeeds(self, monkeypatch):
        adapter = self._make_adapter()
        _patch_sequence(monkeypatch, [
            _photon.httpx.ConnectError("connection refused"),
            _resp(status=200, payload={"id": "ok"}),
        ])
        result = _run(adapter.send("+1", "hi"))
        assert result.success is True
        assert _SequencingClient.calls == 2

    def test_send_does_NOT_retry_422_validation(self, monkeypatch):
        # 422 is permanent (bad address / empty text) — fail immediately, no retry.
        adapter = self._make_adapter()
        _patch_sequence(monkeypatch, [
            _resp(status=422, text="address required"),
            _resp(status=200, payload={"id": "should-not-reach"}),
        ])
        result = _run(adapter.send("+1", "hi"))
        assert result.success is False
        assert "422" in result.error
        assert _SequencingClient.calls == 1  # exactly one attempt — no retry

    def test_send_exhausts_retries_returns_retryable(self, monkeypatch):
        # All attempts transiently fail → failure, but retryable=True so the
        # gateway's outer _send_with_retry gets one more shot.
        adapter = self._make_adapter()
        _patch_sequence(monkeypatch, [_resp(status=503, text="down")])
        result = _run(adapter.send("+1", "hi"))
        assert result.success is False
        assert result.retryable is True
        assert _SequencingClient.calls == _photon.SEND_MAX_RETRIES

    def test_standalone_send_retries_then_succeeds(self, monkeypatch):
        # The cron / CC-notify out-of-process path retries too.
        _patch_sequence(monkeypatch, [
            _resp(status=503, text="reconnecting"),
            _resp(status=200, payload={"id": "s9"}),
        ])
        pconfig = PlatformConfig(
            enabled=True, extra={"sidecar_url": "http://127.0.0.1:8799"})
        res = _run(_standalone_send(pconfig, "+15555550123", "build done"))
        assert res["success"] is True
        assert res["message_id"] == "s9"
        assert _SequencingClient.calls == 2

    def test_standalone_send_does_NOT_retry_422(self, monkeypatch):
        _patch_sequence(monkeypatch, [
            _resp(status=422, text="address required"),
            _resp(status=200, payload={"id": "nope"}),
        ])
        pconfig = PlatformConfig(
            enabled=True, extra={"sidecar_url": "http://127.0.0.1:8799"})
        res = _run(_standalone_send(pconfig, "+15555550123", "hi"))
        assert "error" in res
        assert "422" in res["error"]
        assert _SequencingClient.calls == 1


# ---------------------------------------------------------------------------
# Adapter edit (streaming replies)
# ---------------------------------------------------------------------------


class TestAdapterEdit:
    def _make_adapter(self, **extra):
        base = {"sidecar_url": "http://127.0.0.1:8799", "sidecar_token": "tok"}
        base.update(extra)
        return PhotonAdapter(PlatformConfig(enabled=True, extra=base))

    def test_streaming_capability_hooks_enabled(self):
        # The gateway's stream consumer enables the send+edit streaming path
        # only when edit_message is OVERRIDDEN and SUPPORTS_MESSAGE_EDITING is
        # truthy. Guard both so a refactor can't silently disable streaming.
        from gateway.platforms.base import BasePlatformAdapter

        assert PhotonAdapter.edit_message is not BasePlatformAdapter.edit_message
        assert getattr(PhotonAdapter, "SUPPORTS_MESSAGE_EDITING", True) is True

    def test_edit_message_posts_to_sidecar(self, monkeypatch):
        adapter = self._make_adapter()
        _patch_client(monkeypatch, payload={"success": True, "id": "m1"})
        result = _run(adapter.edit_message("+15555550123", "m1", "growing text"))
        assert result.success is True
        assert result.message_id == "m1"
        last = _CapturingClient.last
        assert last["url"].endswith("/edit")
        assert last["json"]["id"] == "m1"
        assert last["json"]["text"] == "growing text"
        assert last["headers"]["X-Photon-Token"] == "tok"

    def test_edit_message_accepts_finalize_kwarg(self, monkeypatch):
        # The stream consumer always passes finalize=; the override must accept it.
        adapter = self._make_adapter()
        _patch_client(monkeypatch, payload={"success": True, "id": "m1"})
        result = _run(adapter.edit_message("+1", "m1", "done", finalize=True))
        assert result.success is True

    def test_edit_message_empty_id_fails_fast(self, monkeypatch):
        adapter = self._make_adapter()
        _patch_client(monkeypatch)
        result = _run(adapter.edit_message("+1", "", "text"))
        assert result.success is False
        # No HTTP call should have been made for an empty id.
        assert _CapturingClient.last == {}

    def test_edit_message_unknown_id_falls_back(self, monkeypatch):
        # Sidecar returns 422 for an uncached id; the adapter reports failure so
        # the stream consumer falls back to a fresh send.
        adapter = self._make_adapter()
        _patch_client(monkeypatch, status=422, text="Photon edit: unknown message id x")
        result = _run(adapter.edit_message("+1", "x", "text"))
        assert result.success is False
        assert "422" in result.error

    def test_edit_message_uses_fresh_client(self, monkeypatch):
        # Must NOT reuse self._http_client (bound to connect()'s loop). The
        # patched httpx.AsyncClient is the fresh-per-call client.
        adapter = self._make_adapter()
        adapter._http_client = object()  # would explode if reused
        _patch_client(monkeypatch, payload={"success": True, "id": "m1"})
        result = _run(adapter.edit_message("+1", "m1", "text"))
        assert result.success is True


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

    def test_on_message_ingests_image_attachment(self, monkeypatch, tmp_path):
        adapter = self._make_adapter()
        f = tmp_path / "img.png"
        f.write_bytes(b"\x89PNG\r\n\x1a\nfake")
        monkeypatch.setattr(_photon, "cache_image_from_bytes", lambda data, ext: "/cache/img.png")
        with patch.object(adapter, "handle_message", new_callable=AsyncMock) as hm:
            msg = {"id": "m1", "spaceId": "sp1", "handle": "+1", "text": "",
                   "attachments": [{"path": str(f), "mimeType": "image/png",
                                    "kind": "image", "name": "img.png"}]}
            _run(adapter._on_message(msg))
            assert hm.await_count == 1
            event = hm.await_args[0][0]
            assert event.media_urls == ["/cache/img.png"]
            assert event.media_types == ["image/png"]
            assert event.message_type == _photon.MessageType.PHOTO
            assert event.text == "(attachment)"
        # temp spool file is cleaned up after read
        assert not f.exists()

    def test_ingest_attachments_skips_missing_file(self):
        adapter = self._make_adapter()
        urls, types, mtype = adapter._ingest_attachments(
            [{"path": "/nonexistent/x.png", "mimeType": "image/png", "kind": "image"}])
        assert urls == []
        assert mtype == _photon.MessageType.TEXT

    def test_attachment_only_unreadable_file_is_not_dropped(self):
        # An attachment-only inbound whose temp file vanished (a concurrent
        # reader won the read+delete race, or cleanup removed it) must NOT be
        # silently dropped — we still deliver a placeholder so the agent replies
        # instead of going quiet. This is a real "sometimes no reply" path.
        adapter = self._make_adapter()
        with patch.object(adapter, "handle_message", new_callable=AsyncMock) as hm:
            msg = {"id": "att-gone", "spaceId": "sp1", "handle": "+1", "text": "",
                   "attachments": [{"path": "/nonexistent/gone.png",
                                    "mimeType": "image/png", "kind": "image"}]}
            _run(adapter._on_message(msg))
            assert hm.await_count == 1
            event = hm.await_args[0][0]
            assert event.text  # a non-empty placeholder, not dropped
            assert event.media_urls == []

    def test_no_attachments_and_no_text_is_still_dropped(self):
        # Guard the other side: a genuinely empty inbound (no text, no claimed
        # attachments) is correctly skipped — the placeholder only kicks in when
        # attachments WERE claimed but unreadable.
        adapter = self._make_adapter()
        with patch.object(adapter, "handle_message", new_callable=AsyncMock) as hm:
            _run(adapter._on_message({"id": "empty", "handle": "+1", "text": ""}))
            assert hm.await_count == 0


class TestInboundStreamResilience:
    """The inbound consumer must NEVER permanently stop on anything but real
    shutdown — a clean stream end (sidecar /reload or restart) or a transient
    error always loops back to reconnect, or inbound goes silently dead."""

    def _make_adapter(self):
        return PhotonAdapter(PlatformConfig(
            enabled=True, extra={"sidecar_url": "http://127.0.0.1:8787"}))

    def test_clean_stream_end_reconnects_promptly(self, monkeypatch):
        # _consume_stream returning (sidecar end()ed the stream on /reload) must
        # reconnect — NOT exit the loop. We let it reconnect twice then stop.
        adapter = self._make_adapter()
        adapter._running = True
        monkeypatch.setattr(_photon.asyncio, "sleep", AsyncMock())
        calls = {"n": 0}

        async def fake_consume(url):
            calls["n"] += 1
            if calls["n"] >= 3:
                adapter._running = False  # let the loop exit after 3 reconnects
            return  # clean end every time → must reconnect

        monkeypatch.setattr(adapter, "_consume_stream", fake_consume)
        _run(adapter._run_stream())
        assert calls["n"] == 3  # reconnected after each clean end, never gave up

    def test_transient_error_reconnects(self, monkeypatch):
        # A transient exception (network blip / read timeout) must reconnect too.
        adapter = self._make_adapter()
        adapter._running = True
        monkeypatch.setattr(_photon.asyncio, "sleep", AsyncMock())
        calls = {"n": 0}

        async def flaky_consume(url):
            calls["n"] += 1
            if calls["n"] >= 3:
                adapter._running = False
                return
            raise RuntimeError("read timeout / network blip")

        monkeypatch.setattr(adapter, "_consume_stream", flaky_consume)
        _run(adapter._run_stream())
        assert calls["n"] == 3  # an exception never breaks the loop

    def test_fatal_error_stops_the_loop(self, monkeypatch):
        # A 401 (bad token) is fatal — the loop SHOULD stop (no point retrying).
        adapter = self._make_adapter()
        adapter._running = True
        monkeypatch.setattr(_photon.asyncio, "sleep", AsyncMock())
        calls = {"n": 0}

        async def auth_fail(url):
            calls["n"] += 1
            raise _photon._FatalStreamError("401 Unauthorized")

        monkeypatch.setattr(adapter, "_consume_stream", auth_fail)
        _run(adapter._run_stream())
        assert calls["n"] == 1  # fatal → one attempt, then stop
        assert adapter._running is False


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
