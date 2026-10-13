"""An auxiliary caller can turn Claude's thinking off (extra_body.thinking).

Claude 5.5 models think by default; a fast JSON helper (the computer-control
fallback) got an empty reply when thinking used its whole token cap."""
from types import SimpleNamespace


class _FakeMessages:
    def __init__(self):
        self.kwargs = None

    def create(self, **kwargs):
        self.kwargs = kwargs
        return SimpleNamespace(content=[SimpleNamespace(type="text", text='{"ok": 1}')], stop_reason="end_turn",
                               usage=SimpleNamespace(input_tokens=5, output_tokens=3), model=kwargs["model"],
                               id="m", role="assistant", type="message")


def _adapter():
    from agent.auxiliary_client import _AnthropicCompletionsAdapter
    real = SimpleNamespace(messages=_FakeMessages())
    return _AnthropicCompletionsAdapter(real, "claude-haiku-5-5"), real.messages


def test_extra_body_thinking_reaches_the_request():
    adapter, msgs = _adapter()
    adapter.create(model="claude-haiku-5-5", messages=[{"role": "user", "content": "hi"}], max_tokens=50,
                   extra_body={"thinking": {"type": "disabled"}})
    assert msgs.kwargs["thinking"] == {"type": "disabled"}


def test_no_extra_body_sends_no_thinking():
    adapter, msgs = _adapter()
    adapter.create(model="claude-haiku-5-5", messages=[{"role": "user", "content": "hi"}], max_tokens=50)
    assert "thinking" not in msgs.kwargs


def test_fallback_turns_thinking_off_for_anthropic_only():
    from agent.computer import decide as D
    seen = []

    def call(**kw):
        seen.append(kw.get("extra_body"))
        return SimpleNamespace(choices=[SimpleNamespace(message=SimpleNamespace(content='{"action":"done"}'))])

    look = {"elements": [], "base64": ""}
    D.fallback_step("@anthropic-api:claude-haiku-5-5", look, "g", {"do": "x"}, [], call=call)
    D.fallback_step("@openrouter:google/gemini-3-flash-preview", look, "g", {"do": "x"}, [], call=call)
    assert seen == [{"thinking": {"type": "disabled"}}, None]
