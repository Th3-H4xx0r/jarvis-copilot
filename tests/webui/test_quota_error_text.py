"""Anthropic's pay-as-you-go exhaustion message must classify as a quota
failure. It reads "You're out of extra usage" (HTTP 400) and was falling into
the generic "error" bucket, so voice retried the dead model every turn instead
of putting the pick on cooldown."""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "webui"))

from api.streaming import _is_quota_error_text, _classify_provider_error


def test_out_of_extra_usage_is_a_quota_failure():
    assert _is_quota_error_text("You're out of extra usage. Upgrade to continue.")
    assert _is_quota_error_text("out of extra usage")
    assert _classify_provider_error("You're out of extra usage")["type"] == "quota_exhausted"


def test_existing_quota_shapes_still_match():
    assert _is_quota_error_text("insufficient credit balance")
    assert _is_quota_error_text("You exceeded your current quota")
    assert _is_quota_error_text("plan limit reached")


def test_unrelated_errors_are_not_quota():
    assert not _is_quota_error_text("connection reset by peer")
    assert not _is_quota_error_text("tool crashed while running")
