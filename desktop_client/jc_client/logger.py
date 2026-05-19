"""Rotating file logger + stderr handler for the desktop client.

Logs live at ``<state_dir>/logs/client.log`` with size-based rotation
(5 MB, keep 5 generations). Every module that wants logging does:

    from jc_client.logger import get_logger
    log = get_logger(__name__)

``setup()`` is called once from ``cli.main()`` / ``service.run()``;
re-calling is a no-op so unit tests that import the package don't
double-attach handlers.
"""
from __future__ import annotations

import logging
import logging.handlers
import os
import sys
from pathlib import Path
from typing import Optional


_CONFIGURED = False


def state_dir() -> Path:
    """Per-user state directory for the client.

    Layout:
        ~/.jarviscopilot-client/
            config.yaml          (0600)
            logs/client.log
            jc-client.pid
    """
    base = Path.home() / ".jarviscopilot-client"
    base.mkdir(parents=True, exist_ok=True)
    return base


def setup(*, level: str = "INFO", verbose: bool = False) -> None:
    """Attach file + stderr handlers to the root logger.

    Safe to call multiple times — repeat calls only adjust the level.
    """
    global _CONFIGURED
    root = logging.getLogger()
    if _CONFIGURED:
        root.setLevel(getattr(logging, level.upper(), logging.INFO))
        return

    log_dir = state_dir() / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    log_path = log_dir / "client.log"

    fmt = logging.Formatter(
        fmt="%(asctime)s %(levelname)-7s %(name)s | %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )
    file_h = logging.handlers.RotatingFileHandler(
        log_path, maxBytes=5 * 1024 * 1024, backupCount=5, encoding="utf-8",
    )
    file_h.setFormatter(fmt)
    file_h.setLevel(logging.DEBUG)  # always full detail on disk

    stderr_h = logging.StreamHandler(sys.stderr)
    stderr_h.setFormatter(fmt)
    stderr_h.setLevel(logging.DEBUG if verbose else getattr(logging, level.upper(), logging.INFO))

    root.addHandler(file_h)
    root.addHandler(stderr_h)
    root.setLevel(logging.DEBUG)
    _CONFIGURED = True


def get_logger(name: str) -> logging.Logger:
    return logging.getLogger(name)


def log_path() -> Path:
    return state_dir() / "logs" / "client.log"
