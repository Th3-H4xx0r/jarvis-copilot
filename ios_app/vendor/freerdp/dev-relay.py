#!/usr/bin/env python3
"""Dev stand-in for the server's iPhone relay (webui/api/rdp_relay.py) while the PC can't host RDP:
binary WebSocket frames <-> TCP, byte for byte, one connection per WebSocket.

    python3 ios_app/vendor/freerdp/dev-relay.py [ws_port=8765] [target=127.0.0.1:3391]

Pair it with the pinned xrdp container (scripts/dev/xrdp-test.sh's image; user ubuntu / ubuntu) and
point the iPhone client at ws://127.0.0.1:8765/api/rdp/relay/<anything> (the simulator reaches
the Mac's loopback). Dev only — never on the server.
"""
import asyncio
import sys

import websockets


async def bridge(ws, target):
    print("ws connected", getattr(ws, "request", None) and ws.request.path, flush=True)
    host, port = target.rsplit(":", 1)
    reader, writer = await asyncio.open_connection(host, int(port))

    async def ws_to_tcp():
        async for msg in ws:
            writer.write(msg if isinstance(msg, bytes) else msg.encode())
            await writer.drain()
        writer.close()

    async def tcp_to_ws():
        while data := await reader.read(65536):
            await ws.send(data)
        await ws.close()

    await asyncio.gather(ws_to_tcp(), tcp_to_ws(), return_exceptions=True)


async def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    target = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1:3391"
    async with websockets.serve(lambda ws: bridge(ws, target), "127.0.0.1", port, max_size=None):
        print(f"dev relay ws://127.0.0.1:{port}/… -> {target}", flush=True)
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
