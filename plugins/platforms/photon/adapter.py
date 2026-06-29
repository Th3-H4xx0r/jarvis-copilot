"""Photon (Spectrum) platform adapter — hosted iMessage for JarvisCopilot.

photon.codes has no Python SDK, so the live Spectrum connection lives in a small
Node sidecar (``plugins/platforms/photon/sidecar/``). This adapter is a thin
client of that localhost sidecar:

  * Outbound — ``POST {sidecar}/send {address, text}``.
  * Inbound  — ``GET {sidecar}/inbound`` is a newline-delimited JSON stream of
    inbound iMessages (the sidecar consumes Spectrum's ``app.messages`` stream and
    forwards each one). No public Photon webhook / HMAC is needed.

Ships as a bundled JarvisCopilot platform plugin. The plugin loader scans this
directory at startup, calls :func:`register`, and the platform becomes available
to ``gateway/run.py`` and ``tools/send_message_tool`` through the registry — no
edits to core files required (same shape as ``plugins/platforms/ntfy``).

Configuration (env wins over ``config.yaml`` ``platforms.photon.extra``)::

    PHOTON_PROJECT_ID          Photon project id  (sidecar uses it; presence = enabled)
    PHOTON_PROJECT_SECRET      Photon project secret (sidecar only)
    PHOTON_SIDECAR_URL         Sidecar base URL (default http://127.0.0.1:8799)
    PHOTON_SIDECAR_TOKEN       Shared token sent as X-Photon-Token
    PHOTON_NOTIFY_TARGET       Your iMessage handle — the home channel / default
                               recipient for cron + Claude Code notifications
    PHOTON_HOME_CHANNEL        Alias for PHOTON_NOTIFY_TARGET (home-channel address)
    PHOTON_ALLOWED_USERS       Comma-separated allowlist of inbound addresses
    PHOTON_ALLOW_ALL_USERS     Allow any inbound address (dev only)
"""

import asyncio
import json
import logging
import os
import time
import uuid
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

try:
    import httpx

    HTTPX_AVAILABLE = True
except ImportError:  # pragma: no cover - httpx is a JarvisCopilot dependency
    HTTPX_AVAILABLE = False
    httpx = None  # type: ignore[assignment]

from gateway.config import Platform, PlatformConfig
from gateway.platforms.base import (
    BasePlatformAdapter,
    MessageEvent,
    MessageType,
    SendResult,
    cache_audio_from_bytes,
    cache_document_from_bytes,
    cache_image_from_bytes,
    cache_video_from_bytes,
)

logger = logging.getLogger(__name__)

DEFAULT_SIDECAR_URL = "http://127.0.0.1:8799"
# iMessage has no hard per-message length in Spectrum; keep a generous cap so a
# runaway reply still gets chunked rather than rejected.
MAX_MESSAGE_LENGTH = 8000
DEDUP_WINDOW_SECONDS = 300
DEDUP_MAX_SIZE = 1000
RECONNECT_BACKOFF = [2, 5, 10, 30, 60]
STREAM_READ_TIMEOUT = 90  # sidecar heartbeats every ~25s; give margin

# Outbound send retry policy. A single POST to the localhost sidecar can fail
# transiently — the sidecar momentarily busy, mid-/reload, or the Spectrum link
# reconnecting (sidecar returns 503), a connection blip, or a Spectrum 429/5xx.
# Without a retry the user simply gets NO reply, which is the most visible
# "sometimes Photon doesn't answer" symptom. We retry those with short backoff.
# We do NOT retry a 422 (validation: empty/missing address or text) or any other
# permanent rejection — retrying those just wastes time and never succeeds.
SEND_MAX_RETRIES = 3
SEND_RETRY_BACKOFF = [0.5, 1.5, 3.0]
# HTTP statuses that are safe + worth retrying on /send (transient server-side).
_RETRYABLE_SEND_STATUS = {429, 500, 502, 503, 504}


class _FatalStreamError(Exception):
    """Raised when the inbound stream fails unrecoverably (e.g. 401)."""


def _sidecar_url(extra: Optional[dict] = None) -> str:
    extra = extra or {}
    url = (extra.get("sidecar_url") or os.getenv("PHOTON_SIDECAR_URL", DEFAULT_SIDECAR_URL)).strip()
    return url.rstrip("/") or DEFAULT_SIDECAR_URL


def _sidecar_token(extra: Optional[dict] = None) -> str:
    extra = extra or {}
    return (extra.get("sidecar_token") or os.getenv("PHOTON_SIDECAR_TOKEN", "")).strip()


def _auth_headers(extra: Optional[dict] = None) -> Dict[str, str]:
    token = _sidecar_token(extra)
    return {"X-Photon-Token": token} if token else {}


def _notify_target(extra: Optional[dict] = None) -> str:
    """The default recipient address (home channel) for cron / CC notifications."""
    extra = extra or {}
    return (
        extra.get("notify_target")
        or os.getenv("PHOTON_NOTIFY_TARGET", "")
        or os.getenv("PHOTON_HOME_CHANNEL", "")
    ).strip()


def check_requirements() -> bool:
    """Photon is installable + minimally configured.

    Reads env directly (no full ``load_gateway_config()``) for a cheap pre-flight.
    Configured = httpx present AND we know which Photon to use: either a project id
    (production) or an explicit sidecar URL (dev / mock).
    """
    if not HTTPX_AVAILABLE:
        return False
    return bool(
        os.getenv("PHOTON_PROJECT_ID", "").strip()
        or os.getenv("PHOTON_SIDECAR_URL", "").strip()
    )


def validate_config(config) -> bool:
    extra = getattr(config, "extra", {}) or {}
    return bool(
        extra.get("project_id")
        or extra.get("sidecar_url")
        or os.getenv("PHOTON_PROJECT_ID", "").strip()
        or os.getenv("PHOTON_SIDECAR_URL", "").strip()
    )


def is_connected(config) -> bool:
    return validate_config(config)


class PhotonAdapter(BasePlatformAdapter):
    """Bridges the JarvisCopilot gateway to the Photon sidecar."""

    MAX_MESSAGE_LENGTH = MAX_MESSAGE_LENGTH

    # Streaming replies (Telegram-style send-then-edit). Spectrum's iMessage
    # bridge edits a message in place, so we opt into the gateway's edit-based
    # streaming path. Two capability hooks gate that path in the stream
    # consumer / run loop (gateway):
    #   1. ``SUPPORTS_MESSAGE_EDITING`` (read via getattr, default True) — keeps
    #      streaming + the typing cursor enabled for this platform.
    #   2. ``edit_message`` being OVERRIDDEN (the consumer checks
    #      ``type(adapter).edit_message is BasePlatformAdapter.edit_message``);
    #      overriding it below is what actually enables send+edit streaming.
    SUPPORTS_MESSAGE_EDITING = True

    def __init__(self, config: PlatformConfig):
        super().__init__(config=config, platform=Platform("photon"))

        extra = config.extra or {}
        self._sidecar = _sidecar_url(extra)
        self._headers = _auth_headers(extra)
        self._notify_target = _notify_target(extra)

        self._stream_task: Optional[asyncio.Task] = None
        self._http_client: Optional["httpx.AsyncClient"] = None
        self._seen_messages: Dict[str, float] = {}

    # -- Connection lifecycle ----------------------------------------------

    async def connect(self) -> bool:
        if not HTTPX_AVAILABLE:
            logger.warning("[%s] httpx not installed", self.name)
            return False
        try:
            self._http_client = httpx.AsyncClient(timeout=None)
            # Confirm the sidecar is reachable before declaring connected so a
            # missing sidecar surfaces as a clear gateway log, not a silent dud.
            try:
                resp = await self._http_client.get(
                    f"{self._sidecar}/health", headers=self._headers, timeout=5.0
                )
                if resp.status_code == 401:
                    logger.error(
                        "[%s] sidecar rejected token (401). Check PHOTON_SIDECAR_TOKEN.",
                        self.name,
                    )
                    await self._http_client.aclose()
                    self._http_client = None
                    return False
                health = resp.json() if resp.status_code < 300 else {}
                logger.info(
                    "[%s] sidecar healthy at %s (mock=%s, connected=%s)",
                    self.name, self._sidecar, health.get("mock"), health.get("connected"),
                )
            except Exception as e:
                logger.warning(
                    "[%s] sidecar not reachable at %s (%s). Is the Photon sidecar running?",
                    self.name, self._sidecar, e,
                )
                # Stay "connected" so outbound retries can recover once the
                # sidecar comes up; the stream loop reconnects on its own.

            self._stream_task = asyncio.create_task(self._run_stream())
            self._mark_connected()
            return True
        except Exception as e:
            logger.error("[%s] Failed to connect: %s", self.name, e)
            return False

    async def _run_stream(self) -> None:
        """Consume the sidecar inbound NDJSON stream, with reconnection.

        Bulletproof by design: the ONLY ways out of this loop are real shutdown
        (``self._running`` cleared, ``CancelledError``) or a fatal auth error
        (401). EVERY other outcome — a transient exception, a read timeout, OR a
        clean stream end (the sidecar ended the stream on /reload or restart) —
        leads back to a reconnect so a single blip can never permanently stop
        inbound delivery. spectrum-ts has no replay/history backstop, so a stuck
        consumer = silently no replies; we never let that happen."""
        backoff_idx = 0
        url = f"{self._sidecar}/inbound"
        while self._running:
            stream_start = time.monotonic()
            clean_end = False
            try:
                await self._consume_stream(url)
                clean_end = True  # returned without raising → sidecar ended it
            except asyncio.CancelledError:
                return
            except _FatalStreamError:
                self._running = False
                return
            except Exception as e:
                if not self._running:
                    return
                logger.warning("[%s] inbound stream error: %s", self.name, e)

            if not self._running:
                return
            # A CLEAN end (sidecar /reload swapped the engine and end()ed open
            # streams, or a brief server restart) should reconnect PROMPTLY — not
            # sit out a multi-second backoff during which inbound is dead. Only an
            # erroring/short-lived stream escalates the backoff.
            if clean_end:
                logger.info("[%s] inbound stream ended (reload/restart); reconnecting now", self.name)
                await asyncio.sleep(0.25)
                backoff_idx = 0
                continue
            if time.monotonic() - stream_start >= 60.0:
                backoff_idx = 0
            delay = RECONNECT_BACKOFF[min(backoff_idx, len(RECONNECT_BACKOFF) - 1)]
            logger.info("[%s] reconnecting inbound in %ds...", self.name, delay)
            await asyncio.sleep(delay)
            backoff_idx += 1

    async def _consume_stream(self, url: str) -> None:
        assert self._http_client is not None
        async with self._http_client.stream(
            "GET",
            url,
            headers=self._headers,
            timeout=httpx.Timeout(connect=10.0, read=STREAM_READ_TIMEOUT, write=10.0, pool=10.0),
        ) as response:
            if response.status_code == 401:
                logger.error("[%s] inbound stream unauthorized (401)", self.name)
                self._set_fatal_error(
                    "photon_unauthorized",
                    "Photon sidecar rejected the token (401). Check PHOTON_SIDECAR_TOKEN.",
                    retryable=False,
                )
                raise _FatalStreamError("401 Unauthorized")
            response.raise_for_status()
            async for line in response.aiter_lines():
                if not self._running:
                    return
                line = line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                etype = event.get("type")
                if etype == "message":
                    await self._on_message(event.get("message") or {})
                elif etype == "ready":
                    # The sidecar reports whether its Spectrum link is up. If it
                    # is NOT, inbound iMessages will silently never arrive even
                    # though THIS stream is healthy — make that loud so a down /
                    # mock sidecar is diagnosable instead of "Jarvis went quiet".
                    if event.get("connected") is False:
                        logger.warning(
                            "[%s] inbound stream is up but the sidecar's Spectrum "
                            "link is DOWN (mock mode or reconnecting) — no inbound "
                            "iMessages will arrive until it reconnects.",
                            self.name,
                        )
                    else:
                        logger.info("[%s] inbound stream ready (sidecar connected)", self.name)

    async def disconnect(self) -> None:
        self._running = False
        self._mark_disconnected()
        if self._stream_task:
            self._stream_task.cancel()
            try:
                await self._stream_task
            except asyncio.CancelledError:
                pass
            self._stream_task = None
        if self._http_client:
            await self._http_client.aclose()
            self._http_client = None
        self._seen_messages.clear()
        logger.info("[%s] Disconnected", self.name)

    # -- Inbound -----------------------------------------------------------

    async def _on_message(self, msg: Dict[str, Any]) -> None:
        msg_id = str(msg.get("id") or uuid.uuid4().hex)
        if self._is_duplicate(msg_id):
            return
        text = (msg.get("text") or "").strip()
        # Photos/stickers/files/voice arrive as attachments the sidecar spooled to
        # temp files; cache them locally so the agent's vision/audio tools can read
        # them (media_urls = local paths). A message may be attachment-only.
        claimed_attachments = list(msg.get("attachments") or [])
        media_urls, media_types, msg_type = self._ingest_attachments(claimed_attachments)
        if not text and media_urls:
            text = "(attachment)"
        if not text and not media_urls:
            # The wire message CLAIMED attachments but none could be read — the
            # sidecar-spooled temp file was already gone (a concurrent reader won
            # the read+delete race, or the OS/cleanup removed it). Dropping the
            # whole message here is a SILENT no-reply for an attachment-only text
            # ("sometimes Photon doesn't answer"). Surface a placeholder instead so
            # the agent still sees an inbound and replies, rather than going quiet.
            if claimed_attachments:
                logger.warning(
                    "[%s] inbound %s had attachment(s) but none were readable "
                    "(temp file lost); delivering as a placeholder so we still reply",
                    self.name, msg_id,
                )
                text = "(sent an attachment I couldn't open)"
            else:
                return

        # Reply routing keys on the originating SPACE (space_id) so the sidecar
        # replies in-thread (no recipient-provisioning needed). Auth/display use
        # the sender handle. Fall back to each other if one is missing.
        space_id = (msg.get("spaceId") or "").strip()
        handle = (msg.get("handle") or msg.get("address") or "").strip()
        chat_id = space_id or handle
        if not chat_id:
            logger.debug("[%s] inbound with no space/handle, skipping", self.name)
            return

        source = self.build_source(
            chat_id=chat_id,
            chat_name=handle or chat_id,
            chat_type="dm",
            user_id=handle or chat_id,
            user_name=handle or "iMessage",
        )
        timestamp = _parse_ts(msg.get("timestamp"))
        event = MessageEvent(
            text=text,
            message_type=msg_type,
            source=source,
            message_id=msg_id,
            raw_message=msg,
            timestamp=timestamp,
            media_urls=media_urls,
            media_types=media_types,
        )
        await self.handle_message(event)

    def _ingest_attachments(self, attachments: List[dict]):
        """Read each spooled inbound attachment, cache it locally, and return
        (media_urls, media_types, message_type). Temp files are removed after
        read. Never raises — a bad attachment is skipped."""
        media_urls: List[str] = []
        media_types: List[str] = []
        msg_type = MessageType.TEXT
        for att in attachments:
            p = (att.get("path") or "").strip()
            if not p:
                continue
            mime = (att.get("mimeType") or "").lower()
            kind = att.get("kind") or ""
            name = att.get("name") or "file"
            try:
                with open(p, "rb") as fh:
                    data = fh.read()
            except Exception as e:
                logger.warning("[%s] could not read inbound attachment: %s", self.name, e)
                continue
            finally:
                try:
                    os.remove(p)
                except OSError:
                    pass
            if not data:
                continue
            try:
                if kind == "image" or mime.startswith("image/"):
                    cached = cache_image_from_bytes(data, _ext_for(mime, name))
                    msg_type = MessageType.PHOTO
                elif kind == "audio" or mime.startswith("audio/"):
                    cached = cache_audio_from_bytes(data, _ext_for(mime, name))
                    if msg_type == MessageType.TEXT:
                        msg_type = MessageType.VOICE
                elif kind == "video" or mime.startswith("video/"):
                    cached = cache_video_from_bytes(data, _ext_for(mime, name))
                    if msg_type == MessageType.TEXT:
                        msg_type = MessageType.VIDEO
                else:
                    cached = cache_document_from_bytes(data, name)
                    if msg_type == MessageType.TEXT:
                        msg_type = MessageType.DOCUMENT
            except Exception as e:
                logger.warning("[%s] failed to cache inbound attachment: %s", self.name, e)
                continue
            media_urls.append(cached)
            media_types.append(mime)
        # A mixed/multi set that contains any image reads best as a PHOTO event.
        if len(media_urls) > 1 and any((m or "").startswith("image/") for m in media_types):
            msg_type = MessageType.PHOTO
        return media_urls, media_types, msg_type

    def _is_duplicate(self, msg_id: str) -> bool:
        now = time.time()
        if len(self._seen_messages) > DEDUP_MAX_SIZE:
            cutoff = now - DEDUP_WINDOW_SECONDS
            self._seen_messages = {k: v for k, v in self._seen_messages.items() if v > cutoff}
        if msg_id in self._seen_messages:
            return True
        self._seen_messages[msg_id] = now
        return False

    # -- Outbound ----------------------------------------------------------

    async def _post_send(self, body: Dict[str, Any], *, timeout: float = 20.0) -> SendResult:
        """POST a (text and/or attachment) message to the sidecar /send, with a
        bounded retry-with-backoff for TRANSIENT failures.

        Uses a FRESH httpx client bound to the current event loop. The gateway
        dispatches sends from loops/threads other than the one ``connect()`` ran
        in, and reusing ``self._http_client`` (created in connect's loop) raises
        "<asyncio Event> is bound to a different event loop". The persistent
        client is reserved for the long-lived inbound stream.

        Retries (short backoff, ``SEND_MAX_RETRIES`` attempts total):
          * connection errors (sidecar momentarily down / restarting),
          * timeouts (sidecar busy / mid-/reload — localhost, so a stuck POST
            is far more likely "not delivered" than "delivered but slow"),
          * HTTP 429 / 5xx incl. the sidecar's 503 reconnect window.
        Does NOT retry a 422 (validation) or any other 4xx — those are
        permanent and re-POSTing them never succeeds."""
        last_error = "send failed"
        attempts = SEND_MAX_RETRIES
        for attempt in range(attempts):
            try:
                async with httpx.AsyncClient(timeout=timeout) as client:
                    resp = await client.post(
                        f"{self._sidecar}/send", headers=self._headers, json=body
                    )
                if resp.status_code < 300:
                    return SendResult(success=True, message_id=_resp_message_id(resp))
                last_error = f"HTTP {resp.status_code}: {resp.text[:200]}"
                if resp.status_code not in _RETRYABLE_SEND_STATUS:
                    # 422 (validation) and other 4xx are permanent — fail now.
                    logger.warning("[%s] send failed %s", self.name, last_error)
                    return SendResult(success=False, error=last_error)
                logger.warning(
                    "[%s] send transient %s (attempt %d/%d)",
                    self.name, last_error, attempt + 1, attempts,
                )
            except httpx.TimeoutException:
                last_error = "Timeout talking to Photon sidecar"
                logger.warning("[%s] send timeout (attempt %d/%d)", self.name, attempt + 1, attempts)
            except Exception as e:
                last_error = str(e)
                logger.warning("[%s] send error (attempt %d/%d): %s", self.name, attempt + 1, attempts, e)
            if attempt < attempts - 1:
                await asyncio.sleep(SEND_RETRY_BACKOFF[min(attempt, len(SEND_RETRY_BACKOFF) - 1)])
        logger.error("[%s] send failed after %d attempts: %s", self.name, attempts, last_error)
        # retryable=True lets any outer gateway _send_with_retry try once more too.
        return SendResult(success=False, error=last_error, retryable=True)

    async def send(
        self,
        chat_id: str,
        content: str,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        address = (chat_id or self._notify_target or "").strip()
        if not address:
            return SendResult(success=False, error="No Photon recipient address")
        if len(content) > self.MAX_MESSAGE_LENGTH:
            logger.warning(
                "[%s] message truncated from %d to %d chars",
                self.name, len(content), self.MAX_MESSAGE_LENGTH,
            )
            content = content[: self.MAX_MESSAGE_LENGTH]
        return await self._post_send({"address": address, "text": content})

    async def edit_message(
        self,
        chat_id: str,
        message_id: str,
        content: str,
        *,
        finalize: bool = False,
    ) -> SendResult:
        """Edit a previously sent message (streaming replies).

        The gateway's stream consumer sends an initial message via ``send``
        then calls this repeatedly with growing text to animate the reply,
        exactly like Telegram. The sidecar cached the Spectrum ``Message``
        object under ``message_id`` on /send; ``POST /edit`` re-targets it.

        ``finalize`` is accepted for the stream-consumer contract (it always
        passes the kwarg). iMessage edits have no lifecycle state, so it is a
        no-op here — an edit is an edit.

        Uses a FRESH httpx client (not ``self._http_client``) for the same
        reason ``_post_send`` does: the gateway dispatches edits from a
        different event loop than ``connect()`` ran in, and reusing the
        persistent client raises "bound to a different event loop".

        On any failure (unknown id after a sidecar restart, HTTP error,
        timeout) this returns ``success=False`` so the stream consumer falls
        back to sending a fresh message rather than freezing the partial.
        """
        if not message_id:
            return SendResult(success=False, error="No message id to edit")
        if len(content) > self.MAX_MESSAGE_LENGTH:
            content = content[: self.MAX_MESSAGE_LENGTH]
        try:
            async with httpx.AsyncClient(timeout=20.0) as client:
                resp = await client.post(
                    f"{self._sidecar}/edit",
                    headers=self._headers,
                    json={"id": message_id, "text": content},
                )
            if resp.status_code < 300:
                return SendResult(success=True, message_id=message_id)
            # 422 = unknown/non-editable id (e.g. sidecar restarted and dropped
            # its cache); other non-2xx = transport/provider failure. Either way
            # the consumer falls back to a fresh send.
            return SendResult(
                success=False, error=f"HTTP {resp.status_code}: {resp.text[:200]}"
            )
        except httpx.TimeoutException:
            return SendResult(success=False, error="Timeout talking to Photon sidecar")
        except Exception as e:
            logger.error("[%s] edit error: %s", self.name, e)
            return SendResult(success=False, error=str(e))

    async def send_image(
        self,
        chat_id: str,
        image_url: str,
        caption: Optional[str] = None,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        """Send an image by URL as a native iMessage attachment."""
        address = (chat_id or self._notify_target or "").strip()
        if not address:
            return SendResult(success=False, error="No Photon recipient address")
        body: Dict[str, Any] = {"address": address, "attachments": [{"url": image_url}]}
        if caption:
            body["text"] = caption
        return await self._post_send(body, timeout=30.0)

    async def send_image_file(
        self,
        chat_id: str,
        image_path: str,
        caption: Optional[str] = None,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
        **kwargs,
    ) -> SendResult:
        """Send a LOCAL image file as a native iMessage attachment.

        The sidecar runs on the same host, so a validated local path can be read
        directly by Spectrum. Path is vetted by the base media-safety check.
        """
        address = (chat_id or self._notify_target or "").strip()
        if not address:
            return SendResult(success=False, error="No Photon recipient address")
        safe = self.validate_media_delivery_path(image_path)
        if not safe:
            return SendResult(success=False, error=f"Unsafe or missing media path: {image_path}")
        body: Dict[str, Any] = {"address": address, "attachments": [{"path": safe}]}
        if caption:
            body["text"] = caption
        return await self._post_send(body, timeout=30.0)

    async def send_typing(self, chat_id: str, metadata=None) -> None:
        address = (chat_id or self._notify_target or "").strip()
        if not address:
            return
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                await client.post(
                    f"{self._sidecar}/typing",
                    headers=self._headers,
                    json={"address": address},
                )
        except Exception:
            pass  # typing is best-effort

    async def get_chat_info(self, chat_id: str) -> Dict[str, Any]:
        return {"name": chat_id, "type": "dm", "chat_id": chat_id}


# ---------------------------------------------------------------------------
# Module helpers
# ---------------------------------------------------------------------------


def _resp_message_id(resp) -> str:
    """Best-effort message id from a 2xx sidecar response.

    A 2xx with a non-JSON body must NOT be misreported as a send failure — the
    message went out. Fall back to a generated id (mirrors the ntfy adapter)."""
    try:
        data = resp.json() if resp.content else {}
    except Exception:
        data = {}
    return (data.get("id") if isinstance(data, dict) else None) or uuid.uuid4().hex[:12]


_MIME_EXT = {
    "image/jpeg": ".jpg", "image/jpg": ".jpg", "image/png": ".png", "image/gif": ".gif",
    "image/heic": ".heic", "image/heif": ".heic", "image/webp": ".webp", "image/tiff": ".tiff",
    "audio/mpeg": ".mp3", "audio/mp4": ".m4a", "audio/aac": ".m4a", "audio/ogg": ".ogg",
    "audio/amr": ".amr", "audio/wav": ".wav", "video/mp4": ".mp4", "video/quicktime": ".mov",
    "application/pdf": ".pdf",
}


def _ext_for(mime: str, name: str = "") -> str:
    if name and "." in name:
        e = name[name.rfind("."):].lower()
        if len(e) <= 6:
            return e
    return _MIME_EXT.get((mime or "").lower(), ".bin")


def _parse_ts(value) -> datetime:
    if isinstance(value, str) and value:
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            pass
    return datetime.now(tz=timezone.utc)


def _env_enablement() -> Optional[dict]:
    """Seed ``PlatformConfig.extra`` from env before the adapter is built.

    Lets ``hermes gateway status`` reflect an env-only Photon setup, and provides
    the ``home_channel`` so a bare ``photon`` send target (cron / CC notify)
    resolves to your iMessage handle.
    """
    project_id = os.getenv("PHOTON_PROJECT_ID", "").strip()
    sidecar_url = os.getenv("PHOTON_SIDECAR_URL", "").strip()
    if not (project_id or sidecar_url):
        return None
    seed: dict = {"sidecar_url": _sidecar_url()}
    if project_id:
        seed["project_id"] = project_id
    token = os.getenv("PHOTON_SIDECAR_TOKEN", "").strip()
    if token:
        seed["sidecar_token"] = token
    target = _notify_target()
    if target:
        seed["notify_target"] = target
        seed["home_channel"] = {"chat_id": target, "name": "iMessage"}
    return seed


async def _standalone_send(
    pconfig,
    chat_id: str,
    message: str,
    *,
    thread_id: Optional[str] = None,
    media_files: Optional[List[str]] = None,
    force_document: bool = False,
) -> Dict[str, Any]:
    """Out-of-process send for cron / send_message_tool fallbacks.

    Posts straight to the sidecar, so a ``deliver=photon`` cron job or the Code
    Master ``photon`` notification channel works even when the gateway runner is
    not in this process. ``thread_id`` / ``media_files`` are accepted for
    signature parity (iMessage threading/attachments are not modeled here yet).
    """
    if not HTTPX_AVAILABLE:
        return {"error": "Photon standalone send: httpx not installed"}
    extra = getattr(pconfig, "extra", {}) or {}
    address = (chat_id or "").strip() or _notify_target(extra)
    if not address:
        return {"error": "Photon standalone send: no recipient (set PHOTON_NOTIFY_TARGET)"}
    sidecar = _sidecar_url(extra)
    headers = _auth_headers(extra)
    if len(message) > MAX_MESSAGE_LENGTH:
        message = message[:MAX_MESSAGE_LENGTH]
    payload: Dict[str, Any] = {"address": address, "text": message}
    if media_files:
        # iMessage supports attachments / stacked images — forward local paths
        # (the sidecar runs on the same host) so send_message media reaches Photon.
        payload["attachments"] = [{"path": f} for f in media_files if f]
    last_error = "Photon standalone send failed"
    for attempt in range(SEND_MAX_RETRIES):
        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                resp = await client.post(f"{sidecar}/send", headers=headers, json=payload)
            if resp.status_code < 300:
                break
            last_error = f"Photon HTTP {resp.status_code}: {resp.text[:200]}"
            if resp.status_code not in _RETRYABLE_SEND_STATUS:
                return {"error": last_error}  # 422 / permanent — no retry
        except Exception as e:
            last_error = f"Photon standalone send failed: {e}"
        if attempt < SEND_MAX_RETRIES - 1:
            await asyncio.sleep(SEND_RETRY_BACKOFF[min(attempt, len(SEND_RETRY_BACKOFF) - 1)])
    else:
        return {"error": last_error}
    try:
        return {
            "success": True,
            "platform": "photon",
            "chat_id": address,
            "message_id": _resp_message_id(resp),
        }
    except Exception as e:
        return {"error": f"Photon standalone send failed: {e}"}


def register(ctx) -> None:
    """Plugin entry point — called by the JarvisCopilot plugin system at startup."""
    ctx.register_platform(
        name="photon",
        label="Photon (iMessage)",
        adapter_factory=lambda cfg: PhotonAdapter(cfg),
        check_fn=check_requirements,
        validate_config=validate_config,
        is_connected=is_connected,
        required_env=["PHOTON_PROJECT_ID"],
        install_hint=(
            "Set PHOTON_PROJECT_ID/PHOTON_PROJECT_SECRET and run the Photon "
            "sidecar (plugins/platforms/photon/sidecar)."
        ),
        env_enablement_fn=_env_enablement,
        # cron `deliver=photon` resolves its recipient from this var — the same
        # handle used as the send_message/CC-notify home channel.
        cron_deliver_env_var="PHOTON_NOTIFY_TARGET",
        standalone_sender_fn=_standalone_send,
        allowed_users_env="PHOTON_ALLOWED_USERS",
        allow_all_env="PHOTON_ALLOW_ALL_USERS",
        max_message_length=MAX_MESSAGE_LENGTH,
        emoji="💬",
        platform_hint=(
            "You are communicating over iMessage via Photon. Use plain text — "
            "iMessage does not render markdown. Keep replies concise and "
            "conversational, as if texting."
        ),
    )
