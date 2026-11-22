"""Deterministic, hermetic protocol tests for the standalone glasses relay.

A real in-process ``websockets`` client drives a real ``RelayServer`` bound to an
ephemeral port (127.0.0.1:0). STT, brain and TTS are injected FAKES that return
fixed values — no models, no network, no API keys — so these tests assert the
wire protocol behavior, not model output.
"""
from __future__ import annotations

import asyncio
import json
import logging
import re
import threading
import time

import pytest
import websockets

from glasses_relay.config import RelayConfig
from glasses_relay.server import RelayServer

# One 40 ms frame of fake 16 kHz mono PCM16 = 640 samples * 2 bytes = 1280 bytes.
PCM_FRAME = b"\x11\x22" * 640
MIC_AUDIO = PCM_FRAME * 10            # ~400 ms of fake mic audio

FAKE_TRANSCRIPT = "hey jarvis what time is it"
FAKE_ANSWER = "It is almost noon."
FAKE_REPLY_PCM = PCM_FRAME * 3       # 3 frames of fake reply audio


def _fake_transcriber(pcm16: bytes) -> str:
    return FAKE_TRANSCRIPT


def _fake_brain(transcript: str) -> str:
    return FAKE_ANSWER


def _fake_synth(text: str) -> bytes:
    return FAKE_REPLY_PCM


async def _start_server(
    *,
    transcriber=_fake_transcriber,
    brain=_fake_brain,
    synthesizer=_fake_synth,
    **cfg_over,
):
    """Start a relay on an ephemeral port; return (relay, server, ws_uri)."""
    cfg = RelayConfig(host="127.0.0.1", port=0, realtime_pacing=False, **cfg_over)
    relay = RelayServer(cfg, transcriber=transcriber, brain=brain, synthesizer=synthesizer)
    server = await relay.start()
    port = server.sockets[0].getsockname()[1]
    uri = "ws://127.0.0.1:{}{}".format(port, cfg.path)
    return relay, server, uri


async def _recv(ws, timeout=5.0):
    return await asyncio.wait_for(ws.recv(), timeout)


async def _recv_json(ws, timeout=5.0):
    msg = await _recv(ws, timeout)
    assert not isinstance(msg, (bytes, bytearray)), "expected text frame, got binary"
    return json.loads(msg)


async def _await_flag(flag: threading.Event, timeout=5.0):
    deadline = time.monotonic() + timeout
    while not flag.is_set():
        if time.monotonic() > deadline:
            raise AssertionError("background flag was not set within {}s".format(timeout))
        await asyncio.sleep(0.01)


def _run(coro):
    asyncio.run(coro)


# ---------------------------------------------------------------------------
# Happy path: a committed turn yields ready -> reply.start -> PCM -> reply.done
# ---------------------------------------------------------------------------
def test_committed_turn_streams_reply_audio_and_text():
    async def scenario():
        relay, server, uri = await _start_server()
        try:
            async with websockets.connect(uri) as ws:
                assert await _recv_json(ws) == {"type": "ready"}

                await ws.send(json.dumps({"type": "turn.start", "interactionId": 1}))
                await ws.send(MIC_AUDIO)
                await ws.send(json.dumps({"type": "turn.commit", "interactionId": 1}))

                start = await _recv_json(ws)
                assert start["type"] == "reply.start"
                assert start["kind"] == "turn"
                assert start["interactionId"] == 1
                rid = start["replyId"]

                frames = 0
                done = None
                while True:
                    msg = await _recv(ws)
                    if isinstance(msg, (bytes, bytearray)):
                        frames += 1
                        assert len(msg) % 2 == 0  # PCM16 => even byte count
                        continue
                    done = json.loads(msg)
                    break

                assert frames >= 1
                assert done["type"] == "reply.done"
                assert done["replyId"] == rid
                assert done["interactionId"] == 1
                assert done["kind"] == "turn"
                assert done["nothingSaid"] is False
                assert done["text"] == FAKE_ANSWER
                assert done["firstAudioMs"] >= 1
        finally:
            server.close()
            await server.wait_closed()

    _run(scenario())


# ---------------------------------------------------------------------------
# turn.check -> turn.verdict(complete=True)
# ---------------------------------------------------------------------------
def test_turn_check_returns_complete_verdict():
    async def scenario():
        relay, server, uri = await _start_server()
        try:
            async with websockets.connect(uri) as ws:
                assert await _recv_json(ws) == {"type": "ready"}
                await ws.send(json.dumps({"type": "turn.check", "interactionId": 7}))
                verdict = await _recv_json(ws)
                assert verdict["type"] == "turn.verdict"
                assert verdict["interactionId"] == 7
                assert verdict["complete"] is True
                assert verdict["probability"] == 1.0
        finally:
            server.close()
            await server.wait_closed()

    _run(scenario())


# ---------------------------------------------------------------------------
# Empty transcript (nothing intelligible) -> reply.done(nothingSaid=True)
# ---------------------------------------------------------------------------
def test_empty_transcript_reports_nothing_said():
    async def scenario():
        relay, server, uri = await _start_server(transcriber=lambda pcm: "")
        try:
            async with websockets.connect(uri) as ws:
                assert await _recv_json(ws) == {"type": "ready"}
                await ws.send(json.dumps({"type": "turn.start", "interactionId": 3}))
                await ws.send(MIC_AUDIO)
                await ws.send(json.dumps({"type": "turn.commit", "interactionId": 3}))

                start = await _recv_json(ws)
                assert start["type"] == "reply.start"
                assert start["interactionId"] == 3
                done = await _recv_json(ws)
                assert done["type"] == "reply.done"
                assert done["nothingSaid"] is True
                assert done["text"] == ""
        finally:
            server.close()
            await server.wait_closed()

    _run(scenario())


# ---------------------------------------------------------------------------
# turn.cancel / turn.resume stop an in-flight reply (brain blocked mid-turn).
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("stop_type", ["turn.cancel", "turn.resume"])
def test_stop_drops_in_flight_reply(stop_type):
    entered = threading.Event()
    release = threading.Event()

    def blocking_brain(transcript: str) -> str:
        entered.set()
        release.wait(timeout=10)
        return FAKE_ANSWER

    async def scenario():
        relay, server, uri = await _start_server(brain=blocking_brain)
        try:
            async with websockets.connect(uri) as ws:
                assert await _recv_json(ws) == {"type": "ready"}
                await ws.send(json.dumps({"type": "turn.start", "interactionId": 2}))
                await ws.send(MIC_AUDIO)
                await ws.send(json.dumps({"type": "turn.commit", "interactionId": 2}))

                # Reply is now in-flight: STT ran, brain is blocked.
                await _await_flag(entered)

                # Stop it mid-flight, then prove the server is still responsive
                # and never emitted a reply for the cancelled turn.
                await ws.send(json.dumps({"type": stop_type, "interactionId": 2}))
                await ws.send(json.dumps({"type": "turn.check", "interactionId": 99}))

                nxt = await _recv_json(ws)
                assert nxt["type"] == "turn.verdict", (
                    "cancelled reply leaked a {} frame".format(nxt.get("type"))
                )
                assert nxt["interactionId"] == 99
                assert nxt["complete"] is True
        finally:
            release.set()
            server.close()
            await server.wait_closed()

    _run(scenario())


# ---------------------------------------------------------------------------
# Each reply logs what was heard and said: scripts/glasses-sim.sh parses this
# line to print "You: ... -> Jarvis: ..." (a contract, not a snapshot).
# ---------------------------------------------------------------------------
_TURN_LOG = re.compile(r'turn (r\d+) heard=(".*?") said=(".*") first_audio_ms=(\d+)$')
APOSTROPHE_ANSWER = "It's \"almost\" noon."


def test_reply_logs_heard_and_said(caplog):
    async def scenario():
        relay, server, uri = await _start_server(brain=lambda t: APOSTROPHE_ANSWER)
        try:
            async with websockets.connect(uri) as ws:
                assert await _recv_json(ws) == {"type": "ready"}
                await ws.send(json.dumps({"type": "turn.start", "interactionId": 4}))
                await ws.send(MIC_AUDIO)
                await ws.send(json.dumps({"type": "turn.commit", "interactionId": 4}))
                while True:
                    msg = await _recv(ws)
                    if not isinstance(msg, (bytes, bytearray)) and json.loads(msg)["type"] == "reply.done":
                        break
        finally:
            server.close()
            await server.wait_closed()

    with caplog.at_level(logging.INFO, logger="glasses_relay"):
        _run(scenario())
    matches = [_TURN_LOG.search(r.getMessage()) for r in caplog.records]
    matches = [m for m in matches if m]
    assert matches, "no turn log line among: {}".format([r.getMessage() for r in caplog.records])
    rid, heard, said, first_ms = matches[-1].groups()
    assert rid == "r1"
    assert json.loads(heard) == FAKE_TRANSCRIPT
    assert json.loads(said) == APOSTROPHE_ANSWER  # quotes survive the round trip
    assert int(first_ms) >= 1


def test_nothing_said_turn_logs_empty_line(caplog):
    async def scenario():
        relay, server, uri = await _start_server(transcriber=lambda pcm: "")
        try:
            async with websockets.connect(uri) as ws:
                assert await _recv_json(ws) == {"type": "ready"}
                await ws.send(json.dumps({"type": "turn.start", "interactionId": 5}))
                await ws.send(MIC_AUDIO)
                await ws.send(json.dumps({"type": "turn.commit", "interactionId": 5}))
                await _recv_json(ws)  # reply.start
                await _recv_json(ws)  # reply.done
        finally:
            server.close()
            await server.wait_closed()

    with caplog.at_level(logging.INFO, logger="glasses_relay"):
        _run(scenario())
    matches = [m for m in (_TURN_LOG.search(r.getMessage()) for r in caplog.records) if m]
    assert matches
    _, heard, said, first_ms = matches[-1].groups()
    assert (json.loads(heard), json.loads(said), first_ms) == ("", "", "0")


def test_failed_reply_logs_reason(caplog):
    def broken_brain(transcript: str) -> str:
        raise RuntimeError("No LLM provider configured")

    async def scenario():
        relay, server, uri = await _start_server(brain=broken_brain)
        try:
            async with websockets.connect(uri) as ws:
                assert await _recv_json(ws) == {"type": "ready"}
                await ws.send(json.dumps({"type": "turn.start", "interactionId": 6}))
                await ws.send(MIC_AUDIO)
                await ws.send(json.dumps({"type": "turn.commit", "interactionId": 6}))
                done = await _recv_json(ws)
                assert done["type"] == "reply.done"
        finally:
            server.close()
            await server.wait_closed()

    with caplog.at_level(logging.INFO, logger="glasses_relay"):
        _run(scenario())
    reasons = [re.search(r"turn (r\d+) failed: (.*)$", r.getMessage()) for r in caplog.records]
    reasons = [m for m in reasons if m]
    assert reasons, [r.getMessage() for r in caplog.records]
    assert reasons[-1].group(2) == "RuntimeError: No LLM provider configured"
