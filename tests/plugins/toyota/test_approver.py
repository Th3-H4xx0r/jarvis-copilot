"""Face ID approvals: the phone's Secure Enclave key, fresh one-time signatures, Jarvis's approvals."""
import base64
import uuid

import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

from plugins.toyota.approver import (Approvals, ApprovalError, Approver, button_message, button_register_message,
                                     message, register_message)


class Phone:
    """Stands in for the iPhone's Secure Enclave key (the server can't tell the difference)."""

    def __init__(self):
        self.key = ec.generate_private_key(ec.SECP256R1())

    @property
    def public(self) -> str:
        raw = self.key.public_key().public_bytes(serialization.Encoding.X962,
                                                 serialization.PublicFormat.UncompressedPoint)
        return base64.b64encode(raw).decode()

    def _sign(self, data: bytes) -> str:
        return base64.b64encode(self.key.sign(data, ec.ECDSA(hashes.SHA256()))).decode()

    def sign(self, command, nonce, ts) -> str:
        return self._sign(message(command, nonce, ts))

    def sign_register(self, public_key, ts) -> str:
        return self._sign(register_message(public_key, ts))

    def sign_button(self, command, nonce, ts, domain="jarvis-car") -> str:
        return self._sign(button_message(command, nonce, ts, domain))

    def sign_button_register(self, button_key, ts) -> str:
        return self._sign(button_register_message(button_key, ts))

    def register_on(self, keys, ts):
        keys.register(self.public, ts, self.sign_register(self.public, ts))

    def register_button_on(self, keys, button, ts):
        """This (Face ID) key vouches for ``button``, the key that signs Skip Face ID presses."""
        keys.register_button(button.public, ts, self.sign_button_register(button.public, ts))


@pytest.fixture
def clock():
    return [1_800_000_000.0]


@pytest.fixture
def keys(tmp_path, clock):
    return Approver(tmp_path / "car" / "approver.json", clock=lambda: clock[0])


def test_a_fresh_signature_from_the_registered_phone_is_accepted_once(keys, clock):
    phone = Phone()
    phone.register_on(keys, int(clock[0]))
    ts, nonce = int(clock[0]), uuid.uuid4().hex
    keys.verify("unlock", nonce, ts, phone.sign("unlock", nonce, ts))
    with pytest.raises(ApprovalError) as err:
        keys.verify("unlock", nonce, ts, phone.sign("unlock", nonce, ts))
    assert err.value.code == "replayed"


@pytest.mark.parametrize("change,code", [("command", "bad_signature"), ("stale", "stale"), ("other_phone", "bad_signature")])
def test_wrong_old_or_foreign_signatures_are_refused(keys, clock, change, code):
    phone = Phone()
    phone.register_on(keys, int(clock[0]))
    ts, nonce = int(clock[0]), uuid.uuid4().hex
    signer, signed_for = phone, "unlock"
    if change == "command":
        signed_for = "lock"
    if change == "stale":
        ts -= 61
    if change == "other_phone":
        signer = Phone()
    with pytest.raises(ApprovalError) as err:
        keys.verify("unlock", nonce, ts, signer.sign(signed_for, nonce, ts))
    assert err.value.code == code


def test_nothing_is_accepted_before_a_phone_registers(keys, clock):
    with pytest.raises(ApprovalError) as err:
        keys.verify("unlock", "n", int(clock[0]), "AAAA")
    assert err.value.code == "approver_unknown"


def test_a_key_must_prove_itself_and_never_comes_from_the_host(keys, clock):
    phone, other = Phone(), Phone()
    ts = int(clock[0])
    with pytest.raises(ApprovalError):
        keys.register(phone.public)                                            # no proof at all
    with pytest.raises(ApprovalError):
        keys.register(phone.public, ts, other.sign_register(phone.public, ts))  # someone else's proof
    with pytest.raises(ApprovalError) as err:
        keys.register(phone.public, ts, phone.sign_register(phone.public, ts), from_host=True)
    assert err.value.code == "forbidden"
    phone.register_on(keys, ts)
    keys.register(phone.public)                                                # the same key again is fine
    assert keys.registered() == phone.public


def test_a_new_key_needs_the_old_keys_signature(keys, clock):
    first, second = Phone(), Phone()
    ts = int(clock[0])
    first.register_on(keys, ts)
    with pytest.raises(ApprovalError):
        second.register_on(keys, ts)
    keys.register(second.public, ts, first.sign_register(second.public, ts))
    assert keys.registered() == second.public


def test_a_command_signature_never_registers_a_key(keys, clock):
    first, second = Phone(), Phone()
    ts = int(clock[0])
    first.register_on(keys, ts)
    with pytest.raises(ApprovalError):
        keys.register(second.public, ts, first.sign("register", second.public, ts))


def test_the_key_is_kept_in_memory_once_read(tmp_path, clock):
    path = tmp_path / "approver.json"
    keys = Approver(path, clock=lambda: clock[0])
    phone = Phone()
    phone.register_on(keys, int(clock[0]))
    path.write_text('{"public_key": "%s"}' % Phone().public)                 # a change behind its back
    assert keys.registered() == phone.public


def test_an_unreadable_key_file_locks_everything(tmp_path, clock):
    path = tmp_path / "approver.json"
    path.write_text("{ not json")
    keys = Approver(path, clock=lambda: clock[0])
    phone = Phone()
    with pytest.raises(ApprovalError) as err:
        keys.verify("unlock", "n", int(clock[0]), "AAAA")
    assert err.value.code == "locked"
    with pytest.raises(ApprovalError) as err:
        phone.register_on(keys, int(clock[0]))
    assert err.value.code == "locked"


def test_garbage_and_pre_restart_signatures_are_refused(keys, clock):
    with pytest.raises(ApprovalError):
        keys.register("not a key")
    phone = Phone()
    phone.register_on(keys, int(clock[0]))
    with pytest.raises(ApprovalError) as err:
        keys.verify("unlock", "n", int(clock[0]), "!!!")
    assert err.value.code == "bad_request"
    with pytest.raises(ApprovalError) as err:
        keys.verify("unlock", "n", 10 ** 400, phone.sign("unlock", "n", int(clock[0])))
    assert err.value.code == "bad_request"
    with pytest.raises(ApprovalError) as err:
        keys.verify("unlock", "a|b", int(clock[0]), phone.sign("unlock", "a|b", int(clock[0])))
    assert err.value.code == "bad_request"
    before = int(clock[0]) - 10          # signed before this server process started
    with pytest.raises(ApprovalError) as err:
        keys.verify("unlock", "n", before, phone.sign("unlock", "n", before))
    assert err.value.code == "stale"


def test_too_many_approvals_in_a_minute_are_refused(clock):
    waiting = Approvals(clock=lambda: clock[0])
    for name in ["unlock", "lock", "horn", "buzzer", "lights", "start"]:
        waiting.create(name)
    with pytest.raises(ApprovalError) as err:
        waiting.create("hazards_on")
    assert err.value.code == "rate_limited"
    clock[0] += 61
    waiting.create("hazards_on")


def test_approvals_wait_two_minutes_and_end_when_answered(clock):
    waiting = Approvals(clock=lambda: clock[0])
    first = waiting.create("unlock")
    assert first["title"] == "Unlock the car" and first["expires_in_s"] == 120
    again = waiting.create("unlock")
    assert [a["id"] for a in waiting.pending()] == [again["id"]], "asking twice keeps only the newest"
    assert waiting.take(again["id"])["command"] == "unlock"
    with pytest.raises(ApprovalError):
        waiting.take(again["id"])
    late = waiting.create("horn")
    clock[0] += 121
    assert waiting.pending() == []
    with pytest.raises(ApprovalError):
        waiting.peek(late["id"])


# ── Domain separation: the same phone key approves the door alarm ("jarvis-home") ──

def _sign_domain(phone, domain, command, nonce, ts):
    return base64.b64encode(phone.key.sign(message(command, nonce, ts, domain=domain),
                                           ec.ECDSA(hashes.SHA256()))).decode()


def test_message_defaults_to_the_car_domain():
    assert message("unlock", "n", 1) == b"jarvis-car|unlock|n|1"
    assert message("disarm", "n", 1, domain="jarvis-home") == b"jarvis-home|disarm|n|1"


def test_a_car_signature_never_disarms_the_house(keys, clock):
    phone = Phone()
    phone.register_on(keys, int(clock[0]))
    ts, nonce = int(clock[0]), uuid.uuid4().hex
    car_sig = phone.sign("disarm", nonce, ts)  # jarvis-car|disarm|…
    with pytest.raises(ApprovalError) as err:
        keys.verify("disarm", nonce, ts, car_sig, domain="jarvis-home")
    assert err.value.code == "bad_signature"


def test_a_home_signature_verifies_in_its_domain_only(keys, clock):
    phone = Phone()
    phone.register_on(keys, int(clock[0]))
    ts = int(clock[0])
    nonce = uuid.uuid4().hex
    keys.verify("disarm", nonce, ts, _sign_domain(phone, "jarvis-home", "disarm", nonce, ts), domain="jarvis-home")
    other = uuid.uuid4().hex
    with pytest.raises(ApprovalError):
        keys.verify("disarm", other, ts, _sign_domain(phone, "jarvis-home", "disarm", other, ts))


def test_approvals_take_their_own_titles(clock):
    waiting = Approvals(clock=lambda: clock[0], titles={"disarm": "Disarm the door alarm"}, label="door alarm")
    item = waiting.create("disarm")
    assert item["title"] == "Disarm the door alarm"


# ── The button key: a second phone key, no Face ID, for presses that skip it ──

def _nonce():
    return uuid.uuid4().hex


def test_button_messages_have_their_own_prefixes():
    assert button_message("disarm", "n", 1, "jarvis-home") == b"jarvis-button|jarvis-home|disarm|n|1"
    assert button_message("unlock", "n", 1) == b"jarvis-button|jarvis-car|unlock|n|1"
    assert button_register_message("KEY", 1) == b"jarvis-button-register|KEY|1"


def test_button_key_registers_only_with_main_key_signature(keys, clock):
    phone, button, stranger = Phone(), Phone(), Phone()
    ts = int(clock[0])
    with pytest.raises(ApprovalError) as err:                  # no Face ID key to vouch for it yet
        phone.register_button_on(keys, button, ts)
    assert err.value.code == "approver_unknown"
    phone.register_on(keys, ts)
    for signer in (button, stranger):                          # it can't vouch for itself, nor can anyone else
        with pytest.raises(ApprovalError) as err:
            signer.register_button_on(keys, button, ts)
        assert err.value.code == "bad_signature"
    with pytest.raises(ApprovalError) as err:                  # a main-key registration isn't a button one
        keys.register_button(button.public, ts, phone.sign_register(button.public, ts))
    assert err.value.code == "bad_signature"
    with pytest.raises(ApprovalError) as err:
        keys.register_button(button.public, ts - 61, phone.sign_button_register(button.public, ts - 61))
    assert err.value.code == "stale"
    with pytest.raises(ApprovalError) as err:                  # the Face ID key can't double as the button key
        phone.register_button_on(keys, phone, ts)
    assert err.value.code == "bad_key"
    assert keys.button_key() is None
    phone.register_button_on(keys, button, ts)
    assert keys.button_key() == button.public and keys.registered() == phone.public
    again = Approver(keys.path, clock=lambda: clock[0])         # kept in the same file as the Face ID key
    assert again.button_key() == button.public and again.registered() == phone.public


def test_button_key_dropped_when_main_key_replaced(keys, clock):
    first, second, button = Phone(), Phone(), Phone()
    ts = int(clock[0])
    first.register_on(keys, ts)
    first.register_button_on(keys, button, ts)
    keys.register(first.public)                                # the same Face ID key again keeps it
    assert keys.button_key() == button.public
    keys.register(second.public, ts, first.sign_register(second.public, ts))
    assert keys.button_key() is None and keys.registered() == second.public
    assert Approver(keys.path, clock=lambda: clock[0]).button_key() is None
    n = _nonce()
    with pytest.raises(ApprovalError) as err:
        keys.verify("unlock", n, ts, button.sign_button("unlock", n, ts), by_button=True)
    assert err.value.code == "button_key_unknown"


def test_verify_by_button_uses_button_message_not_face_id_message(keys, clock):
    phone, button = Phone(), Phone()
    ts = int(clock[0])
    phone.register_on(keys, ts)
    phone.register_button_on(keys, button, ts)
    for make, by_button in (
        (lambda n: button.sign("unlock", n, ts), True),            # Face ID format, button key
        (lambda n: phone.sign_button("unlock", n, ts), True),      # button format, Face ID key
        (lambda n: button.sign_button("unlock", n, ts), False),    # a button press passed off as Face ID
        (lambda n: phone.sign_button("unlock", n, ts), False),     # button format, checked as Face ID
    ):
        n = _nonce()
        with pytest.raises(ApprovalError) as err:
            keys.verify("unlock", n, ts, make(n), by_button=by_button)
        assert err.value.code == "bad_signature"
    n = _nonce()                                               # domains stay apart for the button key too
    with pytest.raises(ApprovalError) as err:
        keys.verify("disarm", n, ts, button.sign_button("disarm", n, ts, "jarvis-car"), domain="jarvis-home",
                    by_button=True)
    assert err.value.code == "bad_signature"
    n = _nonce()
    keys.verify("disarm", n, ts, button.sign_button("disarm", n, ts, "jarvis-home"), domain="jarvis-home",
                by_button=True)
    n = _nonce()
    keys.verify("unlock", n, ts, button.sign_button("unlock", n, ts), by_button=True)


def test_button_key_only_signs_disarm_silence_and_car_commands(keys, clock):
    phone, button = Phone(), Phone()
    ts = int(clock[0])
    phone.register_on(keys, ts)
    phone.register_button_on(keys, button, ts)
    for command, domain in (("arm", "jarvis-home"), ("set", "jarvis-home"), ("unlock", "jarvis-home"),
                            ("disarm", "jarvis-car"), ("stop", "jarvis-car"), ("register", "jarvis-car")):
        n = _nonce()
        with pytest.raises(ApprovalError) as err:
            keys.verify(command, n, ts, button.sign_button(command, n, ts, domain), domain=domain, by_button=True)
        assert err.value.code == "forbidden", (command, domain)
    for command in ("silence", "disarm"):
        n = _nonce()
        keys.verify(command, n, ts, button.sign_button(command, n, ts, "jarvis-home"), domain="jarvis-home",
                    by_button=True)


def test_verify_by_button_without_key_raises_button_key_unknown(keys, clock):
    phone, button = Phone(), Phone()
    ts = int(clock[0])
    n = _nonce()
    with pytest.raises(ApprovalError) as err:                  # nothing registered at all
        keys.verify("unlock", n, ts, button.sign_button("unlock", n, ts), by_button=True)
    assert err.value.code == "button_key_unknown"
    phone.register_on(keys, ts)
    with pytest.raises(ApprovalError) as err:                  # a Face ID key, but no button key
        keys.verify("unlock", n, ts, button.sign_button("unlock", n, ts), by_button=True)
    assert err.value.code == "button_key_unknown"
    phone.register_button_on(keys, button, ts)
    keys.clear_button()
    assert keys.button_key() is None and keys.registered() == phone.public
    assert Approver(keys.path, clock=lambda: clock[0]).button_key() is None
    with pytest.raises(ApprovalError) as err:
        keys.verify("unlock", n, ts, button.sign_button("unlock", n, ts), by_button=True)
    assert err.value.code == "button_key_unknown"
    keys.clear_button()                                        # clearing twice is fine


def test_register_button_refused_from_host(keys, clock):
    phone, button = Phone(), Phone()
    ts = int(clock[0])
    phone.register_on(keys, ts)
    with pytest.raises(ApprovalError) as err:
        keys.register_button(button.public, ts, phone.sign_button_register(button.public, ts), from_host=True)
    assert err.value.code == "forbidden" and keys.button_key() is None
    phone.register_button_on(keys, button, ts)
    with pytest.raises(ApprovalError) as err:
        keys.clear_button(from_host=True)
    assert err.value.code == "forbidden" and keys.button_key() == button.public


def test_button_proof_replay_refused(keys, clock):
    phone, button = Phone(), Phone()
    ts = int(clock[0])
    phone.register_on(keys, ts)
    phone.register_button_on(keys, button, ts)
    n = _nonce()
    keys.verify("lock", n, ts, button.sign_button("lock", n, ts), by_button=True)
    with pytest.raises(ApprovalError) as err:
        keys.verify("lock", n, ts, button.sign_button("lock", n, ts), by_button=True)
    assert err.value.code == "replayed"
    with pytest.raises(ApprovalError) as err:                  # nor as a Face ID approval with the same code
        keys.verify("lock", n, ts, phone.sign("lock", n, ts))
    assert err.value.code == "replayed"
    clock[0] += 61                                             # and an old press is stale
    m = _nonce()
    with pytest.raises(ApprovalError) as err:
        keys.verify("lock", m, ts, button.sign_button("lock", m, ts), by_button=True)
    assert err.value.code == "stale"


def test_a_cleared_button_key_is_not_brought_back_by_a_replayed_registration(keys, clock):
    phone, button = Phone(), Phone()
    ts = int(clock[0])
    phone.register_on(keys, ts)
    sig = phone.sign_button_register(button.public, ts)
    keys.register_button(button.public, ts, sig)
    keys.register_button(button.public, ts, sig)               # the phone retrying is fine while it holds
    keys.clear_button()
    with pytest.raises(ApprovalError) as err:
        keys.register_button(button.public, ts, sig)
    assert err.value.code == "replayed" and keys.button_key() is None
