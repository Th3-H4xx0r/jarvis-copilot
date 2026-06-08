"""Tests for the bare-minimum HTTP response parser.

Regression coverage for the chunked-transfer-encoding bug: requests to the
tunnel-fronted webui (cloudflared -> nginx -> origin) come back with
``Transfer-Encoding: chunked`` for large bodies (e.g. a full session handoff).
The parser used to return the raw chunk-framed bytes verbatim, so ``.json()``
choked on the leading ``<hexsize>\\r\\n`` and silently returned ``{}`` — which
made ``recall_session_handoff`` look empty even though the server replied with
the data.
"""
import json

from jc_client.protocol import _parse_http_response


def _resp(headers_lines: list[str], body: bytes) -> bytes:
    head = "\r\n".join(["HTTP/1.1 200 OK"] + headers_lines)
    return head.encode("ascii") + b"\r\n\r\n" + body


def test_content_length_body_is_returned_verbatim():
    payload = json.dumps({"entries": [1, 2, 3]}).encode("utf-8")
    raw = _resp([f"Content-Length: {len(payload)}",
                 "Content-Type: application/json"], payload)
    r = _parse_http_response(raw)
    assert r.status == 200
    assert r.json() == {"entries": [1, 2, 3]}


def test_connection_close_framing_still_works():
    payload = b'{"ok": true}'
    raw = _resp(["Content-Type: application/json", "Connection: close"], payload)
    r = _parse_http_response(raw)
    assert r.json() == {"ok": True}


def test_chunked_body_is_dechunked():
    """The core regression: a chunked JSON body must be reassembled."""
    doc = {"slug": "proj", "kind": "sessions",
           "entries": [{"id": "x", "content": "y" * 5000}]}
    payload = json.dumps(doc).encode("utf-8")
    # Split across two chunks + the terminating zero chunk.
    mid = len(payload) // 2
    c1, c2 = payload[:mid], payload[mid:]
    body = (
        f"{len(c1):x}\r\n".encode() + c1 + b"\r\n"
        + f"{len(c2):x}\r\n".encode() + c2 + b"\r\n"
        + b"0\r\n\r\n"
    )
    raw = _resp(["Content-Type: application/json; charset=utf-8",
                 "Transfer-Encoding: chunked"], body)
    r = _parse_http_response(raw)
    assert r.status == 200
    assert r.json() == doc
    assert r.json()["entries"][0]["content"] == "y" * 5000


def test_chunked_with_extension_and_trailer():
    """Chunk extensions (``size;ext``) and trailers must be tolerated."""
    payload = b'{"value": 42}'
    body = (
        f"{len(payload):x};name=value\r\n".encode() + payload + b"\r\n"
        + b"0\r\n"
        + b"X-Trailer: ignored\r\n\r\n"
    )
    raw = _resp(["Transfer-Encoding: chunked"], body)
    r = _parse_http_response(raw)
    assert r.json() == {"value": 42}


def test_chunked_case_insensitive_header():
    payload = b'{"a": 1}'
    body = f"{len(payload):x}\r\n".encode() + payload + b"\r\n0\r\n\r\n"
    raw = _resp(["transfer-encoding: CHUNKED"], body)
    r = _parse_http_response(raw)
    assert r.json() == {"a": 1}
