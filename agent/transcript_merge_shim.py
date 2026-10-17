"""Load jc-client's transcript merge on the server.

``desktop_client/jc_client/transcript_merge.py`` is pure stdlib and is the one
definition of how two copies of a transcript merge; the server has no
``jc_client`` install, so it loads the same file by path (the pattern of
``agent/agent_engine_shim.py``).
"""
from __future__ import annotations

import importlib.util
import os
import sys

_NAME = "jarvis_transcript_merge"
_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                     "desktop_client", "jc_client", "transcript_merge.py")


def _load():
    if _NAME not in sys.modules:
        spec = importlib.util.spec_from_file_location(_NAME, _PATH)
        mod = importlib.util.module_from_spec(spec)
        sys.modules[_NAME] = mod
        spec.loader.exec_module(mod)
    return sys.modules[_NAME]


_mod = _load()
merge = _mod.merge
line_id = _mod.line_id
MergeResult = _mod.MergeResult
