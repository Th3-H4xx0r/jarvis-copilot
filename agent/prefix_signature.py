"""A short fingerprint of the cacheable prompt prefix (system prompt + tools).

Logged on every API call so a provider cache miss names its cause: if two calls
in a session carry different ``sys=`` or ``tools=`` values, that is the miss.
"""
from __future__ import annotations

import hashlib
import json


def _h(text: str) -> str:
    return hashlib.sha1(text.encode("utf-8", "replace")).hexdigest()[:8]


def prefix_signature(api_messages, tools) -> str:
    system = ""
    for m in api_messages or []:
        if isinstance(m, dict) and m.get("role") == "system":
            c = m.get("content")
            system = c if isinstance(c, str) else json.dumps(c, sort_keys=True, default=str)
            break
    return f" sys={_h(system)} tools={_h(json.dumps(tools or [], sort_keys=True, default=str))}"
