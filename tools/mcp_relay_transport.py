"""Custom MCP transport that tunnels JSON-RPC frames to a Playwright MCP
running on a paired desktop device, over the device bridge (Phase 2, A1).

Mirrors ``mcp.client.stdio.stdio_client`` (mcp 1.27.1): it yields a
``(read_stream, write_stream)`` pair of anyio memory streams carrying
``SessionMessage`` objects, which a normal ``ClientSession`` consumes. Instead
of a local subprocess, the "process" is the remote desktop's Playwright MCP:

  - outbound ``SessionMessage`` → JSON-RPC text → ``mcp_frame`` to the device
  - inbound ``mcp_frame`` (delivered on the bridge *pump thread*) → JSON-RPC
    text → ``SessionMessage`` pushed onto the read stream (marshaled onto the
    asyncio loop via ``call_soon_threadsafe``).

The bridge protocol + ``open_relay``/``relay_send_frame``/``close_relay`` live in
``webui/api/device_bridge.py``; the device side (spawn child, pipe stdio) lives
in the desktop client's ``mcp_relay.py``.
"""

from __future__ import annotations

import asyncio
import logging
from contextlib import asynccontextmanager
from typing import Optional

import anyio

logger = logging.getLogger(__name__)

# How long to wait for the device to report `mcp_ready` (child spawned) before
# giving up on the relay. Generous because `npx @playwright/mcp` may cold-fetch.
_READY_TIMEOUT_S = 45.0


def serialize_session_message(session_message) -> str:
    """A ``SessionMessage`` → one JSON-RPC text line (no trailing newline).

    Matches what ``stdio_client`` writes to a child's stdin.
    """
    return session_message.message.model_dump_json(by_alias=True, exclude_none=True)


def deserialize_frame(data: str):
    """One JSON-RPC text line → ``SessionMessage``, or an ``Exception`` instance
    on parse failure.

    ``stdio_client`` forwards parse errors onto the read stream rather than
    raising, so ``ClientSession`` can handle them; we replicate that — the read
    stream is typed ``SessionMessage | Exception``.
    """
    from mcp.shared.message import SessionMessage
    from mcp import types
    try:
        message = types.JSONRPCMessage.model_validate_json(data)
    except Exception as exc:  # noqa: BLE001 — forwarded onto the read stream
        return exc
    return SessionMessage(message)


@asynccontextmanager
async def relay_transport(device_id: str, meta: Optional[dict] = None, *,
                          read_buffer: int = 512):
    """Yield ``(read_stream, write_stream)`` bridged to a desktop Playwright MCP.

    Raises ``ConnectionError`` if the device isn't connected, or
    ``TimeoutError`` if it never reports ``mcp_ready``.
    """
    from api import device_bridge

    loop = asyncio.get_running_loop()

    # read: we push inbound msgs into read_stream_writer; ClientSession reads read_stream.
    read_stream_writer, read_stream = anyio.create_memory_object_stream(read_buffer)
    # write: ClientSession writes into write_stream; we drain write_stream_reader → device.
    write_stream, write_stream_reader = anyio.create_memory_object_stream(0)

    ready_event = asyncio.Event()
    state = {"error": None}

    def _on_frame(data: str):
        # Called on the bridge pump thread — marshal onto the asyncio loop.
        # Use a *blocking* send (not send_nowait): if the consumer briefly
        # stalls and the buffer fills, this applies backpressure rather than
        # DROPPING an RPC frame — a dropped response would hang the awaiting
        # ClientSession request forever. run_coroutine_threadsafe preserves FIFO
        # order; we consume the future's exception so a closed stream during
        # teardown doesn't emit "exception never retrieved" noise.
        msg = deserialize_frame(data)
        try:
            fut = asyncio.run_coroutine_threadsafe(read_stream_writer.send(msg), loop)
        except RuntimeError:
            return  # loop closed (shutdown) — nothing to deliver to
        fut.add_done_callback(lambda f: f.exception())

    def _on_event(kind: str, payload: dict):
        if kind == "ready":
            loop.call_soon_threadsafe(ready_event.set)
            return
        # error / closed → unblock everyone and let ClientSession see the stream end.
        state["error"] = payload.get("error") or kind

        def _teardown():
            try:
                read_stream_writer.close()
            except Exception:
                pass
            ready_event.set()

        loop.call_soon_threadsafe(_teardown)

    session_id = device_bridge.open_relay(
        device_id, on_frame=_on_frame, on_event=_on_event, meta=meta or {}
    )
    if not session_id:
        for stream in (read_stream_writer, write_stream, read_stream, write_stream_reader):
            try:
                stream.close()
            except Exception:
                pass
        raise ConnectionError(f"device {device_id!r} not connected for MCP relay")

    async def _writer():
        try:
            async with write_stream_reader:
                async for session_message in write_stream_reader:
                    data = serialize_session_message(session_message)
                    if not device_bridge.relay_send_frame(device_id, session_id, data):
                        break
        except anyio.ClosedResourceError:
            pass
        except Exception as exc:  # noqa: BLE001
            logger.debug("relay writer for %s ended: %s", device_id, exc)

    try:
        async with anyio.create_task_group() as tg:
            tg.start_soon(_writer)
            # Wait for the desktop child to be live before handing streams to
            # ClientSession (so the initialize request isn't dropped).
            try:
                await asyncio.wait_for(ready_event.wait(), timeout=_READY_TIMEOUT_S)
            except asyncio.TimeoutError:
                raise TimeoutError(
                    f"desktop {device_id!r} did not start its Playwright MCP in time"
                )
            if state["error"]:
                raise ConnectionError(f"desktop relay error: {state['error']}")
            try:
                yield read_stream, write_stream
            finally:
                tg.cancel_scope.cancel()
    finally:
        device_bridge.close_relay(device_id, session_id)
        for stream in (read_stream_writer, write_stream, read_stream, write_stream_reader):
            try:
                stream.close()
            except Exception:
                pass
