"""Harness graphs: the shape, and the one validator phone, web and server share.

The schema lives in ``agent.harness.schema`` so the scheduler (gateway process)
validates the same way without importing the web UI; this module re-exports it
and teaches the core the web UI's ``@provider:model`` splitter (the one that
knows every catalog provider id).
"""
from __future__ import annotations

import api.config  # noqa: F401  (puts the JarvisCopilot checkout on sys.path for agent.*)
from agent.harness import refs as _refs
from agent.harness.schema import (  # noqa: F401  (re-exported)
    AFTER_KINDS,
    DELIVER_BACKGROUND,
    DELIVER_REVIEW,
    NODE_TYPES,
    ROUTE_MATCHES,
    TOOLS_PRESETS,
    _ID_RE,
    _MAX_NODES,
    _clean_node,
    _err,
    _is_decision_ref,
    _num,
    _pickable,
    _tools_ok,
    parse_when,
    validate_harness,
)


def _webui_split(ref):
    from api.config import split_provider_qualified_model
    return split_provider_qualified_model(ref)


_refs.register_splitter(_webui_split)
