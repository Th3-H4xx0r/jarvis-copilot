"""Plan 2.2 — native Anthropic fast lane: prompt-cache verification + OAuth auth.

Two things are asserted here, both against the REAL Anthropic SDK driven by a
mock HTTP transport (no network):

1. A two-turn conversation built through JarvisCopilot's own request builder
   (``build_anthropic_kwargs`` + ``apply_anthropic_cache_control``) sends a
   byte-identical cache prefix on turn 2, and the SDK surfaces
   ``usage.cache_read_input_tokens > 0``.  The fake server only reports a cache
   read when the prefix it received really is byte-identical to turn 1's — so a
   silent invalidator (a timestamp/uuid in the system prompt, a reordered tool
   list, …) fails this test instead of silently costing 10x.
2. ``build_anthropic_client`` builds Bearer + Claude-Code identity headers for an
   OAuth token, and x-api-key headers for a console API key.
"""
from __future__ import annotations

import json

import httpx
import pytest

from agent.anthropic_adapter import (
    _OAUTH_ONLY_BETAS,
    build_anthropic_client,
    build_anthropic_kwargs,
)
from agent.prompt_caching import apply_anthropic_cache_control

anthropic = pytest.importorskip("anthropic")


SYSTEM_PROMPT = (
    "You are JarvisCopilot. Conversation started: Thursday, September 04, 2026\n"
    "Be brief."
) * 40  # long enough to look like a real cacheable prefix

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "open_app",
            "description": "Open an application on a paired device.",
            "parameters": {
                "type": "object",
                "properties": {"name": {"type": "string"}},
                "required": ["name"],
            },
        },
    },
]


class _CacheAwareServer:
    """Mock Anthropic Messages endpoint that models real prefix caching.

    Remembers the serialized ``(system, tools)`` prefix of every request it has
    seen; a later request whose prefix matches byte-for-byte is reported as a
    cache READ, anything else as a cache WRITE.
    """

    def __init__(self) -> None:
        self.seen_prefixes: set[str] = set()
        self.requests: list[dict] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content.decode("utf-8"))
        self.requests.append({"headers": dict(request.headers), "body": body})
        prefix = json.dumps(
            {"system": body.get("system"), "tools": body.get("tools")},
            sort_keys=False,
            ensure_ascii=False,
        )
        hit = prefix in self.seen_prefixes
        self.seen_prefixes.add(prefix)
        return httpx.Response(
            200,
            json={
                "id": "msg_test",
                "type": "message",
                "role": "assistant",
                "model": body.get("model", "claude-haiku-4-5"),
                "content": [{"type": "text", "text": "ok"}],
                "stop_reason": "end_turn",
                "stop_sequence": None,
                "usage": {
                    "input_tokens": 5,
                    "output_tokens": 3,
                    "cache_read_input_tokens": 1200 if hit else 0,
                    "cache_creation_input_tokens": 0 if hit else 1200,
                },
            },
        )


def _client(server: _CacheAwareServer) -> "anthropic.Anthropic":
    return anthropic.Anthropic(
        api_key="sk-ant-api-test",
        http_client=httpx.Client(transport=httpx.MockTransport(server)),
    )


def _kwargs_for(messages: list[dict]) -> dict:
    prepared = apply_anthropic_cache_control(
        [{"role": "system", "content": SYSTEM_PROMPT}] + messages,
        native_anthropic=True,
    )
    return build_anthropic_kwargs(
        model="claude-haiku-4-5",
        messages=prepared,
        tools=TOOLS,
        max_tokens=256,
        reasoning_config=None,
    )


class TestFastLaneCacheHit:
    def test_turn_two_reports_cache_read(self):
        server = _CacheAwareServer()
        client = _client(server)

        turn1 = _kwargs_for([{"role": "user", "content": "hi"}])
        r1 = client.messages.create(**turn1)
        assert r1.usage.cache_read_input_tokens == 0, "turn 1 must be a cache write"

        turn2 = _kwargs_for([
            {"role": "user", "content": "hi"},
            {"role": "assistant", "content": "ok"},
            {"role": "user", "content": "and again"},
        ])
        r2 = client.messages.create(**turn2)
        assert r2.usage.cache_read_input_tokens > 0, (
            "turn 2 sent a different system/tools prefix — a silent cache "
            "invalidator is in the request builder"
        )

    def test_system_block_carries_a_cache_control_breakpoint(self):
        kwargs = _kwargs_for([{"role": "user", "content": "hi"}])
        system = kwargs["system"]
        assert isinstance(system, list) and system, "system must be block form"
        assert any(b.get("cache_control") for b in system), (
            "no cache_control breakpoint on the system prompt — nothing is cached"
        )

    def test_tool_order_is_stable_across_turns(self):
        a = _kwargs_for([{"role": "user", "content": "one"}])
        b = _kwargs_for([{"role": "user", "content": "two"}])
        assert [t["name"] for t in a["tools"]] == [t["name"] for t in b["tools"]]
        assert json.dumps(a["tools"]) == json.dumps(b["tools"])


class TestToolListStabilityIsTheRealInvalidator:
    """The one silent invalidator found in the live path (plan 2.2).

    ``tools`` renders BEFORE ``system`` in the cache prefix, so ANY change to it
    invalidates the entire cached conversation. The in-repo lazy loader mutates
    ``agent.tools`` mid-session every time the model calls ``tool_search`` —
    guaranteeing a full cache miss on the turn after every search. Server-side
    tool search (plan 2.3) is the fix: the tool list is fixed for the session and
    the schemas the model pulls never touch the request body.
    """

    def test_a_mid_session_tool_addition_invalidates_everything(self):
        server = _CacheAwareServer()
        client = _client(server)
        msgs = [{"role": "user", "content": "hi"}]

        client.messages.create(**_kwargs_for(msgs))

        grown = TOOLS + [{
            "type": "function",
            "function": {"name": "spotify", "description": "Play music.",
                         "parameters": {"type": "object", "properties": {}}},
        }]
        kwargs = build_anthropic_kwargs(
            model="claude-haiku-4-5",
            messages=apply_anthropic_cache_control(
                [{"role": "system", "content": SYSTEM_PROMPT}] + msgs,
                native_anthropic=True),
            tools=grown, max_tokens=256, reasoning_config=None,
        )
        assert client.messages.create(**kwargs).usage.cache_read_input_tokens == 0

    def test_native_deferral_keeps_the_tool_list_fixed(self):
        """Loading a deferred tool server-side changes nothing in the body."""
        from tools import lazy_tools

        full = TOOLS + [{
            "type": "function",
            "function": {"name": "spotify", "description": "Play music.",
                         "parameters": {"type": "object", "properties": {}}},
        }]
        server = _CacheAwareServer()
        client = _client(server)
        msgs = [{"role": "user", "content": "hi"}]

        def _shaped():
            kwargs = build_anthropic_kwargs(
                model="claude-haiku-4-5",
                messages=apply_anthropic_cache_control(
                    [{"role": "system", "content": SYSTEM_PROMPT}] + msgs,
                    native_anthropic=True),
                tools=full, max_tokens=256, reasoning_config=None,
            )
            kwargs["tools"] = lazy_tools.build_native_deferred_tools(kwargs["tools"])
            return kwargs

        client.messages.create(**_shaped())
        assert client.messages.create(**_shaped()).usage.cache_read_input_tokens > 0


class TestOAuthAuthHeaders:
    def test_oauth_token_uses_bearer_and_claude_code_identity(self):
        client = build_anthropic_client("sk-ant-oat01-" + "x" * 20)
        assert client.auth_headers.get("Authorization", "").startswith("Bearer ")
        assert "X-Api-Key" not in client.auth_headers
        betas = client.default_headers.get("anthropic-beta", "")
        for beta in _OAUTH_ONLY_BETAS:
            assert beta in betas, f"missing OAuth beta {beta}"
        assert client.default_headers.get("user-agent", "").startswith("claude-cli/")
        assert client.default_headers.get("x-app") == "cli"

    def test_console_api_key_uses_x_api_key(self):
        client = build_anthropic_client("sk-ant-api03-" + "y" * 20)
        assert client.auth_headers.get("X-Api-Key")
        assert "Authorization" not in client.auth_headers
        for beta in _OAUTH_ONLY_BETAS:
            assert beta not in client.default_headers.get("anthropic-beta", "")
