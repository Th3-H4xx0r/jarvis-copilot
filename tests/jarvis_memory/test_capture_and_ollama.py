"""Capture-noise reduction (trivial filter + user-first capture) and the
graceful predicates of the Ollama bootstrap."""
from plugins.memory.jarvis_memory import JarvisMemoryProvider
from plugins.memory.jarvis_memory import ollama_bootstrap as ob
from plugins.memory.jarvis_memory.ingest import cheap_score, is_trivial


def _provider(tmp_path, **over):
    p = JarvisMemoryProvider()
    cfg = {"embedder": "fake", "embed_dim": 64}
    cfg.update(over)
    p.initialize("s", hermes_home=str(tmp_path), platform="cli", _config_override=cfg)
    return p


def test_is_trivial_filters_pleasantries():
    assert is_trivial("hi")
    assert is_trivial("Hi Pranav! How can I help?")
    assert is_trivial("thanks!")
    assert is_trivial("ok")
    assert not is_trivial("I live at 498 E Marcello Ave, Mountain House, CA")
    assert not is_trivial("remember to deploy the watch app on Friday")


def test_cheap_score_zero_for_trivial():
    assert cheap_score("Hi Pranav! How can I help?") == 0.0
    assert cheap_score("thanks") == 0.0


def test_provider_user_only_capture_drops_assistant_and_trivia(tmp_path):
    p = _provider(tmp_path)
    # The scenario from the screenshot: a useful user fact + assistant echo,
    # then a trivial "hi" + assistant greeting.
    p.sync_turn("hello I live at 498 E Marcello Ave, Mountain House, CA 95391 USA",
                "Got it — your address is 498 E Marcello Ave, Mountain House, CA.")
    p.sync_turn("hi", "Hi Pranav! How can I help?")
    p._flush()
    # Only ONE memory survives: the user-provided fact. Assistant echo + both
    # greetings are dropped.
    assert p._store.count_chunks(p._namespace) == 1
    recent = p._store.recent_chunks(p._namespace, 10)
    assert "Marcello" in recent[0].body
    p.shutdown()


def test_provider_capture_both_when_configured(tmp_path):
    p = _provider(tmp_path, capture_roles=["user", "assistant"])
    p.sync_turn("the deadline is Friday for the auth migration project",
                "Understood, I will treat Friday as the auth migration deadline going forward.")
    p._flush()
    assert p._store.count_chunks(p._namespace) == 2  # both substantive turns kept
    p.shutdown()


def test_ollama_bootstrap_predicates_are_graceful():
    # Unreachable server -> False, no exception.
    assert ob.is_running("http://127.0.0.1:9", timeout=0.3) is False
    # These must not raise regardless of whether ollama is installed locally.
    assert isinstance(ob.is_installed(), bool)
    assert isinstance(ob.has_model("definitely-not-a-real-model-xyz"), bool)
