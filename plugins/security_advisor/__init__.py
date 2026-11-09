"""Security Advisor: one always-on watcher for misuse of Jarvis.

Events come from ``security.events.emit()`` (webui, gateway, cron, host sources).
``rules`` classifies them; the worker in the webui process acts on the result.
"""
from __future__ import annotations


def register(ctx) -> None:
    pass
