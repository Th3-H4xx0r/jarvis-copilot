"""Configuring an auxiliary vision backend silently disables native images.

Setting `auxiliary.vision.provider` (needed so device photos get described by
a model that is not out of quota) made decide_image_input_mode return "text"
for every provider, so `_build_native_multimodal_message` dropped the picture
and a photo attached in chat never reached the model: "I'm afraid you haven't
provided an image for me to examine, sir." `agent.image_input_mode` overrides
that, which is how both can be true at once."""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from agent.image_routing import decide_image_input_mode

_AUX = {"auxiliary": {"vision": {"provider": "ollama-cloud", "model": "gemma4:31b"}}}


def test_an_aux_vision_backend_alone_forces_the_text_pipeline():
    assert decide_image_input_mode("ollama-cloud", "gemma4:31b", _AUX) == "text"


def test_an_explicit_native_mode_wins_over_the_aux_override():
    cfg = {**_AUX, "agent": {"image_input_mode": "native"}}
    for provider, model in (("ollama-cloud", "gemma4:31b"),
                            ("openrouter", "google/gemini-3.8-flash"),
                            ("claude-code", "claude-sonnet-5")):
        assert decide_image_input_mode(provider, model, cfg) == "native", provider


def test_an_explicit_text_mode_is_still_honoured():
    cfg = {**_AUX, "agent": {"image_input_mode": "text"}}
    assert decide_image_input_mode("anthropic", "claude-sonnet-5", cfg) == "text"


def test_no_config_at_all_is_not_forced_to_text():
    assert decide_image_input_mode("anthropic", "claude-sonnet-5", {}) in {"native", "text"}
