from agent.turn_context import merge_injections


def test_turn_context_is_appended_after_other_injections():
    assert merge_injections("hello", ["<memory>m</memory>", "plugin"], "voice rules") == \
        "hello\n\n<memory>m</memory>\n\nplugin\n\nvoice rules"


def test_no_injections_returns_content_unchanged():
    assert merge_injections("hello", [], "") == "hello"


def test_list_content_gets_a_text_part():
    parts = [{"type": "text", "text": "hi"}, {"type": "image_url", "image_url": {"url": "x"}}]
    out = merge_injections(parts, [], "rules")
    assert out[-1] == {"type": "text", "text": "rules"} and out[:2] == parts
