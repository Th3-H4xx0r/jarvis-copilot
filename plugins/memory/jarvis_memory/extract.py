"""Phase-2 LLM fact extraction.

Distills a conversation turn into 0-N clean, standalone durable facts instead of
storing raw messages. Runs on the background thread; uses a local Ollama chat
model by default (private/free, like openhuman's local extractor). If extraction
is unavailable it raises so the provider falls back to raw capture — it never
silently drops a turn.
"""
from __future__ import annotations

import json
import logging
import re
from abc import ABC, abstractmethod
from typing import List

logger = logging.getLogger(__name__)

MAX_FACTS = 4

SYSTEM_PROMPT = (
    "You extract durable, long-term facts from a conversation turn for a personal "
    "assistant's memory. Output ONLY a JSON array of strings — no prose, no markdown. "
    "Each string is ONE standalone declarative fact worth remembering about the user, "
    "their preferences, the people/projects they mention, or decisions made — written so "
    "it stands alone without the conversation (resolve 'I'/'my' to the user). "
    "Rules: omit greetings, acknowledgements, small talk, and transient one-off requests; "
    "merge related details into a single fact; at most 4 facts; if nothing is worth "
    "remembering long-term, output []."
)


def _parse_facts(content: str) -> List[str]:
    """Pull the first JSON array out of an LLM response and return its strings."""
    if not content:
        return []
    m = re.search(r"\[.*\]", content, re.DOTALL)
    blob = m.group(0) if m else content
    try:
        data = json.loads(blob)
    except Exception:
        return []
    if not isinstance(data, list):
        return []
    out = []
    for item in data:
        if isinstance(item, str) and item.strip():
            out.append(item.strip())
    return out[:MAX_FACTS]


class FactExtractor(ABC):
    @abstractmethod
    def extract(self, user_text: str, assistant_text: str) -> List[str]:
        """Return durable facts. Raise on unavailability (-> provider falls back)."""


class NoopExtractor(FactExtractor):
    def extract(self, user_text, assistant_text):
        return []


class FakeExtractor(FactExtractor):
    """Test double — returns preset facts (or echoes a canned list)."""

    def __init__(self, facts=None, raises: bool = False):
        self._facts = facts or []
        self._raises = raises

    def extract(self, user_text, assistant_text):
        if self._raises:
            raise RuntimeError("extractor unavailable")
        return list(self._facts)


class OllamaFactExtractor(FactExtractor):
    def __init__(self, model: str = "llama3.2:3b", url: str = "http://localhost:11434",
                 timeout: float = 25.0):
        self._model = model
        self._url = url.rstrip("/")
        self._timeout = timeout

    def extract(self, user_text: str, assistant_text: str) -> List[str]:
        import urllib.request

        user_block = f"User said: {user_text or ''}".strip()
        if assistant_text:
            user_block += f"\nAssistant said: {assistant_text}"
        user_block += "\n\nJSON array of durable facts:"
        payload = {
            "model": self._model,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": user_block},
            ],
            "stream": False,
            "options": {"temperature": 0},
        }
        req = urllib.request.Request(
            f"{self._url}/api/chat",
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=self._timeout) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        content = (data.get("message") or {}).get("content", "")
        return _parse_facts(content)


def make_extractor(cfg: dict):
    """Return a FactExtractor or None (None = extraction disabled, raw capture)."""
    kind = cfg.get("extract")
    if kind is None:
        kind = "ollama" if (cfg.get("embedder") or "ollama").lower() == "ollama" else "off"
    kind = str(kind).lower()
    if kind in ("off", "none", "false", "0"):
        return None
    if kind == "ollama":
        return OllamaFactExtractor(
            model=cfg.get("extract_model", "llama3.2:3b"),
            url=cfg.get("ollama_url", "http://localhost:11434"),
        )
    return None
