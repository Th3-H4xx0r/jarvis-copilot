"""Tests for the claude-code provider profile registration + alias reclaim."""

from providers import get_provider_profile, list_providers


def test_claude_code_profile_registered_with_expected_config():
    p = get_provider_profile("claude-code")
    assert p is not None
    assert p.name == "claude-code"
    assert p.auth_type == "external_process"
    assert p.base_url == "claude-cli://local"
    assert p.api_mode == "chat_completions"
    assert p.env_vars == ()
    assert p.supports_health_check is False
    # The five anthropic models the user's Anthropic card shows should also be
    # exposed by Claude Code (they all run on the same models, just via subscription).
    for m in ("claude-opus-4-7", "claude-opus-4-6", "claude-sonnet-4-6",
              "claude-sonnet-4-5", "claude-haiku-4-5"):
        assert m in p.fallback_models, f"missing {m}"


def test_claude_code_aliases_resolve_to_the_new_profile():
    for alias in ("claude-cli", "claude-code-cli", "claude-max"):
        prof = get_provider_profile(alias)
        assert prof is not None and prof.name == "claude-code", (
            f"alias '{alias}' resolved to {prof.name if prof else None}, "
            f"expected 'claude-code'"
        )


def test_claude_code_is_not_shadowed_by_anthropic_alias():
    """The anthropic plugin used to claim 'claude-code' as an alias; this
    regression test ensures the name now resolves to the new CLI provider,
    not the API-key Anthropic provider."""
    p = get_provider_profile("claude-code")
    assert p is not None
    assert p.name == "claude-code"  # must NOT be "anthropic"


def test_anthropic_no_longer_claims_claude_code_alias():
    anthropic = get_provider_profile("anthropic")
    assert anthropic is not None
    assert "claude-code" not in anthropic.aliases
    assert "claude-oauth" not in anthropic.aliases
    # "claude" remains an anthropic alias (it's the generic API-key path)
    assert "claude" in anthropic.aliases


def test_claude_code_visible_in_list_providers():
    names = {p.name for p in list_providers()}
    assert "claude-code" in names
    # And anthropic is still there.
    assert "anthropic" in names
