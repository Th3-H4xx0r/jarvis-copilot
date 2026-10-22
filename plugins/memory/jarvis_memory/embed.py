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
    """Local embeddings via an Ollama server (default backend).

    The signature/dim are FROZEN at construction (from config). We never rewrite
    them based on a single response: model_signature keys the stored vectors and
    must stay stable for the life of the store, or previously written vectors
    become unreachable (see bug-sweep C1).
    """

    def __init__(self, url: str = "http://localhost:11434", model: str = "bge-m3",
                 dim: int = 1024, timeout: float = 30.0):
        self._url = url.rstrip("/")
        self._model = model
        self._dim = int(dim)
        self._timeout = timeout
        self._warned_dim = False

    @property
    def signature(self) -> str:
        return f"ollama:{self._model}:{self._dim}"

    @property
    def dim(self) -> int:
        return self._dim

    def embed(self, texts: List[str]) -> List[List[float]]:
        """All of ``texts`` in one request (``/api/embed``): a batch costs about
        what one text does on the server's CPU. Falls back to one request per
        text on an Ollama too old for it."""
        import json as _json
        import urllib.error
        import urllib.request  # stdlib — no third-party dependency

        texts = [t or "" for t in texts]
        if not texts:
            return []
        req = urllib.request.Request(
            f"{self._url}/api/embed",
            # keep_alive: an unloaded model costs ~3 s on the next turn.
            data=_json.dumps({"model": self._model, "input": texts,
                              "keep_alive": "24h"}).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=self._timeout) as resp:
                payload = _json.loads(resp.read().decode("utf-8"))
            out = [[float(x) for x in emb] for emb in payload.get("embeddings") or []]
        except urllib.error.HTTPError as exc:
            if exc.code != 404:
                raise
            out = [self._embed_legacy(t) for t in texts]
        for emb in out:
            self._check_dim(emb)
        return out

    def _embed_legacy(self, text: str) -> List[float]:
        import json as _json
        import urllib.request
        req = urllib.request.Request(
            f"{self._url}/api/embeddings",
            data=_json.dumps({"model": self._model, "prompt": text,
                              "keep_alive": "24h"}).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=self._timeout) as resp:
            payload = _json.loads(resp.read().decode("utf-8"))
        return [float(x) for x in payload.get("embedding") or []]

    def _check_dim(self, emb) -> None:
        if emb and len(emb) != self._dim and not self._warned_dim:
            # Do NOT mutate self._dim — that would change the signature and
            # strand previously stored vectors. Warn once; fix the config.
            logger.warning(
                "jarvis_memory: ollama model %s returned dim %d but configured "
                "embed_dim=%d; set plugins.jarvis_memory.embed_dim=%d to match",
                self._model, len(emb), self._dim, len(emb),
            )
            self._warned_dim = True


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
