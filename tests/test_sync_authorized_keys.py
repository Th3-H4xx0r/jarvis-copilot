import os

from agent.sync_authorized_keys import add_authorized_key, is_valid_pubkey

_KEY = ("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILObviouslyFakeKeyBodyHere1234567890 "
        "jc-sync")


def test_valid_pubkey_accepts_ssh_keys():
    assert is_valid_pubkey(_KEY)
    assert is_valid_pubkey("ssh-rsa AAAAB3NzaC1yc2ELongBodyHere0000000 host")
    assert not is_valid_pubkey("")
    assert not is_valid_pubkey("-----BEGIN OPENSSH PRIVATE KEY-----")
    assert not is_valid_pubkey("ssh-ed25519 short")
    assert not is_valid_pubkey("ssh-ed25519 AAAA...\nrm -rf /")  # multi-line


def test_add_key_creates_file_with_perms(tmp_path):
    res = add_authorized_key(_KEY, home=str(tmp_path))
    assert res["added"] is True
    ak = tmp_path / ".ssh" / "authorized_keys"
    assert ak.is_file()
    assert "jarviscopilot-sync" in ak.read_text()
    assert oct(os.stat(tmp_path / ".ssh").st_mode)[-3:] == "700"
    assert oct(ak.stat().st_mode)[-3:] == "600"


def test_add_key_is_idempotent(tmp_path):
    add_authorized_key(_KEY, home=str(tmp_path))
    res2 = add_authorized_key(_KEY, home=str(tmp_path))
    assert res2["added"] is False
    ak = tmp_path / ".ssh" / "authorized_keys"
    # exactly one occurrence of the key body
    assert ak.read_text().count("AAAAC3NzaC1lZDI1NTE5") == 1


def test_add_key_preserves_existing_user_keys(tmp_path):
    ssh = tmp_path / ".ssh"
    ssh.mkdir()
    (ssh / "authorized_keys").write_text("ssh-rsa AAAAUSERKEYBODYHERE000000 me@laptop\n")
    add_authorized_key(_KEY, home=str(tmp_path))
    text = (ssh / "authorized_keys").read_text()
    assert "me@laptop" in text and "jarviscopilot-sync" in text


def test_add_bad_key_rejected(tmp_path):
    assert "error" in add_authorized_key("not a key", home=str(tmp_path))


def test_reject_control_chars(tmp_path):
    # tab / NUL / other control bytes in the comment must be rejected
    assert not is_valid_pubkey("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAALongBody\tevil")
    assert not is_valid_pubkey("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAALongBody\x00evil")
    assert "error" in add_authorized_key(
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAALongBody\x00x", home=str(tmp_path))


def test_refuses_symlinked_ssh_dir(tmp_path):
    import os
    real = tmp_path / "real_ssh"
    real.mkdir()
    link = tmp_path / ".ssh"
    os.symlink(real, link)
    res = add_authorized_key(_KEY, home=str(tmp_path))
    assert "error" in res and "symlink" in res["error"]


def test_refuses_symlinked_authorized_keys(tmp_path):
    import os
    ssh = tmp_path / ".ssh"
    ssh.mkdir()
    target = tmp_path / "evil_target"
    target.write_text("")
    os.symlink(target, ssh / "authorized_keys")
    res = add_authorized_key(_KEY, home=str(tmp_path))
    assert "error" in res          # O_NOFOLLOW refuses to follow the symlink
    assert target.read_text() == ""  # the symlink target was NOT written
