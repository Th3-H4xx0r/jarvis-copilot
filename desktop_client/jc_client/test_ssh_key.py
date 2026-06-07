import os

from jc_client import ssh_key


def test_render_block_has_alias_and_proxy():
    block = ssh_key.render_ssh_config_block(
        identity="/k/id", proxy_command="jc-client tcp-relay", user="root")
    assert "Host jc-hermes" in block
    assert "ProxyCommand jc-client tcp-relay" in block
    assert "IdentityFile /k/id" in block
    assert "StrictHostKeyChecking no" in block
    assert block.startswith("# >>> jarviscopilot-sync")


def test_upsert_block_inserts_then_replaces():
    block1 = ssh_key.render_ssh_config_block(identity="/a", proxy_command="cmd1")
    out1 = ssh_key.upsert_block("Host other\n  User x\n", block1)
    assert "Host other" in out1 and "cmd1" in out1
    # replacing keeps the user's block + swaps ours (no duplicate markers)
    block2 = ssh_key.render_ssh_config_block(identity="/b", proxy_command="cmd2")
    out2 = ssh_key.upsert_block(out1, block2)
    assert out2.count("# >>> jarviscopilot-sync") == 1
    assert "cmd2" in out2 and "cmd1" not in out2
    assert "Host other" in out2


def test_write_ssh_config_idempotent(tmp_path):
    p1 = ssh_key.write_ssh_config(str(tmp_path), identity="/k", proxy_command="cmd")
    p2 = ssh_key.write_ssh_config(str(tmp_path), identity="/k", proxy_command="cmd")
    assert p1 == p2
    text = open(p1).read()
    assert text.count("Host jc-hermes") == 1
    assert oct(os.stat(p1).st_mode)[-3:] == "600"


def test_ensure_keypair_uses_keygen_then_idempotent(tmp_path):
    calls = {"n": 0}

    def fake_keygen(argv):
        calls["n"] += 1
        # emulate ssh-keygen writing the priv + .pub
        priv = argv[argv.index("-f") + 1]
        open(priv, "w").write("PRIV")
        open(priv + ".pub", "w").write("ssh-ed25519 AAAAFAKEKEYBODY jc-sync")
        return 0

    priv, pub = ssh_key.ensure_keypair(str(tmp_path / "state"), keygen=fake_keygen)
    assert pub.startswith("ssh-ed25519")
    assert calls["n"] == 1
    # second call: key exists -> no keygen invocation
    ssh_key.ensure_keypair(str(tmp_path / "state"), keygen=fake_keygen)
    assert calls["n"] == 1
