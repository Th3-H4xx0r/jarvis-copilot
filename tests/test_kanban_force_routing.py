"""Kanban worker routing must be AUTHORITATIVE.

``_apply_worker_routing_env`` (jarviscopilot_cli.kanban_db) routes a claude
worker onto the claude-code subscription by setting env vars. Provider
resolution checks the env THIRD — behind the profile's config ``model.provider``
— so a profile pinned to ``anthropic`` (or one whose config resolves to
anthropic) used to ignore the routing and hit the dead anthropic API.

The fix introduces HERMES_FORCE_PROVIDER / HERMES_FORCE_MODEL, which the routing
sets and provider resolution honours FIRST. These tests assert the worker env
gets the FORCE override for claude-family profiles, including an
``anthropic``-pinned one.
"""
import types

import yaml

from jarviscopilot_cli.kanban_db import _apply_worker_routing_env


def _task(model_override=None):
    return types.SimpleNamespace(model_override=model_override)


def _write_profile(tmp_path, model_cfg):
    (tmp_path / "config.yaml").write_text(yaml.safe_dump({"model": model_cfg}))
    return str(tmp_path)


def test_anthropic_pinned_claude_profile_is_forced_to_claude_code(tmp_path):
    # A profile whose config pins provider: anthropic still routes to claude-code
    # via FORCE vars (the whole point of the fix).
    home = _write_profile(
        tmp_path, {"provider": "anthropic", "default": "claude-opus-4-8"}
    )
    env = {}
    _apply_worker_routing_env(env, _task(), home)
    assert env["HERMES_FORCE_PROVIDER"] == "claude-code"
    assert env["HERMES_FORCE_MODEL"] == "claude-opus-4-8"
    # legacy fallback vars still set
    assert env["HERMES_INFERENCE_PROVIDER"] == "claude-code"
    assert env["HERMES_INFERENCE_MODEL"] == "claude-opus-4-8"


def test_claude_code_dict_profile_is_forced(tmp_path):
    home = _write_profile(
        tmp_path, {"provider": "claude-code", "default": "claude-opus-4-8"}
    )
    env = {}
    _apply_worker_routing_env(env, _task(), home)
    assert env["HERMES_FORCE_PROVIDER"] == "claude-code"
    assert env["HERMES_FORCE_MODEL"] == "claude-opus-4-8"


def test_anthropic_per_task_override_forces_claude_code(tmp_path):
    env = {}
    _apply_worker_routing_env(env, _task(model_override="claude-opus-4-8"), None)
    assert env["HERMES_FORCE_PROVIDER"] == "claude-code"
    assert env["HERMES_FORCE_MODEL"] == "claude-opus-4-8"


def test_non_claude_profile_gets_no_force(tmp_path):
    # glm etc. must NOT be forced onto claude-code.
    home = _write_profile(tmp_path, {"provider": "glm", "default": "glm-5-1"})
    env = {}
    _apply_worker_routing_env(env, _task(), home)
    assert "HERMES_FORCE_PROVIDER" not in env
    assert "HERMES_FORCE_MODEL" not in env
    assert "HERMES_INFERENCE_PROVIDER" not in env


def test_non_anthropic_per_task_override_gets_no_force():
    env = {}
    _apply_worker_routing_env(env, _task(model_override="glm-5-1"), None)
    assert "HERMES_FORCE_PROVIDER" not in env
    assert "HERMES_FORCE_MODEL" not in env
    # the non-anthropic override still carries its own model.
    assert env["HERMES_INFERENCE_MODEL"] == "glm-5-1"


def test_opt_out_allows_anthropic(tmp_path):
    home = _write_profile(
        tmp_path, {"provider": "anthropic", "default": "claude-opus-4-8"}
    )
    env = {"HERMES_KANBAN_ALLOW_ANTHROPIC": "1"}
    _apply_worker_routing_env(env, _task(), home)
    assert "HERMES_FORCE_PROVIDER" not in env
    assert "HERMES_FORCE_MODEL" not in env
