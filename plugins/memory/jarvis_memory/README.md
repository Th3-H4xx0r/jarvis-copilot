# jarvis_memory

Semantic long-term memory provider (Phase 1 of the memory tree). Automatic
per-turn capture + hybrid (vector + keyword) recall, backed by SQLite + a
markdown vault under `$HERMES_HOME/memory/`.

Enable in `config.yaml`:

```yaml
memory:
  provider: jarvis_memory
plugins:
  jarvis_memory:
    embedder: ollama          # or "fake" (tests)
    ollama_model: bge-m3
    embed_dim: 1024
    recall_limit: 5
```

Requires a running Ollama with `bge-m3` pulled for the default embedder; recall
degrades to keyword-only if the embedder is unavailable.

See `docs/superpowers/specs/2026-05-30-memory-tree-design.md` for the full design
and the roadmap to the complete tree (entity graph, summary folding, digests),
and `docs/superpowers/plans/2026-05-30-memory-tree-phase1-foundation.md` for this
phase's plan.
