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
from typing import Any, Dict, Optional

logger = logging.getLogger(__name__)

# Multilingual, and already on disk here — an English-only build would defeat
# the entire purpose, so this default is load-bearing rather than arbitrary.
DEFAULT_MODEL = "base"

# Below this the detector is guessing. A wrong "correction" is worse than the
# phone's honest mistake: it rewrites a line the user watched appear.
MIN_CONFIDENCE = 0.60

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

_model: Any = None
_model_name = ""
_model_lock = threading.Lock()
_unavailable_reason = ""


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
    global _model, _model_name, _unavailable_reason
    with _model_lock:
        _model = None
        _model_name = ""
        _unavailable_reason = ""


def _load(model_name: str):
    """One model per process, loaded on first use.

    CPU + int8 without trying CUDA first: this runs beside a recorder on a
    server with no GPU, and faster-whisper's `device="auto"` can load happily
    and then fail at the first transcribe on a host without the NVIDIA runtime
    — which would turn every utterance into an exception instead of a skip.
    """
    global _model, _model_name, _unavailable_reason
    with _model_lock:
        if _model is not None and _model_name == model_name:
            return _model
        try:
            from faster_whisper import WhisperModel
            _model = WhisperModel(model_name, device="cpu", compute_type="int8")
            _model_name = model_name
            _unavailable_reason = ""
            logger.info("live: language rescue using faster-whisper %r",
                        model_name)
        except Exception as exc:
            _model = None
            _model_name = ""
            _unavailable_reason = f"{type(exc).__name__}: {exc}"[:200]
            logger.warning("live: could not load faster-whisper %r for language "
                           "rescue: %s", model_name, _unavailable_reason)
        return _model


def rescue(pcm16: bytes, rate: int, declared_lang: str, *,
           model_name: str = DEFAULT_MODEL,
           translate_to: str = "") -> Optional[Dict[str, Any]]:
    """Re-hear one utterance. Returns a correction, or None to leave it alone.

    None is the common and correct answer: most utterances really are in the
    language the device expected. A correction is
    `{"lang", "text", "confidence"}`, plus `"translation"` when it could be
    produced here.

    `translate_to` is the user's primary language. When that is English, the
    translation comes from a second decode of audio this function has already
    loaded, with the model already warm — which is why it lands in the same
    breath as the corrected line instead of seconds later. Whisper's translate
    task only ever outputs English, so any other target is left to the caller's
    own translator.
    """
    samples = _to_float32(pcm16, rate)
    if samples is None:
        return None
    duration_ms = int(len(samples) * 1000 / 16000)
    if duration_ms < MIN_AUDIO_MS:
        return None
    model = _load(model_name)
    if model is None:
        return None

    try:
        segments, info = model.transcribe(
            samples,
            # No `language=`: detecting it is the entire point.
            task="transcribe",
            beam_size=1,
            # Whisper invents speech in silence, and an ambient recorder is
            # mostly silence. Its own VAD is the cheapest guard against
            # rewriting a real line with a hallucinated one.
            vad_filter=True,
            condition_on_previous_text=False)
        heard = " ".join(s.text.strip() for s in segments).strip()
        detected = str(getattr(info, "language", "") or "").strip().lower()
        confidence = float(getattr(info, "language_probability", 0.0) or 0.0)
    except Exception:
        logger.warning("live: language rescue failed on one utterance",
                       exc_info=True)
        return None

    if not detected or confidence < MIN_CONFIDENCE:
        return None
    if same_language(detected, declared_lang):
        return None
    if not heard or _looks_hallucinated(heard):
        # It says the language is different but has no real words to show for
        # it. Relabelling without replacing the text would mark a line foreign
        # and then translate the English spelling of it, which is worse than
        # doing nothing.
        return None
    found = {"lang": detected, "text": heard,
             "confidence": round(confidence, 3)}
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
            vad_filter=True, condition_on_previous_text=False)
        english = " ".join(s.text.strip() for s in segments).strip()
    except Exception:
        logger.debug("live: could not translate this utterance locally",
                     exc_info=True)
        return ""
    if not english or _looks_hallucinated(english):
        return ""
    return english


def same_language(a: str, b: str) -> bool:
    """Compare on the primary subtag, so `en-US`, `EN` and `en` are one thing.

    Mirrors `live_watchers._language_matches` on purpose: this decides whether
    to relabel a segment and THAT decides whether it gets translated, so the
    two must not disagree about what counts as the same language.
    """
    left = str(a or "").strip().lower().replace("_", "-").split("-")[0]
    right = str(b or "").strip().lower().replace("_", "-").split("-")[0]
    return bool(left) and bool(right) and left == right


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
