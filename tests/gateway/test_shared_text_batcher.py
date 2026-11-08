"""The client-split text batcher shared by Telegram and Discord (base adapter).

Before it was shared, Telegram lacked Discord's shield around the dispatch
(a follow-up chunk cancelled the running agent turn) and Discord lacked
Telegram's adaptive delay tiers.
"""

import asyncio
from unittest.mock import AsyncMock

import pytest

from gateway.config import Platform, PlatformConfig
from gateway.platforms.base import MessageEvent, MessageType, SessionSource


def _event(text: str, platform: Platform) -> MessageEvent:
    return MessageEvent(
        text=text,
        message_type=MessageType.TEXT,
        source=SessionSource(platform=platform, chat_id="1", chat_type="dm"),
    )


def _adapter(platform: Platform, *, delay: float = 0.1, split_delay: float = 0.3):
    if platform is Platform.TELEGRAM:
        from gateway.platforms.telegram import TelegramAdapter as cls
    else:
        from plugins.platforms.discord.adapter import DiscordAdapter as cls
    adapter = object.__new__(cls)
    adapter.platform = platform
    adapter.config = PlatformConfig(enabled=True, token="t")
    adapter._pending_text_batches = {}
    adapter._pending_text_batch_tasks = {}
    adapter._text_batch_delay_seconds = delay
    adapter._text_batch_split_delay_seconds = split_delay
    adapter.handle_message = AsyncMock()
    return adapter


@pytest.mark.asyncio
@pytest.mark.parametrize("platform", [Platform.TELEGRAM, Platform.DISCORD])
async def test_follow_up_chunk_does_not_cancel_running_dispatch(platform):
    adapter = _adapter(platform, delay=0.01)
    started, release = asyncio.Event(), asyncio.Event()
    cancelled, completed = asyncio.Event(), asyncio.Event()
    calls = []

    async def slow_handle(event):
        calls.append(event.text)
        if len(calls) == 1:
            started.set()
            try:
                await release.wait()
                completed.set()
            except asyncio.CancelledError:
                cancelled.set()
                raise

    adapter.handle_message = slow_handle
    adapter._enqueue_text_event(_event("first", platform))
    await asyncio.wait_for(started.wait(), timeout=1.0)

    adapter._enqueue_text_event(_event("second", platform))
    await asyncio.sleep(0.05)
    assert not cancelled.is_set()

    release.set()
    await asyncio.wait_for(completed.wait(), timeout=1.0)
    await asyncio.sleep(0.05)
    assert calls == ["first", "second"]
    assert not adapter._pending_text_batch_tasks


@pytest.mark.parametrize("platform", [Platform.TELEGRAM, Platform.DISCORD])
def test_adaptive_tiers_apply_on_both_platforms(platform):
    adapter = _adapter(platform, delay=0.6, split_delay=2.0)
    short = _event("hi", platform)
    short._last_chunk_len = 2
    medium = _event("x" * 600, platform)
    medium._last_chunk_len = 600
    long = _event("x" * 1500, platform)
    long._last_chunk_len = 1500
    assert adapter._text_batch_delay_for(short) == adapter._TEXT_BATCH_FAST_DELAY_S
    assert adapter._text_batch_delay_for(medium) == adapter._TEXT_BATCH_SHORT_DELAY_S
    if long._last_chunk_len < adapter._SPLIT_THRESHOLD:
        assert adapter._text_batch_delay_for(long) == 0.6


@pytest.mark.parametrize("platform", [Platform.TELEGRAM, Platform.DISCORD])
def test_split_threshold_is_per_platform(platform):
    adapter = _adapter(platform, delay=0.6, split_delay=2.0)
    near_limit = _event("x" * adapter._SPLIT_THRESHOLD, platform)
    near_limit._last_chunk_len = adapter._SPLIT_THRESHOLD
    below = _event("x" * (adapter._SPLIT_THRESHOLD - 1), platform)
    below._last_chunk_len = adapter._SPLIT_THRESHOLD - 1
    assert adapter._text_batch_delay_for(near_limit) == 2.0
    assert adapter._text_batch_delay_for(below) != 2.0


def test_thresholds_follow_each_platform_limit():
    from gateway.platforms.telegram import TelegramAdapter
    from plugins.platforms.discord.adapter import DiscordAdapter

    for cls in (TelegramAdapter, DiscordAdapter):
        assert 0 < cls._SPLIT_THRESHOLD <= cls.MAX_MESSAGE_LENGTH
