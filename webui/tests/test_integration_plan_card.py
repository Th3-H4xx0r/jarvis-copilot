"""The plan card in chat: a proposal the user acts on, not a tool result to skim."""
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
UI_JS = (REPO / "static" / "ui.js").read_text(encoding="utf-8")
INTEGRATIONS_JS = (REPO / "static" / "integrations.js").read_text(encoding="utf-8")
CSS = (REPO / "static" / "style.css").read_text(encoding="utf-8")


def test_the_plan_tool_call_renders_as_a_card_instead():
    assert "tc.name==='integration_plan_propose'" in UI_JS, (
        "buildToolCard() must hand an integration plan to the plan card renderer"
    )
    assert "function buildIntegrationPlanCard(tc)" in INTEGRATIONS_JS


def test_the_plan_id_survives_the_snippet():
    """The chat keeps 200 characters of a tool result, so the id has to be near the
    front — which it is, because the tool returns {"ok":…,"plan":{"id":…."""
    import re

    pattern = re.search(r'const m = /(.+?)/\.exec', INTEGRATIONS_JS)
    assert pattern, "the plan id extraction regex is gone"
    result = '{"ok": true, "plan": {"id": "a1b2c3d4e5f6", "space_id": "gym-sessions"'
    assert re.search(pattern.group(1).replace("\\\\", "\\"), result)


def test_nothing_is_created_until_the_user_presses_create():
    """The card's own copy has to say so, and the only write is the approve POST."""
    assert "Nothing exists until you say so." in INTEGRATIONS_JS
    # The card's only writes are the two decisions, and both go through the plans API.
    assert "_intgPlanDecide(row, plan, 'approve')" in INTEGRATIONS_JS
    assert "_intgPlanDecide(row, plan, 'cancel')" in INTEGRATIONS_JS
    assert "/api/integrations/plans/${encodeURIComponent(plan.id)}/${action}" in INTEGRATIONS_JS


def test_a_decided_plan_still_renders():
    for status in ("approved", "cancelled"):
        assert f"'{status}'" in INTEGRATIONS_JS, (
            f"a {status} plan must still draw, for a conversation scrolled back to later"
        )


def test_the_card_layout_is_fixed_in_css_not_by_the_model():
    for cls in ("plan-card-head", "plan-card-section-label", "plan-card-item", "plan-card-foot"):
        assert f".{cls}" in CSS, f"{cls} has no style, so the card would render unstyled"


def test_the_card_is_never_hidden_inside_the_collapsed_activity_group():
    """It asks for a decision, so it cannot need unfolding to be seen.

    With simplified tool calling every tool card goes into an activity group that
    starts collapsed; the plan card is placed after that group instead.
    """
    assert "function _isStandaloneCard(el)" in UI_JS
    assert "planCards=built.filter(_isStandaloneCard)" in UI_JS
    assert "toolCards=built.filter(el=>!_isStandaloneCard(el))" in UI_JS
    # And in the plain branch, the Expand all toggle only counts real tool cards.
    assert "frag.querySelectorAll('.tool-card').length>=2" in UI_JS


PANELS_JS = (REPO / "static" / "panels.js").read_text(encoding="utf-8")
MESSAGES_JS = (REPO / "static" / "messages.js").read_text(encoding="utf-8")


def test_the_card_draws_during_the_turn_not_only_after_it():
    """tool_complete carries no result, so the card had no plan id until turn end."""
    assert "source.addEventListener('tool_result'" in MESSAGES_JS
    assert "_isStandaloneCard(liveCard)" in UI_JS, (
        "the live path must keep the card out of the collapsed activity group too"
    )


def test_a_schedule_keeps_its_integration_when_the_first_save_is_rejected():
    """An unparseable schedule is a 400; the retry must still file it in the same place."""
    assert "if(_intgPendingForNewJob) body.integration=_intgPendingForNewJob;" in PANELS_JS
    # Cleared when the form closes, never mid-save.
    assert "_intgPendingForNewJob = null;   // the integrations page re-sets it right after" in PANELS_JS
    assert "_intgPendingForNewJob = null;   // a duplicate belongs where the original does" in PANELS_JS


def test_a_slow_response_cannot_land_under_a_later_screen():
    assert "let _intgView = '';" in INTEGRATIONS_JS
    assert INTEGRATIONS_JS.count("if (_intgView !== mine) return;") >= 3
