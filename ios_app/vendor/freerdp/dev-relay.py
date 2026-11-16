#!/usr/bin/env python3
"""Dev stand-in for the server's iPhone relay (webui/api/rdp_relay.py) while testing against xrdp:
binary WebSocket frames <-> TCP, byte for byte, one TCP connection per WebSocket — and, like the
real one, a TEXT "k" keepalive to the client every 3 s and client TEXT frames dropped.

    python3 ios_app/vendor/freerdp/dev-relay.py [ws_port=8765] [target=127.0.0.1:3391] [--hold-last]

--hold-last mimics the proxy chain in front of the real server: each client frame is held until
the next frame (of any kind) arrives. A client that sends one small frame and waits (FreeRDP's
X.224 connection request) stalls there unless it pushes a TEXT frame after its data.

Pair it with the pinned xrdp container (scripts/dev/xrdp-test.sh's image; user ubuntu / ubuntu) and
point the iPhone client at ws://127.0.0.1:8765/api/rdp/relay/<anything> (the simulator reaches
the Mac's loopback). Dev only — never on the server.
"""
import asyncio
import sys

import websockets

HOLD = "--hold-last" in sys.argv
ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]


async def bridge(ws, target):
    print("ws connected", ws.request.path, "hold" if HOLD else "", flush=True)
    host, port = target.rsplit(":", 1)
    reader, writer = await asyncio.open_connection(host, int(port))
    held = None
    sent = 0

    async def keepalive():
        while True:
            await asyncio.sleep(3)
            await ws.send("k")

    async def ws_to_tcp():
        nonlocal held, sent
        async for msg in ws:
            if HOLD:
                if held is not None:            # the next frame releases the held one
                    writer.write(held)
                    sent += len(held)
                    held = None
                if isinstance(msg, bytes):
                    held = msg
            elif isinstance(msg, bytes):
                writer.write(msg)
                sent += len(msg)
            await writer.drain()                # TEXT frames are keepalives: dropped
        writer.close()

    async def tcp_to_ws():
        while data := await reader.read(65536):
            await ws.send(data)
        await ws.close()

    ka = asyncio.create_task(keepalive())
    await asyncio.gather(ws_to_tcp(), tcp_to_ws(), return_exceptions=True)
    ka.cancel()
    print("ws closed, bytes to target", sent, flush=True)


async def main():
    port = int(ARGS[0]) if ARGS else 8765
    target = ARGS[1] if len(ARGS) > 1 else "127.0.0.1:3391"
    async with websockets.serve(lambda ws: bridge(ws, target), "127.0.0.1", port, max_size=None):
        print(f"dev relay ws://127.0.0.1:{port}/… -> {target}{' (holding the last frame)' if HOLD else ''}", flush=True)
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
