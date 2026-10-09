"""Sign in with Toyota through Home Assistant's own sign-in flow for the integration."""
import asyncio
import logging

import pytest

from plugins.toyota.account import FLOWS, SignInError, ToyotaAccount
from plugins.toyota.ha import HAError, HAUnreachable

from .fake_ha import FakeHA

PASSWORD = "hunter2-very-secret"


def run(coro):
    return asyncio.run(coro)


def code_form(errors=None):
    return {"type": "form", "step_id": "otp", "flow_id": "f1", "errors": errors or {}}


def test_states():
    assert run(ToyotaAccount(FakeHA(handlers=[])).state()) == {"state": "not_installed"}
    assert run(ToyotaAccount(FakeHA()).state()) == {"state": "signed_out"}
    entry = {"entry_id": "e1", "title": "p@example.com", "state": "loaded"}
    assert run(ToyotaAccount(FakeHA(entries=[entry])).state()) == {"state": "signed_in", "email": "p@example.com"}
    reauth = FakeHA(entries=[entry], flows=[{"flow_id": "r", "handler": "toyota_na", "context": {"source": "reauth"}}])
    assert run(ToyotaAccount(reauth).state())["state"] == "reauth"
    retry = FakeHA(entries=[{**entry, "state": "setup_retry", "reason": "Toyota timed out"}])
    assert run(ToyotaAccount(retry).state()) == {"state": "unavailable", "reason": "Toyota timed out", "email": "p@example.com"}
    down = FakeHA()
    down.reply("GET", "/api/config/config_entries/flow_handlers", HAUnreachable("Home Assistant isn't reachable"))
    assert run(ToyotaAccount(down).state())["state"] == "ha_unreachable"


def test_password_then_code_then_signed_in_with_cloud_updates_only(caplog):
    caplog.set_level(logging.DEBUG)
    ha = FakeHA()
    ha.reply("POST", FLOWS, {"type": "form", "step_id": "user", "flow_id": "f1"})
    ha.reply("POST", f"{FLOWS}/f1", code_form(), {"type": "create_entry", "result": {"entry_id": "e9"}})
    ha.reply("POST", "/api/config/config_entries/options/flow", {"type": "form", "flow_id": "o1"})
    ha.reply("POST", "/api/config/config_entries/options/flow/o1", {"type": "create_entry"})
    account = ToyotaAccount(ha)
    assert run(account.sign_in(" p@example.com ", PASSWORD)) == {"step": "code", "flow_id": "f1"}
    assert run(account.submit_code("f1", " 123456 ")) == {"step": "done"}
    assert ha.posts(f"{FLOWS}/f1") == [(f"{FLOWS}/f1", {"username": "p@example.com", "password": PASSWORD}),
                                       (f"{FLOWS}/f1", {"code": "123456"})]
    assert ha.posts("/api/config/config_entries/options/flow/o1") == [
        ("/api/config/config_entries/options/flow/o1", {"automatic_wake_interval": "0"})]
    assert PASSWORD not in caplog.text


@pytest.mark.parametrize("error,words", [("not_logged_in", "email and password"),
                                         ("sso_account", "Forgot password")])
def test_toyota_refusing_the_password_says_why(error, words):
    ha = FakeHA()
    ha.reply("POST", FLOWS, {"type": "form", "step_id": "user", "flow_id": "f1"})
    ha.reply("POST", f"{FLOWS}/f1", {"type": "form", "step_id": "user", "flow_id": "f1", "errors": {"base": error}})
    with pytest.raises(SignInError, match=words):
        run(ToyotaAccount(ha).sign_in("p@example.com", PASSWORD))


def test_a_wrong_code_keeps_the_flow_so_the_right_code_still_works():
    ha = FakeHA(entries=[{"entry_id": "e1", "title": "p", "state": "loaded"}])
    ha.reply("POST", f"{FLOWS}/f1", code_form({"base": "otp_not_logged_in"}), {"type": "create_entry", "result": {}})
    with pytest.raises(SignInError, match="newest code"):
        run(ToyotaAccount(ha).submit_code("f1", "000000"))
    assert run(ToyotaAccount(ha).submit_code("f1", "123456"))["step"] == "done"


def test_an_expired_sign_in_says_start_again():
    ha = FakeHA()
    ha.reply("POST", f"{FLOWS}/gone", HAError("Invalid flow specified", 404))
    with pytest.raises(SignInError, match="expired"):
        run(ToyotaAccount(ha).submit_code("gone", "123456"))


def test_signing_in_again_on_the_same_account_counts_as_done():
    ha = FakeHA()
    ha.reply("POST", FLOWS, {"type": "form", "step_id": "user", "flow_id": "f1"})
    ha.reply("POST", f"{FLOWS}/f1", code_form(), {"type": "abort", "reason": "reauth_successful"})
    run(ToyotaAccount(ha).sign_in("p@example.com", PASSWORD))
    assert run(ToyotaAccount(ha).submit_code("f1", "1"))["step"] == "done"


def test_old_sign_ins_are_dropped():
    ha = FakeHA(flows=[{"flow_id": "old", "handler": "toyota_na", "context": {"source": "user"}},
                       {"flow_id": "x", "handler": "hue", "context": {"source": "user"}}])
    ha.reply("POST", FLOWS, {"type": "form", "step_id": "user", "flow_id": "f1"})
    ha.reply("POST", f"{FLOWS}/f1", code_form())
    run(ToyotaAccount(ha).sign_in("p@example.com", PASSWORD))
    assert [path for method, path, _ in ha.calls if method == "DELETE"] == [f"{FLOWS}/old"]


def test_sign_in_again_answers_home_assistants_reauth_flow():
    ha = FakeHA(entries=[{"entry_id": "e1", "title": "p", "state": "setup_error"}],
                flows=[{"flow_id": "re", "handler": "toyota_na", "step_id": "user", "context": {"source": "reauth"}}])
    ha.reply("POST", f"{FLOWS}/re", code_form() | {"flow_id": "re"}, {"type": "abort", "reason": "reauth_successful"})
    ha.reply("POST", "/api/config/config_entries/options/flow", {"type": "form", "flow_id": "o1"})
    ha.reply("POST", "/api/config/config_entries/options/flow/o1", {"type": "create_entry"})
    account = ToyotaAccount(ha)
    assert run(account.sign_in("p@example.com", PASSWORD)) == {"step": "code", "flow_id": "re"}
    assert run(account.submit_code("re", "123456")) == {"step": "done"}
    assert not ha.posts(FLOWS + "/f"), "no second flow was started"
    assert ("DELETE", f"{FLOWS}/re", None) not in ha.calls
    assert ha.posts("/api/config/config_entries/options/flow/o1"), "Cloud updates only after a re-auth too"


def test_a_refused_cloud_only_option_is_reported():
    ha = FakeHA(entries=[{"entry_id": "e1", "title": "p", "state": "loaded"}])
    ha.reply("POST", f"{FLOWS}/f1", {"type": "create_entry", "result": {"entry_id": "e1"}})
    ha.reply("POST", "/api/config/config_entries/options/flow", {"type": "form", "flow_id": "o1"})
    ha.reply("POST", "/api/config/config_entries/options/flow/o1", {"type": "form", "errors": {"base": "x"}})
    out = run(ToyotaAccount(ha).submit_code("f1", "1"))
    assert out["step"] == "done" and "Cloud updates only" in out["warning"]


def test_missing_details_and_not_installed_are_refused():
    with pytest.raises(SignInError, match="email and password"):
        run(ToyotaAccount(FakeHA()).sign_in("", PASSWORD))
    with pytest.raises(SignInError, match="isn't set up"):
        run(ToyotaAccount(FakeHA(handlers=[])).sign_in("p@example.com", PASSWORD))
    with pytest.raises(SignInError):
        run(ToyotaAccount(FakeHA()).submit_code("../../api/states", "1"))


def test_sign_out_removes_the_entry():
    ha = FakeHA(entries=[{"entry_id": "e1", "title": "p", "state": "loaded"}])
    assert run(ToyotaAccount(ha).sign_out()) == {"ok": True}
    assert ("DELETE", "/api/config/config_entries/entry/e1", None) in ha.calls
