"""``jc-client`` CLI entry point.

Subcommands:
    pair              open Tk dialog (interactive)
    pair --server URL --code XXX-XXX --name NAME  (headless)
    start             foreground service (systemd / launchd ExecStart)
    stop              kill the running daemon via PID file
    restart           stop + start
    status            show paired-server + connection + skill count
    logs [--follow]   tail the client log
    skills list       what skills the client currently advertises
    skills disable <name> / enable <name>
    config get|set [key [value]]
    tray              spawn tray app (Windows + macOS menubar + linux AppIndicator)
    unpair            wipe credentials
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from jc_client import credentials, pair_ui, service, skills
from jc_client.logger import log_path, setup as setup_logging, state_dir
from jc_client.protocol import HttpClient

log = logging.getLogger(__name__)


PID_FILE = state_dir() / "jc-client.pid"
TRAY_PID_FILE = state_dir() / "jc-client-tray.pid"


# ── PID file helpers ──────────────────────────────────────────────────────


def _read_pid() -> int | None:
    try:
        raw = PID_FILE.read_text().strip()
        return int(raw) if raw else None
    except (FileNotFoundError, ValueError):
        return None


def _write_pid(pid: int) -> None:
    PID_FILE.parent.mkdir(parents=True, exist_ok=True)
    PID_FILE.write_text(str(pid))


def _read_tray_pid() -> int | None:
    try:
        raw = TRAY_PID_FILE.read_text().strip()
        return int(raw) if raw else None
    except (FileNotFoundError, ValueError):
        return None


def _write_tray_pid(pid: int) -> None:
    TRAY_PID_FILE.parent.mkdir(parents=True, exist_ok=True)
    TRAY_PID_FILE.write_text(str(pid))


def _is_running(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False


# ── Supervisor (LaunchAgent / systemd) helpers ────────────────────────────

_LAUNCHCTL_LABEL = "com.jarviscopilot.client"
_LAUNCHCTL_PLIST = Path.home() / "Library/LaunchAgents/com.jarviscopilot.client.plist"
_SYSTEMD_UNIT = "jc-client.service"


def _supervisor_kind() -> str | None:
    """Return 'launchctl' if a macOS LaunchAgent plist exists, 'systemd'
    if the user systemd unit exists, else None. The supervisor is the
    process responsible for keeping the service alive across reboots /
    crashes — if one's installed, `start`/`stop`/`restart` must drive
    it rather than fight it."""
    if sys.platform == "darwin" and _LAUNCHCTL_PLIST.is_file():
        return "launchctl"
    if sys.platform.startswith("linux"):
        try:
            unit = Path.home() / f".config/systemd/user/{_SYSTEMD_UNIT}"
            if unit.is_file():
                return "systemd"
        except Exception:
            pass
    return None


def _supervisor_is_loaded() -> bool:
    kind = _supervisor_kind()
    if kind == "launchctl":
        rc = subprocess.run(
            ["launchctl", "list", _LAUNCHCTL_LABEL],
            capture_output=True, text=True,
        )
        return rc.returncode == 0
    if kind == "systemd":
        rc = subprocess.run(
            ["systemctl", "--user", "is-active", "--quiet", _SYSTEMD_UNIT],
            capture_output=True, text=True,
        )
        return rc.returncode == 0
    return False


def _supervisor_load() -> None:
    kind = _supervisor_kind()
    if kind == "launchctl":
        subprocess.run(
            ["launchctl", "load", "-w", str(_LAUNCHCTL_PLIST)],
            capture_output=True, text=True, check=False,
        )
    elif kind == "systemd":
        subprocess.run(
            ["systemctl", "--user", "start", _SYSTEMD_UNIT],
            capture_output=True, text=True, check=False,
        )


def _supervisor_unload() -> None:
    kind = _supervisor_kind()
    if kind == "launchctl":
        subprocess.run(
            ["launchctl", "unload", str(_LAUNCHCTL_PLIST)],
            capture_output=True, text=True, check=False,
        )
    elif kind == "systemd":
        subprocess.run(
            ["systemctl", "--user", "stop", _SYSTEMD_UNIT],
            capture_output=True, text=True, check=False,
        )


# ── Subcommands ────────────────────────────────────────────────────────────


def cmd_pair(args) -> int:
    """Interactive Tk dialog OR headless pairing via --server/--code."""
    if args.server and args.code:
        return _pair_headless(args.server, args.code, args.name)
    # Interactive.
    try:
        creds = pair_ui.show()
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0 if creds else 1


def _pair_headless(url: str, code: str, name: str | None) -> int:
    name = name or socket.gethostname()
    log.info("pairing %s with %s", url, name)
    try:
        client = HttpClient(url, expected_fingerprint="")
        resp, fingerprint = client.post_json(
            "/api/auth/pair/claim", {"code": code, "name": name}
        )
    except Exception as exc:
        print(f"pair failed: {exc}", file=sys.stderr)
        return 1
    if resp.status != 200 or not resp.cookie:
        err = resp.json().get("error") if resp.body else None
        print(f"pair failed: HTTP {resp.status} — {err or 'unknown'}", file=sys.stderr)
        return 1
    creds = credentials.load()
    creds.server_url = url.rstrip("/")
    creds.device_name = name
    creds.cookie = resp.cookie
    creds.cert_fingerprint = fingerprint
    if not creds.device_id:
        import uuid
        creds.device_id = uuid.uuid4().hex
    credentials.save(creds)
    print(f"Paired with {url}")
    print(f"  Device name: {name}")
    print(f"  Cert SHA-256: {fingerprint}")
    return 0


def cmd_start(args) -> int:
    """Start the service. With --no-tray, headless service in the
    foreground. Otherwise: ensure the supervisor (LaunchAgent / systemd)
    is loaded, then open the menubar tray. If no supervisor is
    installed, runs the service in a background thread via the tray."""
    # Headless mode: explicit, used by LaunchAgent/systemd themselves.
    if getattr(args, "no_tray", False):
        pid = _read_pid()
        if pid and _is_running(pid):
            print(f"already running (pid {pid})", file=sys.stderr)
            return 1
        _write_pid(os.getpid())
        try:
            return service.run(verbose=args.verbose)
        finally:
            try:
                PID_FILE.unlink()
            except FileNotFoundError:
                pass

    # Interactive: hand supervision off to launchctl/systemd if one is
    # installed. Otherwise the tray will spawn the service itself.
    sup = _supervisor_kind()
    if sup and not _supervisor_is_loaded():
        print(f"loading {sup} supervisor …")
        _supervisor_load()
        # Wait for the supervisor's child to claim the PID file before
        # the tray tries to spawn its own — otherwise both register as
        # the same device, the server kicks them in turn, and we get
        # the 1Hz reconnect storm again. ~3s is enough for launchd /
        # systemd to spawn + the service to write its pid.
        deadline = time.time() + 3.0
        while time.time() < deadline:
            pid = _read_pid()
            if pid and _is_running(pid):
                break
            time.sleep(0.1)

    # The tray is a GUI process. Run it DETACHED (its own session, stdio to
    # /dev/null) so closing this terminal doesn't SIGHUP the menubar icon —
    # `jc-client start` should background it, not tie it to the shell.
    try:
        import pystray  # noqa: F401  (probe: is a GUI tray even possible here?)
        have_gui = True
    except Exception:
        have_gui = False

    if have_gui:
        existing = _read_tray_pid()
        if existing and _is_running(existing):
            print(f"tray already running (pid {existing})")
            return 0
        proc = subprocess.Popen(
            [sys.executable, "-m", "jc_client", "tray"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
        )
        _write_tray_pid(proc.pid)
        print(f"tray started in background (pid {proc.pid}). "
              "Safe to close this terminal.")
        return 0

    # No GUI here. If a supervisor runs the service, we're done; otherwise run
    # the service in the foreground so the command isn't silently useless.
    if sup:
        print(f"no GUI available — service is supervised by {sup}")
        return 0
    pid = _read_pid()
    if pid and _is_running(pid):
        print(f"already running (pid {pid})", file=sys.stderr)
        return 1
    print("tray unavailable — running service in foreground", file=sys.stderr)
    _write_pid(os.getpid())
    try:
        return service.run(verbose=args.verbose)
    finally:
        try:
            PID_FILE.unlink()
        except FileNotFoundError:
            pass


def cmd_stop(args) -> int:
    # Also stop the detached tray UI we launched from `start`, so the menubar
    # icon doesn't linger after the service is stopped.
    tray_pid = _read_tray_pid()
    if tray_pid and _is_running(tray_pid):
        try:
            os.kill(tray_pid, signal.SIGTERM)
        except OSError:
            pass
    try:
        TRAY_PID_FILE.unlink()
    except FileNotFoundError:
        pass

    # Drive the supervisor first — otherwise killing the PID just
    # triggers an instant launchd/systemd respawn.
    sup = _supervisor_kind()
    if sup and _supervisor_is_loaded():
        _supervisor_unload()
        print(f"stopped ({sup})")
        return 0

    pid = _read_pid()
    if not pid or not _is_running(pid):
        print("not running", file=sys.stderr)
        return 1
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError as exc:
        print(f"kill failed: {exc}", file=sys.stderr)
        return 1
    # Wait up to 5s for the process to exit.
    for _ in range(50):
        if not _is_running(pid):
            break
        time.sleep(0.1)
    try:
        PID_FILE.unlink()
    except FileNotFoundError:
        pass
    print("stopped")
    return 0


def cmd_restart(args) -> int:
    # Through supervisor: cleanest path.
    sup = _supervisor_kind()
    if sup:
        if _supervisor_is_loaded():
            _supervisor_unload()
            # Give launchctl a beat to release the slot before re-loading.
            time.sleep(0.5)
        _supervisor_load()
        print(f"restarted ({sup})")
        return 0

    rc = cmd_stop(args)
    # Re-spawn ourselves detached.
    py = sys.executable
    subprocess.Popen(
        [py, "-m", "jc_client", "start"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
        close_fds=True,
    )
    print("restarted")
    return 0


def cmd_status(args) -> int:
    creds = credentials.load()
    pid = _read_pid()
    running = pid is not None and _is_running(pid)
    print("JarvisCopilot client status")
    print("  paired:       ", "yes" if creds.paired else "no")
    if creds.paired:
        print("  server:       ", creds.server_url)
        print("  device name:  ", creds.device_name)
        print("  cert fp:      ", creds.cert_fingerprint[:32] + "…")
    print("  running:      ", "yes (pid %s)" % pid if running else "no")
    print("  log file:     ", log_path())
    skills.load_all(allow_shell=creds.allow_shell)
    manifest = skills.all_manifest(disabled=creds.skills_disabled)
    print("  skills enabled:", len(manifest), "/", len(skills.registered_names()))
    print("  allow_shell:  ", "yes" if creds.allow_shell else "no")
    return 0


def cmd_logs(args) -> int:
    path = log_path()
    if not path.exists():
        print(f"no log file yet ({path})", file=sys.stderr)
        return 1
    if args.follow:
        try:
            # Tail-follow without external deps. Sleep-poll is fine for
            # human reading speeds.
            with path.open("r", encoding="utf-8", errors="replace") as fh:
                fh.seek(0, os.SEEK_END)
                while True:
                    line = fh.readline()
                    if not line:
                        time.sleep(0.3)
                        continue
                    sys.stdout.write(line)
                    sys.stdout.flush()
        except KeyboardInterrupt:
            return 0
    else:
        sys.stdout.write(path.read_text(encoding="utf-8", errors="replace"))
        return 0


def cmd_skills(args) -> int:
    creds = credentials.load()
    skills.load_all(allow_shell=creds.allow_shell)
    sub = args.skills_command
    if sub == "list":
        manifest = skills.all_manifest()
        disabled = set(creds.skills_disabled)
        for s in manifest:
            mark = " " if s["name"] not in disabled else "✗"
            destr = "  destructive" if s.get("destructive") else ""
            print(f"  [{mark}] {s['name']:<22} {s['description'][:60]}{destr}")
        return 0
    if sub == "disable":
        name = args.skill_name
        if not skills.has_skill(name):
            print(f"unknown skill: {name}", file=sys.stderr)
            return 1
        creds.skills_disabled = sorted(set(creds.skills_disabled) | {name})
        credentials.save(creds)
        print(f"disabled {name}; restart the service for changes to apply")
        return 0
    if sub == "enable":
        name = args.skill_name
        creds.skills_disabled = [s for s in creds.skills_disabled if s != name]
        credentials.save(creds)
        print(f"enabled {name}; restart the service for changes to apply")
        return 0
    return 2


def cmd_config(args) -> int:
    creds = credentials.load()
    sub = args.config_command
    if sub == "get":
        if args.key:
            print(getattr(creds, args.key, ""))
        else:
            for f in (
                "server_url",
                "device_name",
                "cert_fingerprint",
                "device_id",
                "allow_shell",
                "skills_disabled",
            ):
                print(f"{f} = {getattr(creds, f)!r}")
        return 0
    if sub == "set":
        if not hasattr(creds, args.key):
            print(f"unknown key: {args.key}", file=sys.stderr)
            return 1
        cur = getattr(creds, args.key)
        # Type-coerce the incoming string based on the existing value's type.
        new: Any
        if isinstance(cur, bool):
            new = args.value.strip().lower() in ("1", "true", "yes", "on")
        elif isinstance(cur, list):
            new = [v.strip() for v in args.value.split(",") if v.strip()]
        else:
            new = args.value
        setattr(creds, args.key, new)
        credentials.save(creds)
        print(f"{args.key} = {new!r}")
        return 0
    return 2


def cmd_unpair(args) -> int:
    print("This will wipe the saved server URL, cookie, and pinned cert.")
    if not args.yes:
        try:
            resp = input("Continue? [y/N] ").strip().lower()
        except EOFError:
            resp = ""
        if resp != "y":
            print("aborted")
            return 1
    # Stop the daemon if it's running so it doesn't keep using stale creds.
    pid = _read_pid()
    if pid and _is_running(pid):
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    credentials.clear()
    print("unpaired. Run `jc-client pair` to set up again.")
    return 0


def cmd_tray(args) -> int:
    """Launch the system-tray app. Service auto-spawns inside the tray."""
    from jc_client import tray

    tray.run()
    return 0


def cmd_voice_popup(args) -> int:
    """Open the draggable voice-orb popup window (blocks until closed)."""
    from jc_client.voice_popup import run_voice_popup

    run_voice_popup()
    return 0


def cmd_tui(args) -> int:
    """Launch the full terminal UI locally, attached to the paired server."""
    from jc_client.tui_launcher import run_tui

    return run_tui()


def cmd_mcp_serve(args) -> int:
    from jc_client.mcp_server import main as serve
    serve()
    return 0


def cmd_code_memory(args) -> int:
    import json as _json
    import os as _os
    from jc_client import code_memory_client as cmc
    try:
        if args.cm_command == "projects":
            print(_json.dumps(cmc.projects(), indent=2))
        elif args.cm_command == "recall":
            slug = args.project or cmc.current_slug()
            for r in cmc.recall(slug, args.kind, limit=args.limit):
                print(f"[{r.get('ts','')}] [{r.get('entry_type','')}] {r.get('content','')}")
        elif args.cm_command == "store":
            slug = args.project or cmc.current_slug()
            cmc.store(slug, args.kind, args.entry_type, args.content)
            print("stored")
        elif args.cm_command == "bootstrap":
            slug = cmc.current_slug()
            cmc.register(slug, _os.path.basename(_os.getcwd()), _os.getcwd(), "")
            print(f"# JarvisCopilot code-memory for `{slug}`\n")
            sess = cmc.recall(slug, "sessions", limit=3)
            if sess:
                print("## Recent session handoff")
                for r in sess:
                    print(f"- {r.get('content','')}")
            know = cmc.recall(slug, "knowledge", limit=20)
            if know:
                print("\n## Known project knowledge")
                for r in know:
                    print(f"- [{r.get('entry_type','')}] {r.get('content','')}")
    except cmc.NotPaired as e:
        print(f"(jarvisclaw-code-assist: {e})")
    return 0


def cmd_update(args) -> int:
    """Pull the latest client code and reinstall — same as re-running the installer.

    The client runs from an editable git checkout (the installer's `src` clone),
    which is an auto-managed mirror of origin. We hard-sync it to origin/<branch>
    so local drift never blocks the update (the old `git pull --ff-only` aborted
    with "local changes would be overwritten"), then refresh the editable install.
    """
    # cli.py lives at <src>/desktop_client/jc_client/cli.py → repo root is parents[2].
    repo = Path(__file__).resolve().parents[2]
    if not (repo / ".git").exists():
        print(f"update: {repo} is not a git checkout — re-run the installer instead.",
              file=sys.stderr)
        return 1
    branch = getattr(args, "branch", None) or "main"

    def _git(*cargs) -> int:
        return subprocess.run(["git", "-C", str(repo), *cargs]).returncode

    print(f"Syncing {repo} to origin/{branch} …")
    if _git("fetch", "--quiet", "origin", branch) != 0:
        print("update: git fetch failed (no network / bad remote?)", file=sys.stderr)
        return 1
    # Discard local drift, then point the branch at origin. reset --hard (no
    # ref) cleans the working tree first so the checkout can't be blocked.
    if _git("reset", "--hard", "--quiet") != 0 or \
            _git("checkout", "-q", "-B", branch, f"origin/{branch}") != 0:
        print("update: git sync failed", file=sys.stderr)
        return 1

    print("Refreshing the editable install …")
    subprocess.run(
        [sys.executable, "-m", "pip", "install", "-e", str(repo / "desktop_client"),
         "-q", "--disable-pip-version-check"],
    )
    print("Updated. Restart to apply: quit + relaunch the tray for the new menu,"
          " and `jc-client restart` for the background service.")
    return 0


# ── Main ───────────────────────────────────────────────────────────────────


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="jc-client", description="JarvisCopilot desktop client")
    p.add_argument("-v", "--verbose", action="store_true", help="Debug logging to stderr")
    sub = p.add_subparsers(dest="cmd", required=True)

    pp = sub.add_parser("pair", help="Pair with a JarvisCopilot server")
    pp.add_argument("--server", help="https://host:port — skip the dialog when paired with --code")
    pp.add_argument("--code", help="6-char pairing code (XXX-XXX)")
    pp.add_argument("--name", help="Override device name (default: hostname)")
    pp.set_defaults(func=cmd_pair)

    start = sub.add_parser(
        "start",
        help="Run the service (and open the menubar tray unless --no-tray)",
    )
    start.add_argument(
        "--no-tray",
        action="store_true",
        help="Headless: run only the service, no menubar icon "
             "(used by the LaunchAgent / systemd unit)",
    )
    start.set_defaults(func=cmd_start)

    sub.add_parser("stop", help="Stop the running daemon").set_defaults(func=cmd_stop)
    sub.add_parser("restart", help="Stop then re-spawn").set_defaults(func=cmd_restart)
    sub.add_parser("status", help="Show paired server + connection state").set_defaults(func=cmd_status)

    logs = sub.add_parser("logs", help="Show client logs")
    logs.add_argument("--follow", "-f", action="store_true", help="Tail-follow")
    logs.set_defaults(func=cmd_logs)

    sk = sub.add_parser("skills", help="Manage which skills are advertised")
    sk_sub = sk.add_subparsers(dest="skills_command", required=True)
    sk_sub.add_parser("list", help="List skills and their state")
    d = sk_sub.add_parser("disable", help="Hide a skill from the server")
    d.add_argument("skill_name")
    e = sk_sub.add_parser("enable", help="Re-enable a previously-disabled skill")
    e.add_argument("skill_name")
    sk.set_defaults(func=cmd_skills)

    cfg = sub.add_parser("config", help="Read/write local config keys")
    cfg_sub = cfg.add_subparsers(dest="config_command", required=True)
    g = cfg_sub.add_parser("get", help="Print one or all config values")
    g.add_argument("key", nargs="?")
    s = cfg_sub.add_parser("set", help="Set a config value")
    s.add_argument("key")
    s.add_argument("value")
    cfg.set_defaults(func=cmd_config)

    sub.add_parser("tray", help="Launch the system tray app").set_defaults(func=cmd_tray)

    sub.add_parser(
        "voice-popup",
        help="Open the draggable voice-orb popup window",
    ).set_defaults(func=cmd_voice_popup)

    sub.add_parser(
        "tui",
        help="Launch the full terminal UI (attached to the paired server)",
    ).set_defaults(func=cmd_tui)

    sub.add_parser("mcp-serve", help="Run the jarvisclaw-code-assist MCP server (stdio)").set_defaults(func=cmd_mcp_serve)
    cmsub = sub.add_parser("code-memory", help="Project code-memory (bootstrap/recall/store/projects)")
    cmsubp = cmsub.add_subparsers(dest="cm_command", required=True)
    cmsubp.add_parser("bootstrap")
    cmsubp.add_parser("projects")
    _r = cmsubp.add_parser("recall"); _r.add_argument("--project", default=""); _r.add_argument("--kind", default="knowledge"); _r.add_argument("--limit", type=int, default=20)
    _s = cmsubp.add_parser("store"); _s.add_argument("--project", default=""); _s.add_argument("--kind", default="knowledge"); _s.add_argument("--entry-type", dest="entry_type", default="note"); _s.add_argument("--content", required=True)
    cmsub.set_defaults(func=cmd_code_memory)

    upd = sub.add_parser("update", help="Pull the latest client code and reinstall")
    upd.add_argument("--branch", default=None,
                     help="Git branch to sync to (default: main)")
    upd.set_defaults(func=cmd_update)

    up = sub.add_parser("unpair", help="Wipe saved credentials")
    up.add_argument("--yes", action="store_true", help="Skip confirmation")
    up.set_defaults(func=cmd_unpair)

    return p


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    setup_logging(level="DEBUG" if args.verbose else "INFO", verbose=args.verbose)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
