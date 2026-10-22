"""In-memory cosine index over one (namespace, embedder) slice of the store.

The old search read every vector blob out of SQLite and looped in Python on
each query (54–100 ms at 7k memories); one normalised float32 matrix and a
single matrix-vector product does the same in a few milliseconds. The store
keeps it in step with every write, delete and hide.
"""
from __future__ import annotations

from typing import Dict, Iterable, List, Optional, Set, Tuple

import numpy as np


class VectorIndex:
    def __init__(self, dim: int):
        self.dim = int(dim)
        self._ids: List[str] = []
        self._pos: Dict[str, int] = {}
        self._mat = np.zeros((0, self.dim), dtype=np.float32)

    def __len__(self) -> int:
        return len(self._ids)

    @staticmethod
    def _norm(vec) -> Optional[np.ndarray]:
        v = np.asarray(vec, dtype=np.float32).reshape(-1)
        n = float(np.linalg.norm(v))
        return v / n if n else None

    def build(self, pairs: Iterable[Tuple[str, "np.ndarray"]]) -> None:
        ids, rows = [], []
        for cid, vec in pairs:
            v = self._norm(vec)
            if v is None or v.shape[0] != self.dim:
                continue
            ids.append(cid)
            rows.append(v)
        self._ids = ids
        self._pos = {cid: i for i, cid in enumerate(ids)}
        self._mat = np.vstack(rows).astype(np.float32) if rows else np.zeros((0, self.dim), np.float32)

    def add(self, cid: str, vec) -> None:
        v = self._norm(vec)
        if v is None or v.shape[0] != self.dim:
            return
        i = self._pos.get(cid)
        if i is not None:
            self._mat[i] = v
            return
        self._pos[cid] = len(self._ids)
        self._ids.append(cid)
        self._mat = np.vstack([self._mat, v[None, :]])

    def remove(self, cid: str) -> None:
        i = self._pos.pop(cid, None)
        if i is None:
            return
        last = len(self._ids) - 1
        if i != last:
            moved = self._ids[last]
            self._ids[i] = moved
            self._mat[i] = self._mat[last]
            self._pos[moved] = i
        self._ids.pop()
        self._mat = self._mat[:last]

    def search(self, query, limit: int = 20,
               only_ids: Optional[Set[str]] = None) -> List[Tuple[str, float]]:
        q = self._norm(query)
        if q is None or q.shape[0] != self.dim or not self._ids:
            return []
        scores = self._mat @ q
        if only_ids is not None:
            idx = np.array([self._pos[c] for c in only_ids if c in self._pos], dtype=np.int64)
            if idx.size == 0:
                return []
        else:
            idx = np.arange(len(self._ids))
        sub = scores[idx]
        k = min(int(limit), sub.size)
        if k <= 0:
            return []
        top = np.argpartition(-sub, k - 1)[:k]
        top = top[np.argsort(-sub[top], kind="stable")]
        return [(self._ids[int(idx[t])], float(sub[t])) for t in top]
