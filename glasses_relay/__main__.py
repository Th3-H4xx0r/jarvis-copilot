"""CLI entry point for the standalone glasses relay: ``python -m glasses_relay``."""
from __future__ import annotations

import argparse
import asyncio
import logging
import sys
from typing import List, Optional

from .config import DEFAULT_PORT, RelayConfig
from .server import RelayServer


def _parse_args(argv: List[str]):
    parser = argparse.ArgumentParser(
        prog="python -m glasses_relay",
        description=(
            "Standalone glasses -> Jarvis voice relay WebSocket server. "
            "Not wired into the webui/gateway; run it as its own process."
        ),
    )
    parser.add_argument(
        "port", nargs="?", type=int, default=None,
        help="TCP port to listen on (default: $JARVIS_RELAY_PORT or %d)" % DEFAULT_PORT,
    )
    parser.add_argument("--host", default=None, help="bind address (default 127.0.0.1)")
    parser.add_argument("--tts", choices=["say", "jarvis"], default=None, help="TTS backend")
    parser.add_argument("--no-warm", action="store_true", help="skip STT warmup at startup")
    parser.add_argument("-v", "--verbose", action="store_true", help="debug logging")
    return parser.parse_args(argv)


def build_config(argv: List[str]) -> RelayConfig:
    args = _parse_args(argv)
    config = RelayConfig.from_sources(port=args.port)
    if args.host:
        config.host = args.host
    if args.tts:
        config.tts_backend = args.tts
    return config, args


def main(argv: Optional[List[str]] = None) -> None:
    argv = list(sys.argv[1:] if argv is None else argv)
    config, args = build_config(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s [glasses_relay] %(message)s",
    )
    server = RelayServer(config)
    try:
        asyncio.run(server.serve_forever(warm=not args.no_warm))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
