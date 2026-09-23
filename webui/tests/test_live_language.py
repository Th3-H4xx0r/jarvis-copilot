"""The server's second opinion on what language an utterance was in.

What is worth testing is not that Whisper works — it is every rule about when
NOT to believe it. This path REWRITES a line the user already watched appear,
so a wrong correction is worse than the phone's honest mistake, and most of
this file is the guards that keep it quiet.
"""
import sys
import types

import pytest

from api import live_language


@pytest.fixture(autouse=True)
def fresh():
    live_language.reset_for_tests()
    yield
    live_language.reset_for_tests()


class _Seg:
    def __init__(self, text):
        self.text = text


def _fake_whisper(monkeypatch, *, language, probability, text,
                  english="in english"):
    """Stand in for the model, so no test here loads 140 MB or touches audio.

    Records every call, because WHICH task was asked for is the contract:
    `transcribe` detects and gives native text, `translate` gives English.
    """
    calls = {"tasks": [], "detects": 0, "loads": []}

    class _Model:
        def __init__(self, name, device=None, compute_type=None):
            calls["model"] = name
            calls["loads"].append(name)

        def detect_language(self, samples):
            calls["detects"] += 1
            calls["samples"] = samples
            return language, probability, [(language, probability)]

        def transcribe(self, samples, **kwargs):
            calls["tasks"].append(kwargs.get("task"))
            calls["kwargs"] = kwargs
            calls["samples"] = samples
            if kwargs.get("task") == "translate":
                return [_Seg(english)], types.SimpleNamespace(
                    language=language, language_probability=probability)
            info = types.SimpleNamespace(language=language,
                                         language_probability=probability)
            return [_Seg(text)], info

    module = types.ModuleType("faster_whisper")
    module.WhisperModel = _Model
    monkeypatch.setitem(sys.modules, "faster_whisper", module)
    return calls


def _pcm(ms=2000, rate=16000):
    """Silence is fine: the model is faked, only the byte count matters."""
    return b"\0\0" * int(rate * ms / 1000)


# ── when it should speak up ───────────────────────────────────────────────


def test_spanish_heard_by_an_english_recogniser_is_corrected(monkeypatch):
    """The exact capture that started this: "Hola, hola, ¿cómo estás?" was
    stored as `Ola, Ola, Como, Stas` and, because it was labelled en-US, never
    translated either."""
    _fake_whisper(monkeypatch, language="es", probability=0.97,
                  text="Hola, hola, ¿cómo estás?")

    found = live_language.rescue(_pcm(), 16000, "en-US")

    assert found["lang"] == "es"
    assert found["text"] == "Hola, hola, ¿cómo estás?"
    assert found["confidence"] == 0.97


def test_an_unlabelled_segment_can_also_be_corrected(monkeypatch):
    """No declared language is not a claim that it was English."""
    _fake_whisper(monkeypatch, language="te", probability=0.9,
                  text="నా పేరు ప్రణవ్")

    assert live_language.rescue(_pcm(), 16000, "")["lang"] == "te"


def test_it_asks_the_model_to_detect_rather_than_assume(monkeypatch):
    """Naming a language up front would defeat the point — detection is what
    removes the need to list languages in advance. Once detected, the
    transcription is told the answer rather than paying to detect it again."""
    calls = _fake_whisper(monkeypatch, language="fr", probability=0.9,
                          text="bonjour tout le monde")

    live_language.rescue(_pcm(), 16000, "en")

    assert calls["detects"] == 1, "it must detect, not be told"
    assert calls["kwargs"]["language"] == "fr"
    assert calls["kwargs"]["vad_filter"] is False, (
        "the VAD trims two-second clips down to nothing and makes detection "
        "guess — measured 0.275 with it against 0.756 without; hallucinations "
        "are caught by their text instead")


# ── translation, in the same warm pass ────────────────────────────────────


def test_english_comes_back_with_the_correction(monkeypatch):
    """The gap the user saw was a separate model call made after the segment
    had already landed. The audio is already in memory here and the model is
    already warm, so the translation rides along."""
    calls = _fake_whisper(monkeypatch, language="es", probability=0.96,
                          text="¿cómo estás?", english="How are you?")

    found = live_language.rescue(_pcm(), 16000, "en-US", translate_to="en")

    assert found["translation"] == "How are you?"
    assert calls["tasks"] == ["transcribe", "translate"]


def test_a_non_english_target_is_left_to_the_caller(monkeypatch):
    """Whisper's translate task emits English whatever you ask for, so using
    it for a Spanish target would return English labelled as Spanish."""
    calls = _fake_whisper(monkeypatch, language="te", probability=0.95,
                          text="నా పేరు ప్రణవ్")

    found = live_language.rescue(_pcm(), 16000, "en-US", translate_to="es")

    assert "translation" not in found
    assert calls["tasks"] == ["transcribe"], "no pointless second decode"


def test_no_target_asks_for_no_translation(monkeypatch):
    calls = _fake_whisper(monkeypatch, language="es", probability=0.95,
                          text="hola")

    live_language.rescue(_pcm(), 16000, "en-US")

    assert calls["tasks"] == ["transcribe"]


def test_a_hallucinated_translation_is_dropped_not_shown(monkeypatch):
    """The same stock phrases turn up in the translate task."""
    _fake_whisper(monkeypatch, language="es", probability=0.96,
                  text="¿cómo estás?", english="Thank you.")

    found = live_language.rescue(_pcm(), 16000, "en-US", translate_to="en")

    assert "translation" not in found
    assert found["text"] == "¿cómo estás?", "the correction itself still stands"


# ── when it should stay quiet ─────────────────────────────────────────────


def test_agreeing_with_the_device_changes_nothing(monkeypatch):
    _fake_whisper(monkeypatch, language="en", probability=0.99,
                  text="something slightly different")

    assert live_language.rescue(_pcm(), 16000, "en-US") is None


def test_a_regional_variant_is_the_same_language(monkeypatch):
    """`en` from Whisper against `en-GB` from the device is agreement, not a
    correction — relabelling would start translating English into English."""
    _fake_whisper(monkeypatch, language="en", probability=0.99, text="hello")

    assert live_language.rescue(_pcm(), 16000, "en-GB") is None


def test_an_unconfident_guess_is_ignored(monkeypatch):
    _fake_whisper(monkeypatch, language="cy", probability=0.31, text="rhywbeth")

    assert live_language.rescue(_pcm(), 16000, "en") is None


def test_audio_too_short_to_judge_is_left_alone(monkeypatch):
    """Short fragments are exactly where the detector picks a random language."""
    _fake_whisper(monkeypatch, language="es", probability=0.99, text="sí")

    assert live_language.rescue(_pcm(ms=300), 16000, "en") is None


@pytest.mark.parametrize("stock", ["Thank you.", "Thanks for watching!",
                                   "you", "♪"])
def test_whisper_hallucinating_on_silence_never_overwrites_a_line(
        monkeypatch, stock):
    """Its best-known failure mode: on near-silence it emits a phrase from its
    training data. Believing that would replace a real utterance with "Thank
    you." and mark it foreign."""
    _fake_whisper(monkeypatch, language="es", probability=0.95, text=stock)

    assert live_language.rescue(_pcm(), 16000, "en") is None


def test_a_confident_language_with_no_words_is_not_a_correction(monkeypatch):
    """Relabelling without replacing the text would translate the English
    spelling of a Spanish sentence, which is worse than leaving it."""
    _fake_whisper(monkeypatch, language="es", probability=0.99, text="   ")

    assert live_language.rescue(_pcm(), 16000, "en") is None


def test_a_model_that_will_not_load_is_a_skip_not_a_crash(monkeypatch):
    """Capture is the floor: every failure on this path is an unchanged
    segment."""
    module = types.ModuleType("faster_whisper")

    def _explode(*a, **kw):
        raise OSError("no such model")

    module.WhisperModel = _explode
    monkeypatch.setitem(sys.modules, "faster_whisper", module)

    assert live_language.rescue(_pcm(), 16000, "en") is None
    assert "no such model" in live_language.unavailable_reason()


def test_a_model_that_raises_mid_transcribe_is_a_skip(monkeypatch):
    class _Model:
        def __init__(self, *a, **kw):
            pass

        def transcribe(self, *a, **kw):
            raise RuntimeError("ctranslate2 exploded")

    module = types.ModuleType("faster_whisper")
    module.WhisperModel = _Model
    monkeypatch.setitem(sys.modules, "faster_whisper", module)

    assert live_language.rescue(_pcm(), 16000, "en") is None


def test_empty_audio_is_a_skip(monkeypatch):
    _fake_whisper(monkeypatch, language="es", probability=0.99, text="hola")

    assert live_language.rescue(b"", 16000, "en") is None


# ── audio conversion ──────────────────────────────────────────────────────


def test_audio_is_resampled_to_what_whisper_expects(monkeypatch):
    """The phone streams Opus decoded at 48 kHz; Whisper wants 16 kHz mono
    float. Handing it the wrong rate would make every utterance sound three
    times too fast, which detects as the wrong language confidently."""
    calls = _fake_whisper(monkeypatch, language="es", probability=0.95,
                          text="hola")

    live_language.rescue(_pcm(ms=1000, rate=48000), 48000, "en")

    samples = calls["samples"]
    assert 15000 <= len(samples) <= 17000, "one second at 16 kHz"


def test_the_default_model_is_multilingual():
    """An `.en` build has no other language to detect, so it would silently
    make this whole feature a no-op."""
    assert not live_language.DEFAULT_MODEL.endswith(".en")


def test_language_comparison_matches_the_translate_gate():
    """This decides whether a segment is relabelled, and that decides whether
    it is translated — so it must agree with `live_watchers._language_matches`
    about what counts as the same language."""
    from api import live_watchers

    for a, b in (("en", "en-US"), ("EN", "en"), ("es-419", "es"),
                 ("en", "es"), ("", "en"), ("en", "")):
        assert live_language.same_language(a, b) == \
            live_watchers._language_matches(a, b), f"{a!r} vs {b!r}"


def test_an_unsure_model_escalates_to_a_bigger_one(monkeypatch):
    """Neither small model is good at everything: `base` reads Spanish at
    0.855 and calls Telugu "Polish" at 0.244, while `small` reads that same
    Telugu at 0.756. So the confident one answers, and the bigger one is asked
    only about the clips the first was unsure of."""
    asked = []

    class _Model:
        def __init__(self, name, device=None, compute_type=None):
            self.name = name

        def transcribe(self, samples, **kwargs):
            asked.append(self.name)
            if self.name == live_language.DEFAULT_MODEL:
                info = types.SimpleNamespace(language="pl",
                                             language_probability=0.244)
                return [_Seg("Biemiczesto na wów.")], info
            info = types.SimpleNamespace(language="te",
                                         language_probability=0.756)
            return [_Seg("నా పేరు ప్రణవ్")], info

    module = types.ModuleType("faster_whisper")
    module.WhisperModel = _Model
    monkeypatch.setitem(sys.modules, "faster_whisper", module)

    found = live_language.rescue(_pcm(), 16000, "en-US")

    assert asked == [live_language.DEFAULT_MODEL,
                     live_language.ESCALATION_MODEL]
    assert found["lang"] == "te"
    assert found["text"] == "నా పేరు ప్రణవ్"


def test_a_confident_first_answer_costs_nothing_extra(monkeypatch):
    """The escalation is for hard clips, not a tax on every utterance."""
    calls = _fake_whisper(monkeypatch, language="es", probability=0.9,
                          text="hola")

    live_language.rescue(_pcm(), 16000, "en-US")

    assert calls["model"] == live_language.DEFAULT_MODEL
    assert len(calls["tasks"]) == 1, "one model, one pass"


def test_a_line_in_the_language_the_device_said_is_never_transcribed(monkeypatch):
    """Most lines are. Transcribing them only to throw the text away cost
    1.5-1.8 s each on the server's single rescue worker, where detection alone
    costs 0.7-0.9 s — and every foreign line queued behind them."""
    calls = _fake_whisper(monkeypatch, language="en", probability=0.95,
                          text="hello there")

    assert live_language.rescue(_pcm(), 16000, "en-US") is None
    assert calls["detects"] == 1
    assert calls["tasks"] == [], "no transcription, no translation"


def test_both_models_stay_loaded_between_utterances(monkeypatch):
    """One slot meant every unsure clip evicted `base` to load `small` (2.0 s)
    and the next clip evicted `small` to reload `base` (0.8 s)."""
    loads = []

    class _Model:
        def __init__(self, name, device=None, compute_type=None):
            self.name = name
            loads.append(name)

        def detect_language(self, samples):
            if self.name == live_language.DEFAULT_MODEL:
                return "pl", 0.3, []
            return "te", 0.8, []

        def transcribe(self, samples, **kwargs):
            return [_Seg("నా పేరు ప్రణవ్")], types.SimpleNamespace(
                language="te", language_probability=0.8)

    module = types.ModuleType("faster_whisper")
    module.WhisperModel = _Model
    monkeypatch.setitem(sys.modules, "faster_whisper", module)

    for _ in range(3):
        assert live_language.rescue(_pcm(), 16000, "en-US")["lang"] == "te"

    assert loads == [live_language.DEFAULT_MODEL, live_language.ESCALATION_MODEL]


def test_decoding_is_bounded_by_the_length_of_the_clip(monkeypatch):
    """Unbounded, six seconds of room noise decoded a hallucination for 8.4 s
    where a real sentence took 1.7 s."""
    calls = _fake_whisper(monkeypatch, language="es", probability=0.95,
                          text="hola")

    live_language.rescue(_pcm(ms=2000), 16000, "en-US")
    short = calls["kwargs"]["max_new_tokens"]
    live_language.rescue(_pcm(ms=10000), 16000, "en-US")
    long = calls["kwargs"]["max_new_tokens"]

    assert 0 < short < long
    assert long <= 10 * 20, "a handful of tokens a second, not the model's 448"


def test_the_corrected_line_is_handed_on_before_its_translation(monkeypatch):
    """The phone translates a corrected line itself in a third of a second, so
    holding the line back for Whisper's own translation cost ~1.7 s of it
    sitting on screen uncorrected."""
    calls = _fake_whisper(monkeypatch, language="es", probability=0.96,
                          text="¿cómo estás?", english="How are you?")
    seen = []

    def _heard(found):
        seen.append((dict(found), list(calls["tasks"])))

    found = live_language.rescue(_pcm(), 16000, "en-US", translate_to="en",
                                 on_heard=_heard)

    assert len(seen) == 1
    early, tasks_then = seen[0]
    assert early["text"] == "¿cómo estás?" and "translation" not in early
    assert "translate" not in tasks_then, "handed on before the translate pass"
    assert found["translation"] == "How are you?"


def test_a_detector_that_raises_is_a_skip(monkeypatch):
    class _Model:
        def __init__(self, *a, **kw):
            pass

        def detect_language(self, samples):
            raise RuntimeError("ctranslate2 exploded")

    module = types.ModuleType("faster_whisper")
    module.WhisperModel = _Model
    monkeypatch.setitem(sys.modules, "faster_whisper", module)

    assert live_language.rescue(_pcm(), 16000, "en") is None


def test_both_models_unsure_changes_nothing(monkeypatch):
    """Escalating and still not knowing is not permission to guess."""
    _fake_whisper(monkeypatch, language="pl", probability=0.3, text="whatever")

    assert live_language.rescue(_pcm(), 16000, "en-US") is None


# "a wrong correction is worse than the phone's honest mistake" — including
# when the language is right and only the spelling of it is ruined.


def test_mangled_text_relabels_without_replacing_the_words(monkeypatch):
    """Measured: a small model asked for Telugu returned confident mojibake
    while its ENGLISH was correct. Keeping the device's readable romanisation
    and still relabelling the row is strictly better — the line stays legible
    and it finally gets translated."""
    _fake_whisper(monkeypatch, language="te", probability=0.9,
                  text="\ufffd aprove \u179b\u17d2\ufffdridges",
                  english="What are you doing?")

    found = live_language.rescue(_pcm(), 16000, "en-US", translate_to="en")

    assert found["lang"] == "te", "the language was still learned"
    assert "text" not in found, "but the mangled words are not shown"
    assert found["translation"] == "What are you doing?"


def test_text_that_is_mostly_punctuation_is_not_words(monkeypatch):
    """The check counts shapes, not any particular alphabet — it has to work
    for scripts it cannot read. With no letters at all there is nothing to
    identify a language from either, so the whole correction is refused."""
    _fake_whisper(monkeypatch, language="ja", probability=0.9,
                  text="-- ||| ### @@@ ~~~ %%%")

    assert live_language.rescue(_pcm(), 16000, "en-US") is None


def test_a_near_empty_transcript_never_relabels_anything(monkeypatch):
    """Measured in production: a clip that transcribed to "." was declared
    Norwegian at high confidence, and the translate pass on the same audio
    invented "Then add 2 tablespoons of potato starch". A model that heard no
    words has not identified a language, whatever probability it reports."""
    _fake_whisper(monkeypatch, language="nn", probability=0.95, text=".",
                  english="Then add 2 tablespoons of potato starch,")

    assert live_language.rescue(_pcm(), 16000, "en-US",
                                translate_to="en") is None


def test_a_real_sentence_in_another_script_is_kept(monkeypatch):
    """The mojibake guard must not reject legitimate non-Latin writing."""
    _fake_whisper(monkeypatch, language="zh", probability=0.9,
                  text="你好我来自中国，你叫什么名字？")

    found = live_language.rescue(_pcm(), 16000, "en-US")

    assert found["text"] == "你好我来自中国，你叫什么名字？"


def test_the_confidence_bar_rejects_the_measured_false_positive(monkeypatch):
    """A Telugu utterance read as Portuguese at 0.606 turned "Naa, Peru,
    Pranavo." into "na pera para não..." — confident, wrong, and less useful
    than the romanisation it replaced. Real detections sat at 0.756-0.97."""
    _fake_whisper(monkeypatch, language="pt", probability=0.606,
                  text="na pera para não...")

    assert live_language.rescue(_pcm(), 16000, "en-US") is None

