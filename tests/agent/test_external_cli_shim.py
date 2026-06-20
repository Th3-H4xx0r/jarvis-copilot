"""Tests for the shared external-CLI shim helpers."""

import json

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


def test_role_renderers_override_default_label_format():
    """A backend can supply a per-role renderer to wrap content in custom
    delimiters — claude-code uses this to wrap tool results in
    <tool_result> blocks so the model doesn't echo `Tool:` lines."""
    def _tool_renderer(content, msg):
        name = msg.get("name", "") if isinstance(msg, dict) else ""
        return f'<tool_result name="{name}">\n{content}\n</tool_result>'

    msgs = [
        {"role": "user", "content": "weather?"},
        {"role": "assistant", "content": "checking"},
        {"role": "tool", "name": "get_weather", "content": '{"temp_f": 68}'},
    ]
    prompt = format_messages_as_prompt(
        msgs, role_renderers={"tool": _tool_renderer}
    )
    # Tool result is wrapped, NOT prefixed with "Tool:"
    assert '<tool_result name="get_weather">' in prompt
    assert '</tool_result>' in prompt
    assert '{"temp_f": 68}' in prompt
    assert "Tool:\n" not in prompt  # default label suppressed
    # Other roles still use the default label format
    assert "User:\nweather?" in prompt
    assert "Assistant:\nchecking" in prompt


def test_role_renderers_callable_one_arg_still_supported():
    """Renderers may accept just `content` (no message kwarg)."""
    prompt = format_messages_as_prompt(
        [{"role": "tool", "content": "X"}],
        role_renderers={"tool": lambda c: f"<R>{c}</R>"},
    )
    assert "<R>X</R>" in prompt


def test_copilot_acp_imports_still_work_after_refactor():
    """The refactor in copilot_acp_client.py must re-export the helpers as
    underscore-prefixed names so the rest of that module keeps working."""
    from agent import copilot_acp_client as cac
    assert callable(cac._format_messages_as_prompt)
    assert callable(cac._extract_tool_calls_from_text)
    # The copilot module preserves its own preamble via _COPILOT_ACP_HEADER_LINES.
    assert any("ACP agent backend" in line for line in cac._COPILOT_ACP_HEADER_LINES)


# ── Output sanitisation (leaked internal-marker stripping) ───────────────────

from agent.external_cli_shim import (  # noqa: E402
    sanitize_model_text,
    extract_image_blocks,
    build_stream_json_user_input,
)


def test_sanitize_strips_mangled_tool_result_block_and_keeps_reply():
    leaked = (
        "Tracker updated with the Air India logo.\n\n"
        "<!-- jc:toolresult name=readfile (internal context — do not reproduce) -->\n"
        '{"content":"1|#!/usr/bin/env python3 SECRET"}\n'
        "<!-- /jc:toolresult -->"
    )
    out = sanitize_model_text(leaked)
    assert "Air India logo" in out
    assert "jc:toolresult" not in out and "SECRET" not in out


def test_sanitize_strips_correct_spelling_and_truncated_block():
    out = sanitize_model_text(
        'Done.\n<!-- jc:tool_result name=execute_code -->\n{"stdout":"x"}')
    assert out.strip() == "Done." and "tool_result" not in out


def test_sanitize_strips_xml_echo_and_orphan_comment_line():
    assert sanitize_model_text('<toolresult>{"a":1}</toolresult>ok') == "ok"
    # A non-tool_result orphan comment line is removed; surrounding prose survives.
    out = sanitize_model_text("line1\n<!-- some marker -->\nline2")
    assert "line1" in out and "line2" in out and "<!--" not in out
    # An opening tool_result marker plus tool-output JSON: the marker comment and
    # the tool-I/O line are stripped; surrounding prose survives.
    out2 = sanitize_model_text('intro\n<!-- jc:tool_result name=terminal -->\n{"output":"x","exit_code":0}')
    assert out2.strip() == "intro" and "exit_code" not in out2
    # Generic (non-tool) JSON a user asked for is NOT stripped.
    assert '{"leaked":1}' in sanitize_model_text('answer\n{"leaked":1}')


def test_sanitize_leaves_clean_text_unchanged():
    txt = "The weather is 68F, partly cloudy."
    assert sanitize_model_text(txt) == txt
    assert sanitize_model_text("") == ""


def test_extract_image_blocks_data_url_and_passthrough():
    blocks = extract_image_blocks([{"role": "user", "content": [
        {"type": "text", "text": "hi"},
        {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,QUJD"}},
    ]}])
    assert blocks == [{"type": "image",
                       "source": {"type": "base64", "media_type": "image/jpeg", "data": "QUJD"}}]
    # already-claude-shaped passes through; non-image content ignored
    assert extract_image_blocks([{"role": "user", "content": "plain"}]) == []


def test_build_stream_json_user_input_shape():
    line = build_stream_json_user_input("hello", [
        {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "QUJD"}}])
    obj = json.loads(line)
    assert obj["type"] == "user" and obj["message"]["role"] == "user"
    assert obj["message"]["content"][0] == {"type": "text", "text": "hello"}
    assert obj["message"]["content"][1]["type"] == "image"


# ── Tool-call history in the prompt (the infinite-loop root cause) ───────────

def test_filter_repeat_tool_calls_breaks_a_pure_repeat_loop():
    """Loop prevention is now DETERMINISTIC: a turn whose calls are all exact
    repeats of already-executed ones is dropped (forces a final answer), without
    relying on the model reading any prompt note."""
    from types import SimpleNamespace
    from agent.external_cli_shim import filter_repeat_tool_calls

    def tc(name, args="{}"):
        return SimpleNamespace(id="x", function=SimpleNamespace(name=name, arguments=args))

    history = [
        {"role": "assistant", "tool_calls": [{"id": "1", "type": "function",
            "function": {"name": "patch", "arguments": '{"v": 13}'}}]},
        {"role": "tool", "name": "patch", "content": "ok"},
    ]
    # exact repeat (incl. cosmetic arg whitespace/key-order) → dropped
    assert filter_repeat_tool_calls([tc("patch", '{"v":13}')], history) == []
    assert filter_repeat_tool_calls([tc("patch", '{ "v" : 13 }')], history) == []
    # a NEW call → kept (never block real progress)
    assert len(filter_repeat_tool_calls([tc("read_file", '{"p":"a"}')], history)) == 1
    # mixed (at least one new) → all kept
    assert len(filter_repeat_tool_calls(
        [tc("patch", '{"v":13}'), tc("read_file", '{"p":"a"}')], history)) == 2


def test_prompt_does_not_inject_a_result_note():
    """The prompt must NOT annotate tool results with a "(result of X — you
    already called it…)" note — the model echoed it verbatim (confusing output)."""
    messages = [
        {"role": "user", "content": "x"},
        {"role": "assistant", "content": "",
         "tool_calls": [{"id": "1", "type": "function",
                         "function": {"name": "foo_tool", "arguments": "{}"}}]},
        {"role": "tool", "name": "foo_tool", "content": "ok"},
    ]
    prompt = format_messages_as_prompt(messages, header_lines=["H"])
    assert "you already called it" not in prompt and "result of `foo_tool`" not in prompt


def test_prompt_does_not_render_mimicable_already_executed_line():
    """The history signal must NOT be a standalone `[already executed: …]` line
    (the model mimicked that format for its own calls → they never executed)."""
    messages = [
        {"role": "user", "content": "x"},
        {"role": "assistant", "content": "",
         "tool_calls": [{"id": "1", "type": "function",
                         "function": {"name": "foo_tool", "arguments": "{}"}}]},
        {"role": "tool", "name": "foo_tool", "content": "ok"},
    ]
    prompt = format_messages_as_prompt(messages, header_lines=["H"])
    assert "[already executed" not in prompt


def test_sanitize_strips_echoed_already_executed_and_result_note():
    leak = ('Here is the plan, sir.\n'
            '[already executed — do NOT call again: tool_search({"q":"x"})]\n'
            '(result of `patch` — you already called it; do NOT call `patch` again)\n'
            'All done.')
    out = sanitize_model_text(leak)
    assert "Here is the plan, sir." in out and "All done." in out
    assert "already executed" not in out and "already called it" not in out


def test_prompt_continuation_points_at_results_after_a_tool_turn():
    messages = [
        {"role": "user", "content": "do it"},
        {"role": "assistant", "content": "",
         "tool_calls": [{"id": "1", "type": "function",
                         "function": {"name": "foo_tool", "arguments": "{}"}}]},
        {"role": "tool", "name": "foo_tool", "content": "ok"},
    ]
    prompt = format_messages_as_prompt(messages, header_lines=["H"]).lower()
    # After a tool result, the model is steered to use results / not repeat,
    # rather than re-addressing the user request from scratch.
    assert "do not repeat" in prompt or "already" in prompt


# ── Sanitiser precision (no false positives) ─────────────────────────────────

def test_sanitize_preserves_legit_content_reviewer_cases():
    # Inline HTML comment: strip the comment span, keep the surrounding prose.
    out = sanitize_model_text("To hide an element add <!-- TODO --> to your HTML.")
    assert "To hide an element add" in out and "to your HTML." in out and "<!--" not in out
    # A transcript the user asked the model to print keeps its role labels.
    assert sanitize_model_text("User: hello\nAssistant: hi there") == "User: hello\nAssistant: hi there"
    # Isolated tool-shaped JSON a user asked for is NOT stripped.
    assert '"exit_code": 0' in sanitize_model_text('Here:\n{"output": "hello", "exit_code": 0}')
    assert '"type": "function"' in sanitize_model_text('Schema:\n{"type": "function", "name": "foo"}')
    assert '"loaded": true' in sanitize_model_text('{"loaded": true, "count": 3}')


def test_sanitize_drops_tool_output_json_only_next_to_a_marker():
    # Adjacent to a jc marker → dropped (transcript dump).
    leak = 'intro\n<!-- jc:tool_result name=terminal -->\n{"output":"x","exit_code":0}\noutro'
    out = sanitize_model_text(leak)
    assert "intro" in out and "outro" in out and "exit_code" not in out and "jc:tool_result" not in out
