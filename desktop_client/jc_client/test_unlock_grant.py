"""Unlock permission (his ask 2026-11-20): one Face ID-signed permission lets Jarvis unlock this computer without
asking each time, until it ends (30 days at most). jc-client keeps it and hands it to the Jarvis app, which checks
the signature itself; a refused permission falls back to the Face ID request."""
from jc_client.password_broker import PasswordBroker
from jc_client.unlock_grant import GrantStore

NOW = 1_800_000_000.0
G = {"id": "ab" * 16, "ts": int(NOW), "until": int(NOW + 3600), "device": "pc-1", "signature": "MEUC"}


def test_a_permission_is_kept_across_restarts_until_it_ends(tmp_path):
    t = {"now": NOW}
    store = GrantStore(tmp_path / "grant.json", clock=lambda: t["now"])
    store.set(G)
    assert GrantStore(tmp_path / "grant.json", clock=lambda: t["now"]).current() == G
    t["now"] += 3601
    assert store.current() is None


def test_a_stopped_permission_never_comes_back(tmp_path):
    store = GrantStore(tmp_path / "grant.json", clock=lambda: NOW)
    store.set(G)
    store.revoke(G["id"])
    assert store.current() is None
    store.set(G)                                  # a replay of the stopped one
    assert store.current() is None
    assert GrantStore(tmp_path / "grant.json", clock=lambda: NOW).current() is None


def test_bad_permissions_are_ignored(tmp_path):
    store = GrantStore(tmp_path / "grant.json", clock=lambda: NOW)
    for bad in ({}, dict(G, id="x"), dict(G, until=int(NOW - 1)), "junk", dict(G, signature="")):
        store.set(bad)
        assert store.current() is None


def _broker(app_answers, grant):
    asked, ups = [], []

    def ask_app(msg, timeout):
        asked.append(msg)
        return app_answers.pop(0) if app_answers else {"ok": False}
    b = PasswordBroker(ups.append, lambda m: None, ask_app, unlock_grant=lambda: grant, device_id="pc-1")
    b._wait = lambda event, timeout: False         # no phone answer in these tests
    return b, asked, ups


def test_an_unlock_with_a_permission_skips_the_phone():
    b, asked, ups = _broker([{"ok": True}], G)
    assert b.request("unlock", "Unlock PC") == {"ok": True}
    assert asked[0]["grant"] == G and asked[0]["device"] == "pc-1" and asked[0]["kind"] == "unlock"
    assert not [u for u in ups if (u.get("name") or "") == "mac_password_request"]


def test_a_refused_permission_falls_back_to_face_id():
    b, asked, ups = _broker([{"ok": False, "error": "The permission didn't check out"}], G)
    out = b.request("unlock", "Unlock PC")
    assert asked[0]["grant"] == G
    assert [u for u in ups if (u.get("name") or "") == "mac_password_request"]   # the phone was asked
    assert out["ok"] is False                                                     # (no answer in the test)


def test_other_kinds_never_use_the_permission():
    b, asked, ups = _broker([], G)
    b.request("sudo", "sudo ls")
    assert not [m for m in asked if "grant" in m]


def test_the_pc_and_mac_power_objects_keep_the_permission_from_the_server(tmp_path):
    from jc_client.pc_power import PcPower
    store = GrantStore(tmp_path / "g.json", clock=lambda: NOW)
    p = PcPower(lambda f: True, set_state=lambda f: 1, lock=lambda: None, suspend=lambda: None,
                probe=lambda: ({"capable": True, "adapter": "x", "reason": ""}, "aa:bb:cc:dd:ee:ff"),
                battery=lambda: (None, None), lan_ip=lambda: "", grants=store, device_id="pc-1",
                wake=type("W", (), {"timer_on": True, "quiet": lambda s: False, "asleep": lambda s: False})())
    p.handle_frame({"type": "mac_unlock_grant", "grant": G})
    assert store.current() == G and p.passwords._device_id == "pc-1"
    p.handle_frame({"type": "mac_unlock_grant", "revoke": G["id"]})
    assert store.current() is None
