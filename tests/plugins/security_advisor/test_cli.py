"""Break-glass CLI: status and unblock straight from the files, from an SSH shell."""
import argparse
import json


def run(argv):
    from plugins.security_advisor import cli
    parser = argparse.ArgumentParser()
    cli.register_cli(parser)
    return cli.security_command(parser.parse_args(argv))


def test_unblock_all_empties_blocks_json(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    from security.blocklist import default_blocklist
    default_blocklist().block("203.0.113.60", "x", ttl_s=600)
    default_blocklist().block("203.0.113.61", "y", ttl_s=600)
    assert run(["unblock", "--all"]) == 0
    assert json.loads((tmp_path / "security" / "blocks.json").read_text()) == {}
    assert "2" in capsys.readouterr().out


def test_unblock_one_and_status(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    from security.blocklist import default_blocklist
    default_blocklist().block("203.0.113.62", "burst", ttl_s=600)
    assert run(["status"]) == 0
    out = capsys.readouterr().out
    assert "quiet" in out and "203.0.113.62" in out
    assert run(["unblock", "203.0.113.62"]) == 0
    assert not default_blocklist().is_blocked("203.0.113.62")
    assert run(["unblock", "203.0.113.99"]) == 1
    assert run(["unblock"]) == 2
