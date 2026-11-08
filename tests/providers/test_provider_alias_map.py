"""One provider alias map: every normalizer agrees, every target is real."""

import pytest

from providers import PROVIDER_ALIASES, list_providers, normalize_provider


def _real_provider_ids() -> set[str]:
    from jarviscopilot_cli.auth import PROVIDER_REGISTRY
    from jarviscopilot_cli.models import CANONICAL_PROVIDERS

    return (
        {p.name for p in list_providers()}
        | set(PROVIDER_REGISTRY)
        | {p.slug for p in CANONICAL_PROVIDERS}
        | {"openrouter", "custom"}
    )


def test_every_alias_targets_a_registered_provider():
    real = _real_provider_ids()
    bad = {alias: target for alias, target in PROVIDER_ALIASES.items() if target not in real}
    assert not bad


def test_canonical_ids_are_not_aliases():
    for profile in list_providers():
        assert PROVIDER_ALIASES.get(profile.name) in (None, profile.name)


def test_all_normalizers_agree():
    from agent.auxiliary_client import _normalize_aux_provider
    from jarviscopilot_cli import models, providers as provider_defs
    from jarviscopilot_cli.auth import AuthError, resolve_provider

    for alias, target in PROVIDER_ALIASES.items():
        assert normalize_provider(alias) == target
        assert models.normalize_provider(alias) == target
        assert provider_defs.normalize_provider(alias) == target
        if alias != "codex":  # aux maps codex itself, to the same target
            assert _normalize_aux_provider(alias) == target
        try:
            assert resolve_provider(alias) == target
        except AuthError:
            pass  # target exists but has no runtime registry entry


@pytest.mark.parametrize(
    "alias, target",
    [
        # These used to resolve differently depending on which table a caller hit.
        ("kimi", "kimi-coding"),
        ("moonshot", "kimi-coding"),
        ("github", "copilot"),
        ("kilo-code", "kilocode"),
        ("kilo-gateway", "kilocode"),
        ("zen", "opencode-zen"),
        ("aigateway", "ai-gateway"),
        ("vercel-ai-gateway", "ai-gateway"),
        ("vllm", "custom"),
        ("llamacpp", "custom"),
    ],
)
def test_former_conflicts_resolve_to_the_registered_provider(alias, target):
    from jarviscopilot_cli import models, providers as provider_defs

    assert models.normalize_provider(alias) == target
    assert provider_defs.normalize_provider(alias) == target


@pytest.mark.parametrize(
    "requested, expected_id",
    [
        ("github", "copilot"),
        ("copilot", "copilot"),
        ("kimi", "kimi-coding"),
        ("kimi-coding-cn", "kimi-coding-cn"),
        ("zen", "opencode-zen"),
        ("kilo", "kilocode"),
        ("vercel", "ai-gateway"),
    ],
)
def test_provider_def_ids_are_jarviscopilot_ids(requested, expected_id):
    """``--provider`` resolution used to return models.dev ids (github-copilot,
    kimi-for-coding, ...), which then leaked into config as the provider."""
    from jarviscopilot_cli.providers import resolve_provider_full

    pdef = resolve_provider_full(requested)
    assert pdef is not None
    assert pdef.id == expected_id


def test_kimi_china_keeps_its_own_endpoint():
    """kimi-coding-cn used to collapse into kimi-for-coding (the global endpoint)."""
    from jarviscopilot_cli.providers import get_provider

    pdef = get_provider("kimi-coding-cn")
    assert pdef is not None
    assert pdef.id == "kimi-coding-cn"
    assert "moonshot.cn" in pdef.base_url


def test_bare_openai_still_routes_through_aggregator_for_provider_defs():
    from jarviscopilot_cli import models, providers as provider_defs

    assert provider_defs.normalize_provider("openai") == "openrouter"
    assert models.normalize_provider("openai") == "openai"
