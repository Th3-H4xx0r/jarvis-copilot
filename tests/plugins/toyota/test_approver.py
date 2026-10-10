"""Face ID approvals: the phone's Secure Enclave key, fresh one-time signatures, Jarvis's approvals."""
import base64
import uuid

import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

from plugins.toyota.approver import Approvals, ApprovalError, Approver, message, register_message


class Phone:
    """Stands in for the iPhone's Secure Enclave key (the server can't tell the difference)."""

    def __init__(self):
        self.key = ec.generate_private_key(ec.SECP256R1())

    @property
    def public(self) -> str:
        raw = self.key.public_key().public_bytes(serialization.Encoding.X962,
                                                 serialization.PublicFormat.UncompressedPoint)
        return base64.b64encode(raw).decode()

    def sign(self, command, nonce, ts) -> str:
        return base64.b64encode(self.key.sign(message(command, nonce, ts), ec.ECDSA(hashes.SHA256()))).decode()

    def sign_register(self, public_key, ts) -> str:
        return base64.b64encode(self.key.sign(register_message(public_key, ts), ec.ECDSA(hashes.SHA256()))).decode()

    def register_on(self, keys, ts):
        keys.register(self.public, ts, self.sign_register(self.public, ts))


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
