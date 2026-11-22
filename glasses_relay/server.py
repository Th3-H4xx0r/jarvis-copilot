"""Standalone glasses -> Jarvis voice relay WebSocket server.

Speaks the Meta glasses relay contract on ``/v1/glasses/realtime``: it buffers
16 kHz mono PCM16 mic audio between ``turn.start`` and ``turn.commit``, then runs
STT -> brain -> TTS and streams the reply back as ``reply.start`` / binary PCM16
frames / ``reply.done``.

Protocol (byte-for-byte compatible with the relay):

  relay -> server
    text  {"type":"turn.start"|"turn.commit"|"turn.cancel"|"turn.resume"
                   |"turn.close"|"turn.check","interactionId":X}
    text  {"type":"proactive.result","replyId":X,"played":bool}
    binary 16 kHz mono PCM16 mic audio
    (optional)  Authorization: Bearer <token>
  server -> relay
    {"type":"ready"}
    {"type":"reply.start","replyId":X,"kind":"turn","interactionId":X}
    binary 16 kHz mono PCM16 reply audio
    {"type":"reply.done","replyId":X,"kind":"turn","interactionId":X,
     "text":"...","nothingSaid":bool,"firstAudioMs":N}
    {"type":"turn.verdict","interactionId":X,"complete":bool,"probability":N}
        (answers turn.check)

STANDALONE: this imports nothing from the webui/gateway request path and is
never wired into the running agent (prompt-caching policy). Run it as its own
process with ``python -m glasses_relay``.

STT, brain and TTS are dependency-injected (see ``glasses_relay.interfaces``);
the real defaults in ``glasses_relay.backends`` lazy-load their heavy deps, so a
test can inject fakes and run with no models, network, or API keys.
"""
from __future__ import annotations

import asyncio
import json
import logging
import time
import traceback
from typing import Optional

import websockets

from . import backends
from .config import FRAME_BYTES, FRAME_SEC, RelayConfig
from .interfaces import Brain, Synthesizer, Transcriber

logger = logging.getLogger("glasses_relay")


class _ConnState:
    """Per-connection mic buffer + in-flight reply bookkeeping."""

    def __init__(self) -> None:
        self.iid = None
        self.mic = bytearray()
        self.reply_n = 0
        self.reply_task: Optional[asyncio.Task] = None
        self.commit_ts: Optional[float] = None
        self.cancel = asyncio.Event()

    async def cancel_reply(self) -> None:
        """Cancel any in-flight reply and reset the cancel flag for the next one."""
        task = self.reply_task
        if task and not task.done():
            self.cancel.set()
            task.cancel()
            try:
                await task
            except BaseException:
                pass
        self.reply_task = None
        self.cancel = asyncio.Event()


async def _send_json(ws, obj) -> None:
    try:
        await ws.send(json.dumps(obj))
    except Exception:
        pass


class RelayServer:
    """A glasses relay server with dependency-injected STT / brain / TTS.

    Pass ``transcriber``, ``brain`` and ``synthesizer`` callables to override the
    real defaults (used by tests). Omit them to build the real defaults from
    ``config`` lazily.
    """

    def __init__(
        self,
        config: Optional[RelayConfig] = None,
        *,
        transcriber: Optional[Transcriber] = None,
        brain: Optional[Brain] = None,
        synthesizer: Optional[Synthesizer] = None,
    ) -> None:
        self.config = config or RelayConfig()
        self._transcriber: Transcriber = transcriber or backends.default_transcriber(self.config)
        self._brain: Brain = brain or backends.default_brain(self.config)
        self._synthesizer: Synthesizer = synthesizer or backends.default_synthesizer(self.config)

    # -- sync backends run in the default executor so the loop stays free --
    async def _transcribe(self, pcm: bytes) -> str:
        return await asyncio.get_event_loop().run_in_executor(None, self._transcriber, pcm)

    async def _think(self, transcript: str) -> str:
        return await asyncio.get_event_loop().run_in_executor(None, self._brain, transcript)

    async def _synthesize(self, text: str) -> bytes:
        return await asyncio.get_event_loop().run_in_executor(None, self._synthesizer, text)

    async def _do_reply(self, ws, conn: _ConnState, iid, pcm: bytes, cancel: asyncio.Event) -> None:
        """STT -> brain -> TTS -> stream the answer back for one committed turn."""
        conn.reply_n += 1
        rid = "r{}".format(conn.reply_n)
        t_commit = conn.commit_ts or time.time()
        try:
            transcript = await self._transcribe(pcm)
            if not transcript:
                await _send_json(ws, {"type": "reply.start", "replyId": rid, "kind": "turn",
                                      "interactionId": iid})
                await _send_json(ws, {"type": "reply.done", "replyId": rid, "kind": "turn",
                                      "interactionId": iid, "text": "", "nothingSaid": True,
                                      "firstAudioMs": 0})
                return
            if cancel.is_set():
                return
            reply_text = await self._think(transcript)
            if not reply_text:
                reply_text = "Sorry, I did not catch that."
            if cancel.is_set():
                return
            audio = await self._synthesize(reply_text)
            if cancel.is_set():
                return

            await _send_json(ws, {"type": "reply.start", "replyId": rid, "kind": "turn",
                                  "interactionId": iid})
            first_audio_ms = 0
            for off in range(0, len(audio), FRAME_BYTES):
                if cancel.is_set():
                    logger.debug("reply %s cancelled mid-stream", rid)
                    return
                await ws.send(bytes(audio[off:off + FRAME_BYTES]))
                if first_audio_ms == 0:
                    first_audio_ms = max(1, int((time.time() - t_commit) * 1000))
                if self.config.realtime_pacing:
                    await asyncio.sleep(FRAME_SEC)
            await _send_json(ws, {"type": "reply.done", "replyId": rid, "kind": "turn",
                                  "interactionId": iid, "text": reply_text,
                                  "nothingSaid": False, "firstAudioMs": first_audio_ms})
        except asyncio.CancelledError:
            return
        except Exception:
            logger.warning("reply %s failed:\n%s", rid, traceback.format_exc())
            await _send_json(ws, {"type": "reply.done", "replyId": rid, "kind": "turn",
                                  "interactionId": iid, "text": "Sorry, something went wrong.",
                                  "nothingSaid": False, "firstAudioMs": 0})

    def _authorized(self, ws) -> bool:
        if not self.config.token:
            return True
        req = getattr(ws, "request", None)
        try:
            auth = req.headers.get("Authorization", "") if req else ""
        except Exception:
            auth = ""
        return auth == "Bearer " + self.config.token

    async def handle(self, ws) -> None:
        """Handle one relay WebSocket connection for its lifetime."""
        req = getattr(ws, "request", None)
        path = getattr(req, "path", "/") if req else "/"
        if not self._authorized(ws):
            logger.info("reject %s: bad/absent bearer token", path)
            await ws.close(code=1008, reason="unauthorized")
            return
        logger.debug("connect path=%s", path)
        await _send_json(ws, {"type": "ready"})
        conn = _ConnState()
        try:
            async for msg in ws:
                if isinstance(msg, (bytes, bytearray)):
                    conn.mic += msg
                    continue
                try:
                    m = json.loads(msg)
                except Exception:
                    continue
                t = m.get("type")
                iid = m.get("interactionId")
                if t == "turn.start":
                    await conn.cancel_reply()
                    conn.iid = iid
                    conn.mic = bytearray()
                elif t == "turn.check":
                    await _send_json(ws, {"type": "turn.verdict", "interactionId": iid,
                                          "complete": True, "probability": 1.0})
                elif t == "turn.commit":
                    conn.commit_ts = time.time()
                    pcm = bytes(conn.mic)
                    await conn.cancel_reply()
                    cancel = conn.cancel
                    conn.reply_task = asyncio.create_task(
                        self._do_reply(ws, conn, iid, pcm, cancel)
                    )
                elif t == "turn.resume":
                    await conn.cancel_reply()
                elif t == "turn.cancel":
                    await conn.cancel_reply()
                    conn.mic = bytearray()
                elif t == "turn.close":
                    conn.mic = bytearray()
                elif t == "proactive.result":
                    pass
        except websockets.ConnectionClosed:
            pass
        finally:
            await conn.cancel_reply()
            logger.debug("disconnect path=%s", path)

    async def start(self):
        """Start the WS server and return the (already-serving) websockets Server.

        Bind ``config.port = 0`` for an ephemeral port; read the bound port from
        ``server.sockets[0].getsockname()``.
        """
        cfg = self.config
        return await websockets.serve(
            self.handle, cfg.host, cfg.port, max_size=cfg.max_audio_bytes
        )

    async def warm(self) -> None:
        """Best-effort warmup of the real STT model (no-op with injected fakes)."""
        try:
            await asyncio.get_event_loop().run_in_executor(None, backends.warm_stt)
        except Exception:
            logger.debug("warm skipped", exc_info=True)

    async def serve_forever(self, *, warm: bool = True) -> None:
        """Warm (optional), start, and serve until cancelled/interrupted."""
        if warm:
            await self.warm()
        server = await self.start()
        host, port = server.sockets[0].getsockname()[:2]
        logger.info(
            "glasses relay listening on ws://%s:%d%s (stt_model=%s, tts=%s)",
            host, port, self.config.path, self.config.stt_model or "default",
            self.config.tts_backend,
        )
        try:
            await asyncio.Future()
        finally:
            server.close()
            await server.wait_closed()
