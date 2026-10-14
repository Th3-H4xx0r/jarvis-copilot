"""The safe action allowlist: only offered items, only fresh offers, never money or email."""
from __future__ import annotations

import pytest

from jarvis_services import actions
from jarvis_services.actions import ALLOWED, MAX_AGE, Refused, check, perform
from jarvis_services.base import Action, Detail, HttpError, Item, Section, Service
from jarvis_services.config import ConfigView

NOW = 1_791_936_000.0
CFG = ConfigView({}, {}, environ={})


class FakeVercel(Service):
    id = "vercel"
    display_name = "Vercel"
    actions = frozenset({"vercel.redeploy", "vercel.promote", "vercel.cancel"})

    def __init__(self, error=None):
        self.error = error
        self.done = []

    def perform(self, http, cfg, kind, target):
        if self.error:
            raise self.error
        self.done.append((kind, target))
        return "Building site-x.vercel.app"


def detail(fetched_at=NOW, *offers):
    return Detail("vercel", "Vercel", sections=[Section("Deployments", [Item("site", actions=list(offers))])],
                  fetched_at=fetched_at)


REDEPLOY = Action("vercel.redeploy", "Redeploy", "d1|site|")
CANCEL = Action("vercel.cancel", "Cancel build", "b1", destructive=True, confirm="Stop this build?")


def test_allowlist_is_exactly_the_safe_nine():
    assert set(ALLOWED) == {"vercel.redeploy", "vercel.promote", "vercel.cancel",
                            "github.rerun", "github.approve", "github.merge",
                            "n8n.activate", "n8n.deactivate", "n8n.retry"}
    assert {k for k, needs_confirm in ALLOWED.items() if needs_confirm} == {
        "vercel.promote", "vercel.cancel", "github.merge", "n8n.deactivate"}
    assert MAX_AGE == 300


@pytest.mark.parametrize("kind", ["stripe.refund", "resend.send", "vercel.delete", "calcom.cancel", "", "refresh"])
def test_anything_else_is_refused(kind):
    with pytest.raises(Refused):
        check(FakeVercel(), detail(NOW, REDEPLOY), kind, "d1|site|", now=NOW)


def test_kind_must_belong_to_the_service():
    with pytest.raises(Refused):
        check(FakeVercel(), detail(NOW, REDEPLOY), "github.merge", "d1|site|", now=NOW)


def test_only_offered_items():
    assert check(FakeVercel(), detail(NOW, REDEPLOY), "vercel.redeploy", "d1|site|", now=NOW) == REDEPLOY
    with pytest.raises(Refused) as e:
        check(FakeVercel(), detail(NOW, REDEPLOY), "vercel.redeploy", "d2|site|", now=NOW)
    assert "isn't offered" in e.value.message
    with pytest.raises(Refused):
        check(FakeVercel(), None, "vercel.redeploy", "d1|site|", now=NOW)


def test_offer_and_request_must_be_under_five_minutes_old():
    check(FakeVercel(), detail(NOW - 299, REDEPLOY), "vercel.redeploy", "d1|site|", now=NOW)
    with pytest.raises(Refused):
        check(FakeVercel(), detail(NOW - 301, REDEPLOY), "vercel.redeploy", "d1|site|", now=NOW)
    with pytest.raises(Refused):
        check(FakeVercel(), detail(NOW, REDEPLOY), "vercel.redeploy", "d1|site|", now=NOW, requested_at=NOW - 301)
    check(FakeVercel(), detail(NOW, REDEPLOY), "vercel.redeploy", "d1|site|", now=NOW, requested_at=NOW - 10)


def test_confirm_actions_need_confirmation():
    with pytest.raises(Refused) as e:
        check(FakeVercel(), detail(NOW, CANCEL), "vercel.cancel", "b1", now=NOW)
    assert e.value.confirm == "Stop this build?"
    assert check(FakeVercel(), detail(NOW, CANCEL), "vercel.cancel", "b1", now=NOW, confirmed=True) == CANCEL


def test_perform_reports_success_and_failure():
    svc = FakeVercel()
    ok = perform(svc, None, CFG, REDEPLOY, NOW)
    assert (ok.title, ok.ok, ok.message, ok.at) == ("Redeploy", True, "Building site-x.vercel.app", NOW)
    assert svc.done == [("vercel.redeploy", "d1|site|")]
    failed = perform(FakeVercel(error=HttpError(403, "missing scope")), None, CFG, REDEPLOY, NOW)
    assert not failed.ok and failed.message.startswith("Not allowed with this key (403)")


def test_no_service_offers_an_unlisted_kind():
    from jarvis_services import default_services
    for svc in default_services():
        assert svc.actions <= set(actions.ALLOWED), svc.id
        assert all(k.startswith(svc.id + ".") for k in svc.actions)
