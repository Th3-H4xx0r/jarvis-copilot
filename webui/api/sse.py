"""Server-sent events on a BaseHTTPRequestHandler: open the stream, send events, keep it alive."""
import json

HEARTBEAT_SECONDS = 5

# Long-lived SSE and WS connections end this way whenever a tab sleeps or a
# phone changes network. Not errors.
CLIENT_GONE = (
    BrokenPipeError, ConnectionResetError, ConnectionAbortedError,
    TimeoutError, OSError,
)


def open_stream(handler) -> None:
    handler.send_response(200)
    handler.send_header('Content-Type', 'text/event-stream; charset=utf-8')
    handler.send_header('Cache-Control', 'no-cache')
    # nginx buffers proxied responses unless told not to.
    handler.send_header('X-Accel-Buffering', 'no')
    handler.send_header('Connection', 'keep-alive')
    handler.end_headers()


def send(handler, event, data) -> None:
    payload = f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"
    handler.wfile.write(payload.encode('utf-8'))
    handler.wfile.flush()


def keepalive(handler) -> None:
    handler.wfile.write(b': keepalive\n\n')
    handler.wfile.flush()
