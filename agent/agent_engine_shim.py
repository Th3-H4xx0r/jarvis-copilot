"""Load jc-client's agent engine on the server.

The engine (``desktop_client/jc_client/agent_engine.py``) is pure stdlib and
is the single definition of what an agent session's state means. jc-client
imports it as a package module; the server has no ``jc_client`` install, so it
loads the same file by path. One implementation, no hand-kept twin (the old
``classify_pane`` copy drifted).
"""
from __future__ import annotations

import importlib.util
import os
import sys

_NAME = "jarvis_agent_engine"
_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                     "desktop_client", "jc_client", "agent_engine.py")


def _load():
    if _NAME in sys.modules:
        return sys.modules[_NAME]
    spec = importlib.util.spec_from_file_location(_NAME, _PATH)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[_NAME] = mod
    spec.loader.exec_module(mod)
    return mod


def _load_sibling(name, filename):
    if name not in sys.modules:
        path = os.path.join(os.path.dirname(_PATH), filename)
        spec = importlib.util.spec_from_file_location(name, path)
        mod = importlib.util.module_from_spec(spec)
        sys.modules[name] = mod
        spec.loader.exec_module(mod)
    return sys.modules[name]


def load_hook_server():
    """jc-client's HookServer class, loaded by path for the server's own socket."""
    return _load_sibling("jarvis_hook_server", "hook_server.py").HookServer


def load_arbiter():
    """jc-client's approval Arbiter class, for hooks running on this host."""
    return _load_sibling("jarvis_approval_arbiter", "approval_arbiter.py").Arbiter


module = _load()
Engine = module.Engine
session_key = module.session_key
fingerprint = module.fingerprint
diff_from_tool = module.diff_from_tool
step_label = module.step_label
merge_rate_limits = module.merge_rate_limits
