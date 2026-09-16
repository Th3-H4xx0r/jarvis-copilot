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
