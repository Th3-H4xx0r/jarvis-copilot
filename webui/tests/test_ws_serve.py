"""The shared WebSocket read loop (api/ws_upgrade.serve) every server socket runs."""
import json
import socket
import threading

import pytest

wsproto = pytest.importorskip("wsproto")
from wsproto import ConnectionType, WSConnection  # noqa: E402
from wsproto.events import (AcceptConnection, BytesMessage, CloseConnection, Ping, Pong,  # noqa: E402
                            Request, TextMessage)

from api import ws_upgrade  # noqa: E402


def _pair():
    client = WSConnection(ConnectionType.CLIENT)
    server = WSConnection(ConnectionType.SERVER)
    server.receive_data(client.send(Request(host="localhost", target="/x")))
    list(server.events())
    client.receive_data(server.send(AcceptConnection()))
    list(client.events())
    return client, server


def _serve(wire: bytes, **kw):
    client, server = _pair()
    near, far = socket.socketpair()
    texts, blobs = [], []
    done = threading.Thread(target=ws_upgrade.serve, args=(server, far), daemon=True,
                            kwargs=dict(on_text=texts.append, on_bytes=blobs.append,
                                        lock=threading.Lock(), chunk=512, **kw))
    done.start()
    near.sendall(wire(client) if callable(wire) else wire)
    done.join(timeout=5)
    replies = b""
    near.settimeout(0.2)
    try:
        while chunk := near.recv(65536):
            replies += chunk
    except OSError:
        pass
    client.receive_data(replies)
    return texts, blobs, list(client.events()), done.is_alive()


def test_a_message_in_pieces_is_handed_on_whole():
    """A `seg` with a voiceprint is ~3 KB: it straddles socket reads and the client may fragment
    it; a half parsed alone was "not JSON" and the line was lost."""
    message = json.dumps({"t": "seg", "emb": [0.0625] * 256})
    thirds = [message[:1000], message[1000:2000], message[2000:]]

    def wire(client):
        return b"".join(client.send(TextMessage(data=part, message_finished=i == 2))
                        for i, part in enumerate(thirds)) + client.send(CloseConnection(code=1000))

    texts, _, _, running = _serve(wire)
    assert [json.loads(t)["emb"] for t in texts] == [[0.0625] * 256]
    assert not running, "the close handshake ends the loop"


def test_an_oversize_message_is_dropped_and_the_next_still_arrives():
    def wire(client):
        return (client.send(BytesMessage(data=b"x" * 300, message_finished=False))
                + client.send(BytesMessage(data=b"x" * 300))
                + client.send(BytesMessage(data=b"ok"))
                + client.send(CloseConnection(code=1000)))

    _, blobs, _, _ = _serve(wire, max_message=500)
    assert blobs == [b"ok"]


def test_pings_are_answered_and_close_is_echoed():
    def wire(client):
        return client.send(Ping(payload=b"hi")) + client.send(CloseConnection(code=1000))

    _, _, events, running = _serve(wire)
    assert any(isinstance(e, Pong) and e.payload == b"hi" for e in events)
    assert any(isinstance(e, CloseConnection) for e in events)
    assert not running
