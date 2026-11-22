"""Standalone glasses -> Jarvis voice relay (WebSocket).

Public API::

    from glasses_relay import RelayServer, RelayConfig
    from glasses_relay.interfaces import Transcriber, Brain, Synthesizer

Run as a process::

    python -m glasses_relay [port] [--host H] [--tts say|jarvis] [--no-warm]

This package is deliberately NOT imported by the webui or gateway request path
(prompt-caching policy); it is a separately-run server. See
``glasses_relay/server.py`` for the wire protocol and ``glasses_relay/__main__.py``
for the CLI.
"""
from .config import RelayConfig
from .interfaces import Brain, Synthesizer, Transcriber
from .server import RelayServer

__all__ = ["RelayConfig", "RelayServer", "Transcriber", "Brain", "Synthesizer"]
