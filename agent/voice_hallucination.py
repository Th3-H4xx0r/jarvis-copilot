"""Whisper hallucination filter (Python port of openhuman's hallucination.rs).

Whisper-family models invent text on silence/noise — "[BLANK_AUDIO]", "Thank you
for watching", or repetition loops ("you you you"). This is pure, dependency-free
string logic that flags such output so the agent never acts on a phantom turn.
Especially relevant to short, noisy Apple-Watch relay clips.

Two modes:
- "conversation" (conservative): only drops clear hallucinations, lets short real
  replies like "yes"/"okay" through.
- "dictation" (aggressive): additionally drops lone filler words.
"""
from __future__ import annotations

import re
from collections import Counter
from typing import List

# Dropped in ALL modes (matched as the entire utterance).
ALWAYS_HALLUCINATION = [
    "[blank_audio]", "[ blank_audio ]", "[blank audio]", "(blank audio)",
    "thank you for watching", "thanks for watching", "thank you for listening",
    "please subscribe", "like and subscribe", "see you next time",
    "see you in the next video", "bye bye",
]

# Dropped only in dictation mode (lone filler that's usually a mis-fire).
DICTATION_ONLY = {
    "thank you", "thanks", "bye", "goodbye",
    "you", "the", "i", "a", "so", "okay", "ok", "yeah", "yes", "no", "oh", "hmm", "huh", "ah",
}

_WORD_RE = re.compile(r"[a-z0-9']+")


def _ngram_loop(words: List[str]) -> bool:
    """True if the words are a 1-3 word phrase repeated to fill (>=2 reps)."""
    n_words = len(words)
    for n in (1, 2, 3):
        if n_words >= 2 * n and n_words % n == 0:
            base = words[:n]
            if all(words[i:i + n] == base for i in range(0, n_words, n)):
                return True
    return False


def is_hallucinated_output(text: str, mode: str = "conversation") -> bool:
    if text is None:
        return True
    lowered = text.strip().lower()
    if not lowered:
        return True
    stripped = lowered.strip(" .,!?…\t\n\r")
    if not stripped:  # punctuation/whitespace only
        return True
    if stripped in ALWAYS_HALLUCINATION or lowered in ALWAYS_HALLUCINATION:
        return True
    if mode == "dictation" and stripped in DICTATION_ONLY:
        return True

    words = _WORD_RE.findall(lowered)
    if not words:
        return True

    # Uniform repetition: "you you you you"
    if len(words) >= 2 and all(w == words[0] for w in words):
        return True

    # Repeating n-gram loop: "thank you. thank you. thank you."
    if _ngram_loop(words):
        return True

    # Dominant-word ratio: a single token > 60% of >=5 words (loop), while still
    # allowing emphatic natural speech like "no no no don't do that" (50%).
    counts = Counter(words)
    total = len(words)
    for c in counts.values():
        if c >= 5 and (c / total) > 0.6:
            return True

    return False
