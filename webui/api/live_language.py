"""Hear the language that was actually spoken, not the one the phone expected.

The phone transcribes on-device, and Apple's `SpeechTranscriber` takes exactly
ONE locale — there is no multi-language transcriber and no language-identifier
in iOS 26/27. So a device set to `en-US` hearing Spanish does not fail; it
spells the sounds in English. Real captures: "Hola, hola, ¿cómo estás?" became
`Ola, Ola, Como, Stas`, and the Telugu "నా పేరు ప్రణవ్" became
`Naa, Peru, Pranavo`. Working around that on the device means running one
recogniser per language the user promises to speak, which caps out at a handful
and asks them to predict the conversation.

That one fault produced both complaints. The transcript was wrong, AND nothing
was ever translated — because `_auto_translate` skips any segment whose `lang`
already matches the primary language, and every one of those segments was
stamped `en-US`. A translator cannot rescue this: by the time text exists, the
Spanish is gone.

So the fix belongs before translation, and on the server, which already holds
the audio and already has **faster-whisper** installed. Whisper detects the
language from the AUDIO and transcribes 99 of them, with no list to configure
and nothing to predict. For each finished utterance:

1. detect the language from its audio;
2. if that disagrees with what the device claimed, and the model is confident,
   transcribe it again in the language actually spoken;
3. write back the corrected text and the true `lang`.

Step 3 is what makes translation start working, because the auto-translate gate
finally sees a segment that is not in the primary language.

Deliberately a SECOND opinion, not the primary path. On-device transcription
stays the fast lane that puts words on screen live; this corrects the minority
of utterances it got wrong, in the background, and never blocks capture.

Model note: the English-only Whisper builds (`base.en`, `small.en`, …) cannot
do this at all — they have no other languages to detect. `live.rescue_model`
must name a multilingual build; the default is `base`, which is multilingual
and already cached on this server.
"""
from __future__ import annotations

import logging
import threading
from typing import Any, Callable, Dict, Optional

logger = logging.getLogger(__name__)

# Multilingual, and already on disk here — an English-only build would defeat
# the entire purpose, so this default is load-bearing rather than arbitrary.
DEFAULT_MODEL = "base"

# Tried only when the default is not sure. Measured on real captures: `base`
# reads Spanish at 0.855 and calls Telugu "Polish" at 0.244, while `small`
# reads that Telugu at 0.756 and is only 0.496 on the Spanish. Neither small
# model is good at everything, so the confident one answers and the second
# opinion is bought only for the clips that need it.
ESCALATION_MODEL = "small"

# Below this the detector is guessing. A wrong "correction" is worse than the
# phone's honest mistake: it rewrites a line the user watched appear.
#
# 0.70 rather than 0.60 because of a measured miss: a Telugu utterance was read
# as Portuguese at 0.606 and turned "Naa, Peru, Pranavo." into "na pera para
# não...", which is confident, wrong, and less useful than the romanisation it
# replaced. The real detections on the same recording sat at 0.756-0.97.
MIN_CONFIDENCE = 0.70

# Whisper needs something to listen to. Under this, detection is noise — and
# short fragments are exactly where it hallucinates a foreign language.
MIN_AUDIO_MS = 700

# Whisper's famous failure mode on silence and breath: it emits a stock phrase
# from its training data. Never overwrite a real transcript with one of these.
_HALLUCINATIONS = (
    "thank you", "thanks for watching", "thank you for watching",
    "subscribe", "please subscribe", "you", "bye", "bye.",
    "♪", "music", "[music]", "silence",
)

# Every model asked for stays loaded. It was one slot: an escalation evicted
# `base` to load `small` (2.0 s on this server) and the next utterance evicted
# `small` to reload `base` (0.8 s), so every unsure clip cost ~3 s of loading on
# the single worker every later utterance queues behind.
_models: Dict[str, Any] = {}
_model_lock = threading.Lock()
_unavailable_reason = ""

# Decoding stops here, per second of audio. Unbounded, a clip of room noise on
# this server decoded a hallucination for 8.4 s (10.6 s on `small`) where a
# real sentence of the same length took 1.7 s. Real speech needs a handful of
# tokens a second even in scripts that cost several tokens a syllable.
_TOKENS_PER_SECOND = 16
_MIN_TOKENS = 32


def available() -> bool:
    """Whether a rescue could run right now, without loading anything."""
    try:
        import importlib.util
        return importlib.util.find_spec("faster_whisper") is not None
    except Exception:
        return False


def unavailable_reason() -> str:
    """Why the last load failed, for the operator. "" when it has not failed."""
    return _unavailable_reason


def reset_for_tests() -> None:
    global _unavailable_reason
    with _model_lock:
        _models.clear()
        _unavailable_reason = ""


def _load(model_name: str):
    """A model by name, loaded on first use and kept.

    CPU + int8 without trying CUDA first: this runs beside a recorder on a
    server with no GPU, and faster-whisper's `device="auto"` can load happily
    and then fail at the first transcribe on a host without the NVIDIA runtime
    — which would turn every utterance into an exception instead of a skip.
    """
    global _unavailable_reason
    with _model_lock:
        model = _models.get(model_name)
        if model is not None:
            return model
        try:
            from faster_whisper import WhisperModel
            model = WhisperModel(model_name, device="cpu", compute_type="int8")
            _models[model_name] = model
            _unavailable_reason = ""
            logger.info("live: language rescue using faster-whisper %r",
                        model_name)
        except Exception as exc:
            model = None
            _unavailable_reason = f"{type(exc).__name__}: {exc}"[:200]
            logger.warning("live: could not load faster-whisper %r for language "
                           "rescue: %s", model_name, _unavailable_reason)
        return model


def rescue(pcm16: bytes, rate: int, declared_lang: str, *,
           model_name: str = DEFAULT_MODEL,
           translate_to: str = "",
           on_heard: Optional[Callable[[Dict[str, Any]], None]] = None,
           ) -> Optional[Dict[str, Any]]:
    """Re-hear one utterance. Returns a correction, or None to leave it alone.

    None is the common and correct answer: most utterances really are in the
    language the device expected. A correction is
    `{"lang", "text", "confidence"}`, plus `"translation"` when it could be
    produced here.

    The language is DETECTED first, which costs only the encoder, and the
    utterance is transcribed only when it disagrees with the device — measured
    on this server, 0.75 s against 1.7 s for a full pass, and most lines agree.

    `translate_to` is the user's primary language. When that is English, the
    translation comes from a second decode of audio this function has already
    loaded, with the model already warm. Whisper's translate task only ever
    outputs English, so any other target is left to the caller's own
    translator.

    `on_heard` is handed the correction BEFORE that translation is decoded, so
    the caller can put the corrected line in front of people ~1.7 s sooner — a
    phone translates it itself in a third of a second.
    """
    samples = _to_float32(pcm16, rate)
    if samples is None:
        return None
    duration_ms = int(len(samples) * 1000 / 16000)
    if duration_ms < MIN_AUDIO_MS:
        return None
    heard, detected, confidence, model = None, "", 0.0, None
    for name in _ladder(model_name):
        loaded = _load(name)
        if loaded is None:
            continue
        one = _identify(loaded, samples)
        if one is None:
            continue
        model = loaded
        detected, confidence, heard = one
        if confidence >= MIN_CONFIDENCE:
            break
        # Not sure enough to act on, and not sure enough to stop either: the
        # next model up may simply know this language. Falls through with the
        # last answer so an unsure result is still rejected below.
        logger.debug("live: %r only %.3f sure this was %r; escalating",
                     name, confidence, detected)

    if model is None:
        return None
    if not detected or confidence < MIN_CONFIDENCE:
        return None
    if same_language(detected, declared_lang):
        # The common case, and now it costs no transcription at all.
        return None
    if heard is None:
        heard = _transcribe(model, samples, detected)
        if heard is None:
            return None
    if _too_little_to_judge(heard):
        # Measured in production: a clip that transcribed to "." was declared
        # Norwegian, and the translate pass on the same audio invented "Then
        # add 2 tablespoons of potato starch". A model that heard no words has
        # not identified a language, whatever probability it reports.
        logger.info("live: %r claimed on %r — too little heard to believe it",
                    detected, heard[:20])
        return None
    if not heard or _looks_hallucinated(heard):
        # It says the language is different but has no real words to show for
        # it. Relabelling without replacing the text would mark a line foreign
        # and then translate the English spelling of it, which is worse than
        # doing nothing.
        return None
    found = {"lang": detected, "confidence": round(confidence, 3)}
    if _looks_broken(heard):
        # Trusting the LANGUAGE and trusting the TEXT are two decisions, and
        # they can disagree. A small model asked for a script it barely knows
        # returns confident mojibake: the Telugu "Emi chestunnavu" came back as
        # "\ufffd aprove \u179b\u17d2\ufffdridges". Keeping the phone's
        # readable romanisation while still relabelling the row is strictly
        # better — the line stays legible AND it finally gets translated.
        logger.info("live: %r text looked broken; keeping the device's words "
                    "and relabelling only", detected)
    else:
        found["text"] = heard
    # Kept even when the words are mojibake, because that case is measured and
    # good: the same decode that produced unreadable Telugu script produced a
    # correct "What are you doing now?". What made "." into "Then add 2
    # tablespoons of potato starch" was not a broken transcript but an EMPTY
    # one, and `_too_little_to_judge` has already refused that above.
    if on_heard is not None:
        try:
            on_heard(dict(found))
        except Exception:
            logger.debug("live: the corrected line could not be handed on early",
                         exc_info=True)
    english = _to_english(model, samples, detected, translate_to)
    if english:
        found["translation"] = english
    return found


def _to_english(model: Any, samples: Any, detected: str,
                translate_to: str) -> str:
    """The English of this utterance, from the audio, while the model is warm.

    The translation used to be a separate model call made after the segment had
    already landed, which is where the pause the user saw came from. Doing it
    here costs one more decode of audio that is already in memory.

    Only for an English target: `task="translate"` in Whisper means "to
    English" and nothing else, so asking it for Spanish would silently return
    English and label it Spanish.
    """
    if not same_language(translate_to, "en"):
        return ""
    if same_language(detected, "en"):
        return ""
    try:
        segments, _info = model.transcribe(
            samples, task="translate", language=detected, beam_size=1,
            vad_filter=False, condition_on_previous_text=False,
            max_new_tokens=_token_budget(samples))
        english = " ".join(s.text.strip() for s in segments).strip()
    except Exception:
        logger.debug("live: could not translate this utterance locally",
                     exc_info=True)
        return ""
    if not english or _looks_hallucinated(english):
        return ""
    return english


def _ladder(model_name: str) -> tuple:
    """The models to ask, cheapest first, without asking the same one twice."""
    first = model_name or DEFAULT_MODEL
    if same_language(first, ESCALATION_MODEL) or first == ESCALATION_MODEL:
        return (first,)
    return (first, ESCALATION_MODEL)


def _identify(model: Any, samples: Any):
    """One model's opinion: `(language, confidence, text-or-None)`, or None.

    Detection alone when the model offers it — the encoder and one decoder
    step, measured 0.71-0.91 s on `base` against 1.5-1.8 s for a transcription
    — and the text comes back None, to be decoded only if it is needed. A build
    without `detect_language` can only detect by transcribing, so that path
    returns the text it already paid for.

    No VAD filter. It was here to stop Whisper hallucinating over silence, and
    on a recorder that is mostly silence that sounded right — but these clips
    are two seconds long and trimming them further is what made detection
    guess. Measured: the same Telugu utterance went from 0.275 with the filter
    to 0.756 without it. Hallucinations are caught by their text instead, which
    is what `_looks_hallucinated` is for.
    """
    detect = getattr(model, "detect_language", None)
    if callable(detect):
        try:
            language, probability, _all = detect(samples)
            return (str(language or "").strip().lower(),
                    float(probability or 0.0), None)
        except Exception:
            logger.warning("live: language detection failed on one utterance",
                           exc_info=True)
            return None
    try:
        segments, info = model.transcribe(
            samples,
            # No `language=`: detecting it is the entire point.
            task="transcribe",
            beam_size=1,
            vad_filter=False,
            condition_on_previous_text=False,
            max_new_tokens=_token_budget(samples))
        return (str(getattr(info, "language", "") or "").strip().lower(),
                float(getattr(info, "language_probability", 0.0) or 0.0),
                " ".join(s.text.strip() for s in segments).strip())
    except Exception:
        logger.warning("live: language rescue failed on one utterance",
                       exc_info=True)
        return None


def _transcribe(model: Any, samples: Any, language: str) -> Optional[str]:
    """The words, in the language already detected. None if it threw.

    Told the language rather than left to detect it again: detection has
    already been paid for, and a second opinion from the same model could only
    disagree by chance.
    """
    try:
        segments, _info = model.transcribe(
            samples,
            task="transcribe",
            language=language,
            beam_size=1,
            vad_filter=False,
            condition_on_previous_text=False,
            max_new_tokens=_token_budget(samples))
        return " ".join(s.text.strip() for s in segments).strip()
    except Exception:
        logger.warning("live: language rescue failed on one utterance",
                       exc_info=True)
        return None


def _token_budget(samples: Any) -> int:
    """How many tokens a clip this long can honestly need."""
    seconds = len(samples) / 16000
    return max(_MIN_TOKENS, int(seconds * _TOKENS_PER_SECOND))


def same_language(a: str, b: str) -> bool:
    """Compare on the primary subtag, so `en-US`, `EN` and `en` are one thing.

    Mirrors `live_watchers._language_matches` on purpose: this decides whether
    to relabel a segment and THAT decides whether it gets translated, so the
    two must not disagree about what counts as the same language.
    """
    left = str(a or "").strip().lower().replace("_", "-").split("-")[0]
    right = str(b or "").strip().lower().replace("_", "-").split("-")[0]
    return bool(left) and bool(right) and left == right


# Fewer real characters than this and there is nothing to identify a language
# from. Deliberately low: real utterances here are two seconds of speech, and
# the case being excluded is punctuation and silence, not brevity.
MIN_HEARD_CHARS = 4


def _too_little_to_judge(text: str) -> bool:
    letters = [c for c in str(text or "") if c.isalpha()]
    return len(letters) < MIN_HEARD_CHARS


def _looks_broken(text: str) -> bool:
    """Whether this text is too mangled to put in front of someone.

    Replacement characters mean the decode already failed. A high share of
    characters that are neither letters nor spaces means it is not words at
    all, whatever script it claims to be in — the check has to work for
    alphabets it cannot read, so it counts shapes rather than recognising any
    particular language.
    """
    cleaned = str(text or "").strip()
    if not cleaned:
        return True
    if "\ufffd" in cleaned:
        return True
    letters = sum(1 for c in cleaned if c.isalpha() or c.isspace())
    return letters / len(cleaned) < 0.6


def _looks_hallucinated(text: str) -> bool:
    cleaned = text.strip().lower().rstrip(".!? ")
    return cleaned in _HALLUCINATIONS or len(cleaned) < 2


def _to_float32(pcm16: bytes, rate: int):
    """16-bit PCM at any rate → mono float32 at 16 kHz, which is what Whisper
    wants. Returns None rather than raising: a malformed buffer is a skipped
    rescue, never a failed capture."""
    if not pcm16:
        return None
    try:
        import numpy as np
    except Exception:
        logger.debug("live: numpy unavailable; no language rescue", exc_info=True)
        return None
    try:
        samples = np.frombuffer(pcm16, dtype=np.int16).astype(np.float32) / 32768.0
        if samples.size == 0:
            return None
        rate = int(rate or 16000)
        if rate != 16000:
            # Linear resample. Whisper's own front end is mel-based and
            # forgiving; a polyphase filter here would add scipy for no
            # audible gain on speech.
            target = int(samples.size * 16000 / rate)
            if target <= 0:
                return None
            index = np.linspace(0, samples.size - 1, target, dtype=np.float32)
            samples = np.interp(index, np.arange(samples.size), samples)
            samples = samples.astype(np.float32)
        return samples
    except Exception:
        logger.debug("live: could not convert audio for language rescue",
                     exc_info=True)
        return None
