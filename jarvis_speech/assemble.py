"""Soniox responses → live words, finished lines, and late translations.

Soniox re-sends non-final tokens every response until they turn final, marks the
end of a line with a final `<end>` (endpointing) or `<fin>` (manual finalize),
and streams a translation chunk AFTER the spoken chunk it translates — so a
line's translation can still be arriving after the line itself closed. Pure:
no I/O, no threads; the stream calls `consume` from its reader thread.
"""
from __future__ import annotations

from collections import Counter
from typing import Callable, Dict, List, Optional

from jarvis_speech.types import Segment

_MARKERS = ("<end>", "<fin>")
_KEEP_TRANSLATIONS = 32
# Below this, a word was probably misheard: on the Pod's far-field clips every
# wrong word scored under it ("an email with a phone(0.64)" for "a poem").
UNSURE_CONFIDENCE = 0.7


class TokenAssembler:
    def __init__(self, sink, to_session: Optional[Callable[[int], int]] = None) -> None:
        self._sink = sink
        self._to_session = to_session or (lambda ms: ms)
        self._open: List[dict] = []        # final spoken tokens of the line being built
        self._key = 0                      # that line's key
        self._next_key = 1
        # Lines that got spoken words since the last translation token. Soniox
        # translates a chunk after speaking it, so the chunk's translation belongs
        # to the FIRST of them — a speaker split inside the chunk must not move it.
        self._awaiting: List[int] = []
        self._translation_key = 0
        self._translations: Dict[int, List[str]] = {}
        self._closed: set = set()
        self._last_partial = ""

    def consume(self, response: dict) -> None:
        if response.get("error_code") or response.get("error_type"):
            kind = response.get("error_type") or f"error {response.get('error_code')}"
            self._sink.on_error(f"{kind}: {response.get('error_message') or ''}".strip().rstrip(":"))
            return
        pending: List[dict] = []
        late: set = set()
        for token in response.get("tokens") or ():
            text = token.get("text") or ""
            status = token.get("translation_status") or "none"
            if status == "translation":
                if not token.get("is_final"):
                    continue
                if self._awaiting:
                    self._translation_key = self._awaiting[0]
                    self._awaiting = []
                key = self._translation_key
                if key:
                    self._translations.setdefault(key, []).append(text)
                    if key in self._closed:
                        late.add(key)
                continue
            if text in _MARKERS:
                self._close()
                continue
            if not token.get("is_final"):
                pending.append(token)
                continue
            if self._open and str(token.get("speaker") or "") != str(self._open[-1].get("speaker") or ""):
                self._close()
            if not self._open:
                self._key = self._next_key
                self._next_key += 1
            self._open.append(token)
            if status == "original" and self._key not in self._awaiting:
                self._awaiting.append(self._key)
        for key in sorted(late):
            self._sink.on_translation(key, self._translation(key))
        self._partial(self._open + pending)

    def flush(self) -> None:
        self._close()

    # ── internals ──

    def _translation(self, key: int) -> str:
        return "".join(self._translations.get(key, ())).strip()

    def _partial(self, tokens: List[dict]) -> None:
        text = "".join(t.get("text") or "" for t in tokens).strip()
        if not text or text == self._last_partial:
            return
        self._last_partial = text
        first, last = tokens[0], tokens[-1]
        start = first.get("start_ms")
        self._sink.on_partial(text, int(self._to_session(start)) if start is not None else 0,
                              str(last.get("speaker") or ""), str(last.get("language") or ""))

    def _close(self) -> None:
        if not self._open:
            return
        tokens, self._open = self._open, []
        key = self._key
        self._closed.add(key)
        self._last_partial = ""
        for old in [k for k in self._translations if k < key - _KEEP_TRANSLATIONS]:
            self._translations.pop(old, None)
            self._closed.discard(old)
        text = "".join(t.get("text") or "" for t in tokens).strip()
        if not text:
            return
        starts = [t["start_ms"] for t in tokens if t.get("start_ms") is not None]
        ends = [t["end_ms"] for t in tokens if t.get("end_ms") is not None]
        start = int(self._to_session(min(starts))) if starts else 0
        end = int(self._to_session(max(ends))) if ends else start
        self._sink.on_segment(Segment(
            text=text, start_ms=start, end_ms=max(end, start), language=_language(tokens),
            translation=self._translation(key), speaker=str(tokens[0].get("speaker") or ""), key=key,
            unsure=_unsure_words(tokens)))


def _language(tokens: List[dict]) -> str:
    """The language most of the line's duration was spoken in."""
    spoken = Counter()
    for token in tokens:
        language = str(token.get("language") or "")
        if language:
            span = (token.get("end_ms") or 0) - (token.get("start_ms") or 0)
            spoken[language] += max(1, span)
    return spoken.most_common(1)[0][0] if spoken else ""


def _unsure_words(tokens: List[dict]) -> tuple:
    """Words (sub-word tokens joined; a leading space starts a word) whose lowest
    token confidence is under UNSURE_CONFIDENCE."""
    words: List[list] = []
    for token in tokens:
        text = token.get("text") or ""
        confidence = token.get("confidence")
        if not words or text.startswith(" "):
            words.append([text.strip(), confidence])
        else:
            words[-1][0] += text
            if confidence is not None:
                words[-1][1] = confidence if words[-1][1] is None else min(words[-1][1], confidence)
    out = []
    for word, confidence in words:
        bare = word.strip(".,!?;:\"'\u2014\u2013-\u00bf\u00a1")
        if bare and confidence is not None and confidence < UNSURE_CONFIDENCE:
            out.append(bare)
    return tuple(out)
