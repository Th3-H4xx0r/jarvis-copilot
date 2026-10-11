"""Which model turns pages into JSON (browser_extract, read_top): set in Settings as a
model (`@provider:model`) or a harness (`harness:<id>`, whose Route picks the model)."""
from unittest.mock import patch

import pytest

from agent import extract_model as em


@pytest.fixture(autouse=True)
def _clean():
    em.register_resolver(None)
    yield
    em.register_resolver(None)


def _configured(ref):
    return patch.object(em, "configured", lambda: ref)


def test_a_chosen_model_is_used_as_is():
    with _configured("@anthropic-api:claude-haiku-5-5"):
        assert em.resolve("prices", 1000) == ("anthropic-api", "claude-haiku-5-5")
    with _configured("@celeris:celeris-1"):
        assert em.resolve("prices", 1000) == ("celeris", "celeris-1")


def test_a_harness_picks_the_model_through_its_route():
    seen = []

    def resolver(harness_id, instruction, size):
        seen.append((harness_id, instruction, size))
        return "@celeris:celeris-1" if size < 5000 else "@anthropic-api:claude-sonnet-5-5"

    em.register_resolver(resolver)
    with _configured("harness:extract"):
        assert em.resolve("flight prices", 1200) == ("celeris", "celeris-1")
        assert em.resolve("flight prices", 90000) == ("anthropic-api", "claude-sonnet-5-5")
    assert seen[0] == ("extract", "flight prices", 1200)


def test_nothing_chosen_means_haiku_when_the_anthropic_key_is_there():
    with _configured(""), patch.object(em, "_anthropic_api_ready", lambda: True):
        assert em.resolve("x", 10) == ("anthropic-api", "claude-haiku-5-5")
    with _configured(""), patch.object(em, "_anthropic_api_ready", lambda: False):
        assert em.resolve("x", 10) is None


def test_a_harness_without_a_resolver_falls_back_to_the_default():
    with _configured("harness:gone"), patch.object(em, "_anthropic_api_ready", lambda: False):
        assert em.resolve("x", 10) is None


def test_custom_provider_refs_keep_their_slug():
    with _configured("@custom:lab:qwen3:32b"):
        assert em.resolve("x", 10) == ("custom:lab", "qwen3:32b")
    with _configured("@ollama-cloud:gemma4:31b"):
        assert em.resolve("x", 10) == ("ollama-cloud", "gemma4:31b")


def test_the_web_uis_splitter_wins_when_registered():
    em.register_splitter(lambda ref: ("custom:host:8080", "llama3") if ref == "@custom:host:8080:llama3" else None)
    try:
        with _configured("@custom:host:8080:llama3"):
            assert em.resolve("x", 10) == ("custom:host:8080", "llama3")
    finally:
        em.register_splitter(None)
