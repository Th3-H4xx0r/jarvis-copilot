"""Asking the decision model (and the fallback vision model) for one Mac move."""
from types import SimpleNamespace

from agent.computer import decide as D
from agent.decision_client import Decision, DecisionError

LOOK = {"app": "Spotify", "window": "Spotify", "base64": "QUJD", "mime": "image/jpeg",
        "elements": [{"i": 1, "role": "AXButton", "label": "Play"},
                     {"i": 2, "role": "AXSearchField", "label": "Search"}]}
STEP = {"do": "search for lo-fi", "text": "lo-fi"}


def test_decide_sends_screenshot_and_context():
    seen = {}

    def fake_choose(provider, model, **kw):
        seen.update(kw, provider=provider, model=model)
        return Decision(choice="fill 2", confidence=0.91, ms=380)

    history = [f"move {n}" for n in range(8)]
    m = D.decide("@celeris:celeris-1-decision", LOOK, "play lo-fi", STEP, history, choose=fake_choose)
    assert (seen["provider"], seen["model"]) == ("celeris", "celeris-1-decision")
    assert seen["images"] == ["data:image/jpeg;base64,QUJD"]
    text = seen["text"]
    assert "Goal: play lo-fi" in text and "search for lo-fi" in text and "“lo-fi”" in text
    assert "move 7" in text and "move 2" not in text  # last 5 only
    assert "1. button 'Play'" in text and "2. search field 'Search'" in text
    assert ("fill 2", "Type “lo-fi” into the search field 'Search'") in seen["choices"]
    assert m.action == {"action": "fill", "element": 2, "text": "lo-fi"}
    assert (m.confidence, m.by, m.ms) == (0.91, "decision", 380)


def test_decide_bad_reply_is_low_confidence():
    def boom(*a, **k):
        raise DecisionError("bad reply")

    m = D.decide("@celeris:celeris-1-decision", LOOK, "g", STEP, [], choose=boom)
    assert m.action == {"action": "stuck"} and m.confidence == 0.0 and "bad reply" in m.why


def _reply(text):
    return SimpleNamespace(choices=[SimpleNamespace(message=SimpleNamespace(content=text))])


def test_fallback_parses_json_even_in_prose():
    seen = {}

    def fake_call(**kw):
        seen.update(kw)
        return _reply('Sure: {"action": "click", "element": 1, "why": "play button"} done')

    m = D.fallback_step("@anthropic-api:claude-haiku-5-5", LOOK, "g", STEP, [], call=fake_call)
    assert m.action == {"action": "click", "element": 1} and m.by == "fallback" and m.why == "play button"
    assert seen["provider"] == "anthropic-api" and seen["model"] == "claude-haiku-5-5"
    parts = seen["messages"][-1]["content"]
    assert parts[1] == {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,QUJD"}}


def test_fallback_actions_validated():
    def reply(obj):
        return lambda **kw: _reply(obj)

    ref = "@x:y"
    assert D.fallback_step(ref, LOOK, "g", STEP, [], call=reply('{"action":"click","x":10,"y":20}')).action == \
        {"action": "click", "x": 10, "y": 20}
    assert D.fallback_step(ref, LOOK, "g", STEP, [], call=reply('{"action":"fill","element":2}')).action == \
        {"action": "fill", "element": 2, "text": "lo-fi"}
    assert D.fallback_step(ref, LOOK, "g", STEP, [], call=reply('{"action":"key","keys":"cmd+f"}')).action == \
        {"action": "key", "keys": "cmd+f"}
    assert D.fallback_step(ref, LOOK, "g", STEP, [], call=reply('{"action":"click","element":9}')).action == \
        {"action": "stuck"}
    assert D.fallback_step(ref, LOOK, "g", STEP, [], call=reply("no idea")).action == {"action": "stuck"}

    def boom(**kw):
        raise RuntimeError("provider down")

    m = D.fallback_step(ref, LOOK, "g", STEP, [], call=boom)
    assert m.action == {"action": "stuck"} and "provider down" in m.why


def test_plan_steps():
    def call(**kw):
        return _reply('{"steps": [{"do": "open Spotify", "app": "Spotify"}, '
                      '{"do": "search", "text": "lo-fi"}], "say": "Playing lo-fi."}')

    p = D.plan_steps("@x:y", "play lo-fi on my mac", LOOK, call=call)
    assert p == {"steps": [{"do": "open Spotify", "app": "Spotify"}, {"do": "search", "text": "lo-fi"}],
                 "say": "Playing lo-fi."}
    assert D.plan_steps("@x:y", "g", LOOK, call=lambda **kw: _reply("??")) == {"steps": [{"do": "g"}], "say": ""}


def test_pick_decision_ref(monkeypatch):
    profiles = [SimpleNamespace(name="openai", decision_models=()),
                SimpleNamespace(name="celeris", decision_models=("celeris-1-decision",))]
    monkeypatch.setattr("providers.list_providers", lambda: profiles)
    monkeypatch.setattr("providers.is_decision_model",
                        lambda p, m: (p, m) == ("celeris", "celeris-1-decision"))
    monkeypatch.setattr(D, "_has_key", lambda provider: provider == "celeris")
    assert D.pick_decision_ref(None) == "@celeris:celeris-1-decision"
    assert D.pick_decision_ref("@celeris:celeris-1-decision") == "@celeris:celeris-1-decision"
    assert D.pick_decision_ref("@openai:gpt-5") == "@celeris:celeris-1-decision"
    monkeypatch.setattr(D, "_has_key", lambda provider: False)
    assert D.pick_decision_ref(None) is None


def test_closing_line_comes_from_the_final_screen():
    seen = {}

    def call(**kw):
        seen.update(kw)
        return _reply("Calculator shows 84.")

    assert D.closing_line("@x:y", "work out 12 times 7", LOOK, call=call) == "Calculator shows 84."
    assert seen["messages"][-1]["content"][1]["image_url"]["url"].startswith("data:image/jpeg")

    def boom(**kw):
        raise RuntimeError("down")

    assert D.closing_line("@x:y", "g", LOOK, call=boom) == ""


def test_needs_reading():
    assert D.needs_reading("On my Mac, open Calculator and work out 23 times 4.")
    assert D.needs_reading("what's playing in Spotify on my mac?")
    assert not D.needs_reading("On my Mac open Safari, search amazon for computer and open the first result")


def test_plan_without_a_screen_and_with_urls():
    seen = {}

    def call(**kw):
        seen.update(kw)
        return _reply('{"steps": [{"do": "open results", "app": "Safari", "url": "https://www.amazon.com/s?k=pc"}]}')

    p = D.plan_steps("@x:y", "search amazon for pc", None, call=call)
    assert p["steps"] == [{"do": "open results", "app": "Safari", "url": "https://www.amazon.com/s?k=pc"}]
    assert len(seen["messages"][-1]["content"]) == 1  # text only, no screenshot


def test_plan_keeps_read_steps_and_read_value_answers_briefly():
    def call(**kw):
        return _reply('{"steps": [{"do": "read the price", "read": "Price!"}, {"do": "type it", "text": "{price}"}]}')

    p = D.plan_steps("@x:y", "g", None, call=call)
    assert p["steps"][0] == {"do": "read the price", "read": "price"}
    assert D.read_value("@x:y", LOOK, "g", {"do": "read the price", "read": "price"},
                        call=lambda **kw: _reply("  $449.99\n")) == "$449.99"
    assert D.read_value("@x:y", LOOK, "g", {"do": "read it", "read": "x"}, call=lambda **kw: _reply("NONE")) == ""
