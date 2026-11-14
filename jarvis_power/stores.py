"""Small helpers wrappers use to keep a feature's settings where they already live."""
from __future__ import annotations

import os
from typing import Any, Optional


def config_get(dotted: str, default: Any = None) -> Any:
    """A value from config.yaml by ``section.key`` path."""
    try:
        from jarviscopilot_cli.config import load_config_readonly
        node: Any = load_config_readonly()
    except Exception:
        return default
    for part in dotted.split("."):
        if not isinstance(node, dict) or part not in node:
            return default
        node = node[part]
    return node


def config_set(dotted: str, value: Any) -> None:
    from jarviscopilot_cli.config import load_config, save_config
    cfg = load_config()
    node = cfg
    parts = dotted.split(".")
    for part in parts[:-1]:
        if not isinstance(node.get(part), dict):
            node[part] = {}
        node = node[part]
    node[parts[-1]] = value
    save_config(cfg)


def env_get(key: str) -> Optional[str]:
    value = os.getenv(key)
    if value:
        return value
    try:
        from jarviscopilot_cli.config import get_env_value
        return get_env_value(key) or None
    except Exception:
        return None


def env_set(key: str, value: Optional[str]) -> None:
    """Write a secret to .env (and this process). None or "" removes it."""
    from jarviscopilot_cli.config import remove_env_value, save_env_value
    if value:
        save_env_value(key, value)
        os.environ[key] = value
    else:
        remove_env_value(key)
        os.environ.pop(key, None)
