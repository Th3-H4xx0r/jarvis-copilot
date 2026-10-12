"""Harness graphs, shared by the web UI and the scheduler.

The pure parts live here so the gateway process (cron schedules) can plan a
turn without importing the web UI (``api.*``):

- ``schema``   — the graph shape and its validator;
- ``builtins`` — the harnesses every install starts with;
- ``store``    — reading designs + per-surface defaults from the web UI state dir;
- ``planner``  — which node answers a turn, what runs after it, Route classification;
- ``llm``      — one tool-less model call (a model Route, a Review node);
- ``refs``     — ``@provider:model`` splitting (the web UI registers its catalog-aware one).

The web UI modules (``api.harness_schema`` / ``harness_store`` / ``harness_llm`` /
``harness_runner``) re-export these, adding only what needs the web UI.
"""
