"""Tests for the server-side MCP relay transport (Phase 2, 2b).

The JSON-RPC (de)serialization helpers require the ``mcp`` SDK, which lives in
the server runtime env — those tests ``importorskip`` it. The unconnected-device
path needs only ``anyio`` + the bridge module.
"""

import asyncio
import json
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "webui"))


def test_serialize_deserialize_roundtrip():
    pytest.importorskip("mcp")
    from mcp.shared.message import SessionMessage
    from tools.mcp_relay_transport import serialize_session_message, deserialize_frame

    raw = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}})
    sm = deserialize_frame(raw)
    assert isinstance(sm, SessionMessage)
    # Round-trip back to text and confirm the method survived.
    out = serialize_session_message(sm)
    assert json.loads(out)["method"] == "tools/list"
    assert json.loads(out)["id"] == 1


def test_deserialize_bad_json_returns_exception():
    pytest.importorskip("mcp")
    from tools.mcp_relay_transport import deserialize_frame

    out = deserialize_frame("{not valid json")
    assert isinstance(out, Exception)


def test_relay_transport_unconnected_device_raises():
    """No connected device → ConnectionError, and no leaked streams."""
    pytest.importorskip("anyio")
    from tools.mcp_relay_transport import relay_transport

    async def go():
        async with relay_transport("no-such-device") as _streams:
            pass

    with pytest.raises(ConnectionError):
        asyncio.run(go())
