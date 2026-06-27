"""Manage the desktop's sync SSH key + an isolated ssh-config host alias.

Mutagen shells out to the system ``ssh``, which reads ``~/.ssh/config``. We add a
single tagged ``Host jc-hermes`` block whose ``ProxyCommand`` pipes the SSH
stream through the WS<->TCP relay (``jc-client tcp-relay``), authenticating with a
dedicated key we manage under the client state dir. The block is delimited by
markers so it is replaced idempotently and never clobbers the user's own config.
"""
from __future__ import annotations

import os
import subprocess
from typing import Callable, Optional, Tuple

HOST_ALIAS = "jc-hermes"
_BEGIN = "# >>> jarviscopilot-sync >>>"
_END = "# <<< jarviscopilot-sync <<<"


def ensure_keypair(state_dir: str,
                   keygen: Optional[Callable[[list], int]] = None) -> Tuple[str, str]:
    """Ensure an ed25519 keypair exists under ``state_dir``; return (priv, pub_text).

    Generated once via ``ssh-keygen`` (present on macOS + Linux). ``keygen`` is an
    injectable runner ``(argv) -> rc`` for tests. Raises RuntimeError if the key
    can't be created.
    """
    os.makedirs(state_dir, exist_ok=True)
    priv = os.path.join(state_dir, "sync_id_ed25519")
    pub = priv + ".pub"
    if os.path.isfile(priv) and os.path.isfile(pub):
        return priv, _read(pub)
    run = keygen or _run_keygen
    rc = run(["ssh-keygen", "-t", "ed25519", "-N", "", "-C", "jarviscopilot-sync",
              "-f", priv])
    if rc != 0 or not os.path.isfile(pub):
        raise RuntimeError("ssh-keygen failed to create the sync key")
    try:
        os.chmod(priv, 0o600)
    except OSError:
        pass
    return priv, _read(pub)


def _run_keygen(argv: list) -> int:
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=30).returncode
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return 1


def render_ssh_config_block(*, identity: str, proxy_command: str,
                            user: str = "root", host_alias: str = HOST_ALIAS) -> str:
    """The tagged ssh-config block for the relay host alias (pure)."""
    return "\n".join([
        _BEGIN,
        f"Host {host_alias}",
        f"    HostName {host_alias}",
        f"    User {user}",
        f"    IdentityFile {identity}",
        "    IdentitiesOnly yes",
        "    StrictHostKeyChecking no",
        "    UserKnownHostsFile /dev/null",
        "    BatchMode yes",
        # Multiplex all ssh to this alias over ONE persistent connection so
        # Mutagen + the conflict healer reuse a single relay instead of dialing a
        # fresh SSH (= a new relay open/close) per reconnect — which spammed the
        # server's tcp-relay log several times a second. ControlPath uses %C (a
        # short hash) to stay under macOS's 104-byte unix-socket path limit.
        "    ControlMaster auto",
        "    ControlPath ~/.ssh/jc-cm-%C",
        "    ControlPersist 60s",
        # Real SSH-level keepalive so a momentarily proxy-held frame isn't
        # mistaken for a dead peer (which triggered the rapid redial loop).
        "    ServerAliveInterval 10",
        "    ServerAliveCountMax 3",
        f"    ProxyCommand {proxy_command}",
        _END,
    ])


def upsert_block(existing: str, block: str) -> str:
    """Insert or replace the tagged block within ``existing`` ssh-config text."""
    b, e = existing.find(_BEGIN), existing.find(_END)
    if b != -1 and e != -1 and e > b:
        before = existing[:b].rstrip("\n")
        after = existing[e + len(_END):].lstrip("\n")
        parts = [p for p in (before, block, after) if p]
        return "\n".join(parts).rstrip("\n") + "\n"
    base = existing.rstrip("\n")
    sep = "\n\n" if base else ""
    return f"{base}{sep}{block}\n"


def write_ssh_config(home: str, *, identity: str, proxy_command: str,
                     user: str = "root") -> str:
    """Idempotently write the relay host-alias block into ``<home>/.ssh/config``.
    Returns the config path."""
    ssh_dir = os.path.join(home, ".ssh")
    os.makedirs(ssh_dir, mode=0o700, exist_ok=True)
    cfg = os.path.join(ssh_dir, "config")
    existing = _read(cfg) if os.path.isfile(cfg) else ""
    block = render_ssh_config_block(identity=identity, proxy_command=proxy_command,
                                    user=user)
    with open(cfg, "w", encoding="utf-8") as fh:
        fh.write(upsert_block(existing, block))
    try:
        os.chmod(cfg, 0o600)
    except OSError:
        pass
    return cfg


def _read(path: str) -> str:
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()
