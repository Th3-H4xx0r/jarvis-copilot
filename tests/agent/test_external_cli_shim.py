"""Tests for the shared external-CLI shim helpers."""

from agent.external_cli_shim import (
    extract_tool_calls_from_text,
    format_messages_as_prompt,
    render_message_content,
)


def test_extract_xml_tool_call_openai_shape():
    text = (
        '<tool_call>{"id":"1","type":"function",'
        '"function":{"name":"get_weather","arguments":"{\\"city\\":\\"Paris\\"}"}}</tool_call>'
    )
    calls, cleaned = extract_tool_calls_from_text(text)
    assert len(calls) == 1
    call = calls[0]
    assert call.function.name == "get_weather"
    assert call.function.arguments == '{"city":"Paris"}'
    assert call.id == "1"
    assert call.type == "function"
    assert cleaned == ""


def test_extract_tool_call_with_surrounding_text():
    text = (
        "I will check the weather for you.\n"
        '<tool_call>{"id":"c1","type":"function","function":{"name":"f","arguments":"{}"}}</tool_call>\n'
        "Done."
    )
    calls, cleaned = extract_tool_calls_from_text(text)
    assert len(calls) == 1 and calls[0].function.name == "f"
    assert "I will check" in cleaned and "Done." in cleaned
    assert "<tool_call>" not in cleaned


def test_extract_synthesises_id_when_missing_or_blank():
    text = '<tool_call>{"id":"  ","type":"function","function":{"name":"x","arguments":"{}"}}</tool_call>'
    calls, _ = extract_tool_calls_from_text(text)
    assert len(calls) == 1
    assert calls[0].id and calls[0].id.startswith("cli_call_")


def test_extract_plain_text_returns_no_calls():
    calls, cleaned = extract_tool_calls_from_text("just a normal reply")
    assert calls == []
    assert cleaned == "just a normal reply"


def test_extract_handles_empty_or_non_string():
    assert extract_tool_calls_from_text("") == ([], "")
    assert extract_tool_calls_from_text(None) == ([], "")  # type: ignore[arg-type]


def test_format_prompt_uses_default_header_when_not_provided():
    prompt = format_messages_as_prompt(
        [{"role": "user", "content": "hi"}], model="claude-haiku-4-5"
    )
    assert "LLM backend for JarvisCopilot" in prompt
    assert "<tool_call>" in prompt
    assert "claude-haiku-4-5" in prompt
    assert "hi" in prompt


def test_format_prompt_uses_custom_header_lines():
    prompt = format_messages_as_prompt(
        [{"role": "user", "content": "hi"}],
        header_lines=["BACKEND-MARKER-XYZ"],
    )
    assert "BACKEND-MARKER-XYZ" in prompt
    assert "LLM backend for JarvisCopilot" not in prompt


def test_format_prompt_embeds_tool_specs_as_json():
    tools = [{
        "type": "function",
        "function": {
            "name": "get_weather",
            "description": "Get the weather",
            "parameters": {"type": "object", "properties": {"city": {"type": "string"}}},
        },
    }]
    prompt = format_messages_as_prompt([{"role": "user", "content": "weather?"}], tools=tools)
    assert '"name": "get_weather"' in prompt
    assert '"description": "Get the weather"' in prompt


def test_format_prompt_renders_full_transcript():
    msgs = [
        {"role": "system", "content": "You are X."},
        {"role": "user", "content": "hello"},
        {"role": "assistant", "content": "hi back"},
    ]
    prompt = format_messages_as_prompt(msgs)
    assert "System:" in prompt and "You are X." in prompt
    assert "User:" in prompt and "hello" in prompt
    assert "Assistant:" in prompt and "hi back" in prompt


def test_render_message_content_variants():
    assert render_message_content(None) == ""
    assert render_message_content("  hi  ") == "hi"
    assert render_message_content({"text": " t "}) == "t"
    assert render_message_content({"content": "c"}) == "c"
    assert render_message_content([{"type": "text", "text": "a"}, {"type": "text", "text": "b"}]) == "a\nb"


def test_copilot_acp_imports_still_work_after_refactor():
    """The refactor in copilot_acp_client.py must re-export the helpers as
    underscore-prefixed names so the rest of that module keeps working."""
    from agent import copilot_acp_client as cac
    assert callable(cac._format_messages_as_prompt)
    assert callable(cac._extract_tool_calls_from_text)
    # The copilot module preserves its own preamble via _COPILOT_ACP_HEADER_LINES.
    assert any("ACP agent backend" in line for line in cac._COPILOT_ACP_HEADER_LINES)
