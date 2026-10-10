"""Model pickers: "Anthropic API" (API key) and "Claude Code" (subscription); the old "Anthropic" is hidden.

An ``@anthropic-api:`` pick must reach the API on the key — never rerouted to the
Claude Code CLI — while chats already pinned to ``@anthropic:`` keep resolving.
"""

import copy
import json
import pathlib
import shutil
import subprocess

import pytest

import api.config as cfg_mod
from api.config import (
    model_with_provider_context,
    picker_catalog,
    resolve_model_provider,
    route_anthropic_via_claude_code,
)


def _catalog():
    return {
        "active_provider": "anthropic-api",
        "default_model": "claude-sonnet-5-5",
        "groups": [
            {"provider": "Anthropic", "provider_id": "anthropic", "models": [{"id": "@anthropic:claude-sonnet-5-5"}]},
            {"provider": "Anthropic API", "provider_id": "anthropic-api", "models": [{"id": "claude-sonnet-5-5"}]},
            {"provider": "Claude Code", "provider_id": "claude-code", "models": [{"id": "@claude-code:claude-sonnet-5-5"}]},
        ],
    }


def test_picker_drops_only_the_old_anthropic_group_and_leaves_its_input_alone():
    full = _catalog()
    before = copy.deepcopy(full)

    shown = picker_catalog(full)

    assert [g["provider_id"] for g in shown["groups"]] == ["anthropic-api", "claude-code"]
    assert shown["active_provider"] == "anthropic-api"
    assert full == before


def test_picker_tolerates_a_catalog_without_groups():
    assert picker_catalog({"models": []}) == {"models": []}


def test_anthropic_api_pick_resolves_to_the_api_and_is_not_rerouted(monkeypatch):
    monkeypatch.setattr(cfg_mod, "_claude_cli_installed", lambda: True)
    picked = model_with_provider_context("@anthropic-api:claude-sonnet-5-5", "anthropic-api")

    model, provider, _base = route_anthropic_via_claude_code(*resolve_model_provider(picked))

    assert model == "claude-sonnet-5-5"
    assert provider == "anthropic-api"


def _ui_js() -> str:
    return (pathlib.Path(__file__).resolve().parents[1] / "static" / "ui.js").read_text()


def _js_function(src: str, name: str) -> str:
    start = src.index(f"function {name}(")
    return src[start:src.index("\nfunction ", start + 1)]


@pytest.mark.skipif(shutil.which("node") is None, reason="node not installed")
def test_only_a_hidden_anthropic_pin_is_kept_out_of_the_picker():
    src = _ui_js()
    fns = "\n".join(_js_function(src, n) for n in (
        "_providerFromModelValue", "_providerDefersMissingModelFallback", "_isHiddenAnthropicPin"))
    cases = [
        ["@anthropic:claude-sonnet-5-5", None],
        ["claude-sonnet-5-5", "anthropic"],
        ["claude-sonnet-5-5", "anthropic-api"],
        ["@nous:anthropic/claude-sonnet-4.6", None],
        ["gpt-5", "openai"],
    ]
    script = fns + "\nconsole.log(JSON.stringify(" + json.dumps(cases) + ".map(c=>_isHiddenAnthropicPin(c[0],c[1]))));"
    out = subprocess.run(["node", "-e", script], check=True, capture_output=True, text=True).stdout
    assert json.loads(out) == [True, True, False, False, False]

    # The pre-existing guard is unchanged (an active "anthropic" provider must not
    # stop stale models from being corrected).
    script = fns + "\nconsole.log(JSON.stringify(['anthropic','custom:x','openrouter'].map(_providerDefersMissingModelFallback)));"
    out = subprocess.run(["node", "-e", script], check=True, capture_output=True, text=True).stdout
    assert json.loads(out) == [False, True, True]


def test_sync_topbar_keeps_hidden_anthropic_pins():
    src = _ui_js()
    block = src[src.index("function syncTopbar"):]
    block = block[:block.index("\nfunction ")]
    assert ("missingModelIsRoutable=_providerDefersMissingModelFallback(S.session.model_provider||window._activeProvider||null)"
            "||_isHiddenAnthropicPin(currentModel,S.session.model_provider)") in block


def test_old_anthropic_pins_still_resolve(monkeypatch):
    monkeypatch.setattr(cfg_mod, "_claude_cli_installed", lambda: True)
    model, provider, _ = route_anthropic_via_claude_code(
        *resolve_model_provider("@anthropic:claude-sonnet-5-5")
    )
    assert model == "claude-sonnet-5-5"
    assert provider == "claude-code"
