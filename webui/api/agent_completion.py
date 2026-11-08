"""One side request on a chat agent's own transport: no tools, no reasoning, and
nothing added to the agent's history. Used for session titles and handoff summaries."""


def complete(agent, system_prompt: str, user_text: str, *, max_tokens: int, reason: str,
             temperature: float, timeout: float, cap_codex_output: bool = True,
             extra_body: dict | None = None):
    """Return ``(text, response)``.

    ``response`` is the chat-completions response (for its finish reason and
    reasoning fields); it is None on the Codex and Anthropic transports, which
    hand back a normalized message. ``cap_codex_output`` False leaves a Codex
    request's own output budget alone (only replacing one it already sets)."""
    messages = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": user_text},
    ]
    disabled_reasoning = {"enabled": False}
    previous_reasoning = getattr(agent, "reasoning_config", None)
    agent.reasoning_config = disabled_reasoning
    try:
        api_mode = getattr(agent, "api_mode", "")
        if api_mode == "codex_responses":
            kwargs = agent._build_api_kwargs(messages)
            kwargs.pop("tools", None)
            if cap_codex_output or "max_output_tokens" in kwargs:
                kwargs["max_output_tokens"] = max_tokens
            message, _ = agent._normalize_codex_response(agent._run_codex_stream(kwargs))
            return str((message.content or "") if message else "").strip(), None

        if api_mode == "anthropic_messages":
            from agent.anthropic_adapter import build_anthropic_kwargs, normalize_anthropic_response
            kwargs = build_anthropic_kwargs(
                model=agent.model,
                messages=messages,
                tools=None,
                max_tokens=max_tokens,
                reasoning_config=disabled_reasoning,
                is_oauth=getattr(agent, "_is_anthropic_oauth", False),
                preserve_dots=agent._anthropic_preserve_dots(),
                base_url=getattr(agent, "_anthropic_base_url", None),
            )
            message, _ = normalize_anthropic_response(
                agent._anthropic_messages_create(kwargs),
                strip_tool_prefix=getattr(agent, "_is_anthropic_oauth", False),
            )
            return str((message.content or "") if message else "").strip(), None

        kwargs = agent._build_api_kwargs(messages)
        kwargs.pop("tools", None)
        kwargs["temperature"] = temperature
        kwargs["timeout"] = timeout
        if extra_body:
            kwargs["extra_body"] = {**(kwargs.get("extra_body") or {}), **extra_body}
        kwargs["max_completion_tokens" if "max_completion_tokens" in kwargs else "max_tokens"] = max_tokens
        resp = agent._ensure_primary_openai_client(reason=reason).chat.completions.create(**kwargs)
        choice = (getattr(resp, "choices", None) or [None])[0]
        message = getattr(choice, "message", None) if choice is not None else None
        return str(getattr(message, "content", "") or "").strip(), resp
    finally:
        agent.reasoning_config = previous_reasoning
