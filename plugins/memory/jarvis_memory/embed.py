"""Pluggable embedders for jarvis_memory.

FakeEmbedder is deterministic + network-free (tests). OllamaEmbedder is the
default runtime backend (bge-m3, 1024-dim). Cloud adapters arrive in later phases.
"""
from __future__ import annotations

import hashlib
import logging
import re
from abc import ABC, abstractmethod
from typing import List

logger = logging.getLogger(__name__)


class Embedder(ABC):
    @property
    @abstractmethod
    def signature(self) -> str:
        """Stable id of (provider, model, dim) — tags every stored vector."""

    @property
    @abstractmethod
    def dim(self) -> int:
        ...

    @abstractmethod
    def embed(self, texts: List[str]) -> List[List[float]]:
        ...

    def embed_one(self, text: str) -> List[float]:
        return self.embed([text])[0]


class FakeEmbedder(Embedder):
    """Deterministic, network-free embedder for tests: hashed bag-of-words,
    L2-normalized, so texts sharing tokens have higher cosine similarity."""

    def __init__(self, dim: int = 64):
        self._dim = int(dim)

    @property
    def signature(self) -> str:
        return f"fake:bow:{self._dim}"

    @property
    def dim(self) -> int:
        return self._dim

    def embed(self, texts: List[str]) -> List[List[float]]:
        out: List[List[float]] = []
        for t in texts:
            vec = [0.0] * self._dim
            for tok in re.findall(r"[a-z0-9]+", (t or "").lower()):
                h = int(hashlib.sha1(tok.encode("utf-8")).hexdigest(), 16)
                vec[h % self._dim] += 1.0
            norm = sum(v * v for v in vec) ** 0.5
            if norm > 0:
                vec = [v / norm for v in vec]
            out.append(vec)
        return out


class OllamaEmbedder(Embedder):
    """Local embeddings via an Ollama server (default backend)."""

    def __init__(self, url: str = "http://localhost:11434", model: str = "bge-m3",
                 dim: int = 1024, timeout: float = 30.0):
        self._url = url.rstrip("/")
        self._model = model
        self._dim = int(dim)
        self._timeout = timeout

    @property
    def signature(self) -> str:
        return f"ollama:{self._model}:{self._dim}"

    @property
    def dim(self) -> int:
        return self._dim

    def embed(self, texts: List[str]) -> List[List[float]]:
        import requests  # lazy — only needed at runtime with Ollama

        out: List[List[float]] = []
        for t in texts:
            r = requests.post(
                f"{self._url}/api/embeddings",
                json={"model": self._model, "prompt": t or ""},
                timeout=self._timeout,
            )
            r.raise_for_status()
            emb = r.json().get("embedding") or []
            if emb and len(emb) != self._dim:
                self._dim = len(emb)
            out.append([float(x) for x in emb])
        return out


def make_embedder(cfg: dict) -> Embedder:
    kind = (cfg.get("embedder") or "ollama").lower()
    if kind == "fake":
        return FakeEmbedder(dim=int(cfg.get("embed_dim", 64)))
    if kind == "ollama":
        return OllamaEmbedder(
            url=cfg.get("ollama_url", "http://localhost:11434"),
            model=cfg.get("ollama_model", "bge-m3"),
            dim=int(cfg.get("embed_dim", 1024)),
        )
    raise ValueError(f"unknown embedder: {kind}")
