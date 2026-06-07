"""System tray (Win + macOS menubar + Linux AppIndicator) for the client.

Run via ``jc-client tray``. Spawns the service in a background thread,
keeps a tray icon up with status + a small menu:

    🟢 Connected to vps.example.com
    ─────────────
    Open dashboard
    Re-pair…
    View logs
    Restart
    Pause / Resume
    Quit

Falls back gracefully when pystray isn't installed or the desktop
environment has no system-tray support — logs the situation and exits
with a clear error.
"""
from __future__ import annotations

import json
import logging
import os
import subprocess
import sys
import threading
import time
import webbrowser
from typing import Optional

from jc_client import credentials, service
from jc_client.logger import log_path, setup as setup_logging, state_dir

log = logging.getLogger(__name__)


_STATE_REFRESH_SEC = 2.0

# Cross-process Coding-Session sync indicator. The service process (which may be
# a SEPARATE launchd-supervised process) writes this file via CodingSyncAgent;
# the tray polls it. Keep these in sync with coding_sync_agent.py.
_SYNC_STATE_FILENAME = "sync_state.json"
_SYNC_WINDOW_SEC = 2.5


def _read_sync_state() -> tuple[float, int, int, int]:
    """Read ``sync_state.json`` written by the service's CodingSyncAgent.

    Returns ``(last_transfer_at, active, done, total)``; ``(0.0, 0, 0, 0)`` if
    the file is missing or unreadable. This is the cross-process channel: on
    macOS the headless service and the tray are different processes, so
    in-memory ``active_count`` isn't visible here — the file is. ``done``/
    ``total`` are the server-pushed aggregate transfer progress (drive the %).
    """
    path = state_dir() / _SYNC_STATE_FILENAME
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return (
            float(data.get("last_transfer_at") or 0.0),
            int(data.get("active") or 0),
            int(data.get("done") or 0),
            int(data.get("total") or 0),
        )
    except (OSError, ValueError, TypeError):
        return 0.0, 0, 0, 0


def _notify_syncing() -> None:
    """Send one desktop notification that a sync has started. Best-effort.

    Reuses the same osascript/notify-send/PowerShell backends the client's
    ``notify`` skill uses, but inline (no skill-registry dependency) so the
    tray process can fire it directly. Never raises.
    """
    title, message = "JarvisCopilot", "Syncing changes…"
    try:
        if sys.platform == "darwin":
            script = f'display notification "{message}" with title "{title}"'
            subprocess.run(["osascript", "-e", script], check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        elif sys.platform == "win32":
            ps = (
                '$ErrorActionPreference = "SilentlyContinue"; '
                '[void][Windows.UI.Notifications.ToastNotificationManager, '
                'Windows.UI.Notifications, ContentType=WindowsRuntime]; '
                '$T="<toast><visual><binding template=\\"ToastGeneric\\">'
                f'<text>{title}</text><text>{message}</text>'
                '</binding></visual></toast>"; '
                '$x = New-Object Windows.Data.Xml.Dom.XmlDocument; $x.LoadXml($T); '
                '$n = New-Object Windows.UI.Notifications.ToastNotification($x); '
                '[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('
                '"JarvisCopilot").Show($n)'
            )
            subprocess.run(["powershell", "-NoProfile", "-Command", ps],
                           check=False, capture_output=True)
        else:
            import shutil
            if shutil.which("notify-send"):
                subprocess.run(["notify-send", title, message], check=False)
    except Exception as exc:  # noqa: BLE001 — a missing notifier must not crash the tray
        log.debug("syncing notification failed: %s", exc)


def _read_service_pid() -> Optional[int]:
    """Return the PID of a running ``jc-client start`` process, or None.
    Reads the PID file that ``cmd_start`` writes and verifies the
    process is still alive."""
    pid_file = state_dir() / "jc-client.pid"
    try:
        raw = pid_file.read_text().strip()
        pid = int(raw)
    except (FileNotFoundError, ValueError):
        return None
    try:
        os.kill(pid, 0)
        return pid
    except (OSError, ProcessLookupError):
        return None


def _icon_image(color: tuple[int, int, int]):
    """Render a 64x64 PNG of a coloured disc with 'JC' on it.
    Stubs to a coloured square if Pillow is missing."""
    try:
        from PIL import Image, ImageDraw, ImageFont  # type: ignore
    except Exception:
        return None
    img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.ellipse((2, 2, 62, 62), fill=color, outline=(0, 0, 0, 160), width=1)
    try:
        font = ImageFont.truetype("arial.ttf", 28)
    except Exception:
        try:
            font = ImageFont.load_default()
        except Exception:
            font = None
    if font is not None:
        draw.text((19, 14), "JC", fill=(255, 255, 255, 255), font=font)
    return img


# ── Tray app ───────────────────────────────────────────────────────────────


class TrayApp:
    def __init__(self) -> None:
        # pystray and PIL are lazy-imported so plain CLI use doesn't
        # need them.
        try:
            import pystray  # type: ignore
        except Exception as exc:
            raise RuntimeError(
                "tray requires `pystray` (pip install pystray pillow)"
            ) from exc
        self._pystray = pystray
        self._icon = None
        self._svc: service.Service | None = None
        self._svc_thread: threading.Thread | None = None
        self._stop = threading.Event()
        # When supervised by launchctl/systemd, _svc is None but a
        # service is alive in another process; we read status from its
        # PID file + log tail.
        self._supervised_pid: int | None = None
        # The voice-orb popup runs as a separate process (pywebview can't share
        # the macOS main run loop with pystray); track it so the menu item can
        # toggle it open/closed.
        self._voice_proc: subprocess.Popen | None = None
        # Cross-process Coding-Session sync indicator: the latest "syncing?"
        # value, refreshed each tick from sync_state.json. ``_prev_syncing``
        # holds the previous tick's value so we fire ONE notification on the
        # idle→syncing transition (not on every tick while it stays true).
        self._syncing: bool = False
        self._prev_syncing: bool = False
        # Aggregate transfer progress (server-pushed via sync_state.json), used
        # to append a percentage to the "Syncing changes…" label.
        self._sync_done: int = 0
        self._sync_total: int = 0

    # ── Service lifecycle ────────────────────────────────────────────

    def _start_service(self) -> None:
        if self._svc_thread and self._svc_thread.is_alive():
            return
        # If another process is already running the service (typically the
        # LaunchAgent / systemd unit), don't spawn a second one — the
        # server allows only one bridge per device_id, so two services
        # would kick each other out of `_REG` in a 1Hz reconnect storm.
        # The tray runs in UI-only mode in that case.
        running_pid = _read_service_pid()
        if running_pid and running_pid != os.getpid():
            log.info(
                "tray: service already running (pid %d) — running UI only",
                running_pid,
            )
            self._svc = None
            self._svc_thread = None
            self._supervised_pid = running_pid
            return
        self._supervised_pid = None

        self._svc = service.Service()
        # Make the active handle reachable from the tray.
        service.ACTIVE = self._svc

        def _runner():
            try:
                self._svc.run()
            finally:
                if service.ACTIVE is self._svc:
                    service.ACTIVE = None

        self._svc_thread = threading.Thread(
            target=_runner, daemon=True, name="jc-client-service"
        )
        self._svc_thread.start()

    def _stop_service(self) -> None:
        if self._svc:
            self._svc.stop()
        if self._svc_thread:
            self._svc_thread.join(timeout=5)
        self._svc = None
        self._svc_thread = None

    # ── Menu actions ─────────────────────────────────────────────────

    def _act_open_dashboard(self, _icon, _item) -> None:
        url = credentials.load().server_url
        if url:
            webbrowser.open(url, new=2)

    def _act_repair(self, _icon, _item) -> None:
        # The Tk dialog has to run on the main thread on macOS, so we
        # spawn a separate Python process for it. Cleaner than juggling
        # threads.
        py = sys.executable
        subprocess.Popen(
            [py, "-m", "jc_client", "pair"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
        )

    def _act_voice_orb(self, _icon, _item) -> None:
        # Toggle the popup: if one is already open, close it; otherwise spawn a
        # fresh `jc-client voice-popup` process. Spawned separately because
        # pywebview needs the main run loop, which pystray already owns.
        proc = self._voice_proc
        if proc is not None and proc.poll() is None:
            try:
                proc.terminate()
            except Exception:
                pass
            self._voice_proc = None
            return
        py = sys.executable
        self._voice_proc = subprocess.Popen(
            [py, "-m", "jc_client", "voice-popup"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
        )

    def _act_view_logs(self, _icon, _item) -> None:
        path = log_path()
        if sys.platform == "darwin":
            subprocess.Popen(["open", str(path)])
        elif sys.platform == "win32":
            os.startfile(str(path))  # type: ignore[attr-defined]
        else:
            subprocess.Popen(["xdg-open", str(path)])

    def _act_restart(self, _icon, _item) -> None:
        if self._supervised_pid:
            # Restart via the supervisor so we don't fight it.
            py = sys.executable
            subprocess.Popen(
                [py, "-m", "jc_client", "restart"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                stdin=subprocess.DEVNULL,
                start_new_session=True,
                close_fds=True,
            )
            return
        self._stop_service()
        self._start_service()

    def _act_pause(self, _icon, _item) -> None:
        if self._svc:
            if self._svc.is_paused:
                self._svc.resume()
            else:
                self._svc.pause()
            self._refresh_menu()
        # In supervised mode there's no IPC to pause the other process;
        # menu item is hidden via _pause_visible.

    def _stop_supervised_service(self) -> None:
        """Stop the SUPERVISED/background service the same way ``jc-client
        stop`` does — drive the supervisor if one's loaded, else kill the
        PID-file process.

        This is what makes "Quit" actually quit: on macOS the LaunchAgent
        (KeepAlive=true) would instantly respawn a merely-killed service, so
        we must ``launchctl unload`` it. We reuse cli.py's per-OS helpers
        rather than re-encoding any launchctl/systemd/kill strings here, so
        the two stop paths can't drift. Best-effort and bounded: each step is
        wrapped, and the supervisor calls run in a daemon thread we join with
        a short timeout so a hung ``launchctl`` can never freeze the quit.
        """
        from jc_client import cli

        def _do_supervisor_stop() -> None:
            # Same branch cmd_stop takes: unload the supervisor if it's the
            # one keeping the service alive. _supervisor_unload() already
            # branches per-OS (launchctl unload on mac, systemctl --user stop
            # on linux) and no-ops when no supervisor is installed (Windows).
            try:
                if cli._supervisor_kind() and cli._supervisor_is_loaded():
                    cli._supervisor_unload()
            except Exception as exc:  # noqa: BLE001 — quit must never hang/raise
                log.debug("supervisor unload failed: %s", exc)

        # launchctl/systemctl can occasionally block; never let it freeze the
        # UI thread. Join with a short timeout, then move on regardless.
        t = threading.Thread(target=_do_supervisor_stop, daemon=True)
        t.start()
        t.join(timeout=4.0)

        # Also kill any PID-file service process directly. On Windows there's
        # no supervisor (the tray owns the service in-process), but a manually
        # launched `jc-client start --no-tray` would still leave a PID file;
        # on mac/linux this reaps a service that unload left running. Mirrors
        # cmd_stop's PID-file fallback. Guarded so a stale/dead PID is a no-op.
        try:
            pid = cli._read_pid()
            if pid and pid != os.getpid() and cli._is_running(pid):
                import signal as _signal
                os.kill(pid, _signal.SIGTERM)
                # Brief, bounded wait for it to exit before we drop the file.
                for _ in range(20):
                    if not cli._is_running(pid):
                        break
                    time.sleep(0.1)
            try:
                cli.PID_FILE.unlink()
            except FileNotFoundError:
                pass
        except Exception as exc:  # noqa: BLE001 — best-effort cleanup
            log.debug("pid-file stop failed: %s", exc)

    def _act_quit(self, icon, _item) -> None:
        self._stop.set()
        # 1. Stop our own in-process service handle if we own one (Windows /
        #    no-supervisor case). No-op when supervised (_svc is None).
        self._stop_service()
        # 2. ALWAYS stop the SUPERVISED/background service too, so the
        #    LaunchAgent/systemd service is actually stopped and KeepAlive
        #    can't restart it. Reuses cli.py's stop logic (per-OS) and is
        #    bounded so it can't hang the quit. NOTE: on macOS this UNLOADS
        #    the LaunchAgent for this login session (the only way to defeat
        #    KeepAlive) — it does not permanently disable autostart, so the
        #    agent loads again on next login/reboot. Re-run `jc-client start`
        #    to bring it back within the same session.
        try:
            self._stop_supervised_service()
        except Exception as exc:  # noqa: BLE001 — never block quit
            log.debug("supervised stop failed: %s", exc)
        # 3. Finally stop the tray icon so the menubar item disappears.
        try:
            icon.stop()
        except Exception:
            pass

    # ── UI ────────────────────────────────────────────────────────────

    def _build_menu(self):
        pystray = self._pystray
        Menu = pystray.Menu
        MenuItem = pystray.MenuItem
        Sep = pystray.Menu.SEPARATOR

        def _status_text(_item):
            if self._svc is not None:
                return _format_status_line(self._svc)
            return _format_supervised_status_line(self._supervised_pid)

        def _sync_text(_item):
            # Only meaningful when we own the service (in-process read). In
            # supervised mode there's no IPC to the other process, so the item
            # is hidden (mirrors the pause/resume supervised fallback).
            return _format_sync_line(self._svc)

        def _sync_visible(_item):
            # In-process: always show. Supervised (no _svc): show only when the
            # state file reports active syncs, so the line stays useful without
            # IPC but doesn't clutter the menu when idle.
            if self._svc is not None:
                return True
            try:
                return _read_sync_state()[1] > 0
            except Exception:
                return False

        def _syncing_visible(_item):
            # Shown ONLY while a transfer happened recently (cross-process read,
            # so it works even when the service is in a separate process).
            return self._syncing

        def _syncing_label(_item):
            # "⟳ Syncing changes… N%" when the server has pushed progress
            # (total>0); just "⟳ Syncing changes…" when the total is unknown.
            base = "⟳ Syncing changes…"
            total = self._sync_total
            if total > 0:
                pct = round(self._sync_done / total * 100)
                # Clamp into [0, 100] in case done briefly overshoots/lags total.
                pct = max(0, min(100, pct))
                return f"{base} {pct}%"
            return base

        def _pause_label(_item):
            return "Resume" if (self._svc and self._svc.is_paused) else "Pause"

        def _pause_visible(_item):
            # Hide pause/resume when we don't own the service — there's
            # no way to signal the supervised process to pause from here.
            return self._svc is not None

        return Menu(
            MenuItem(_status_text, None, enabled=False),
            MenuItem(_sync_text, None, enabled=False, visible=_sync_visible),
            # Greyed-out indicator that appears only while files are syncing.
            # Cross-process (state file), so it shows even when supervised. The
            # label appends a percentage when the server has pushed progress.
            MenuItem(_syncing_label, None, enabled=False,
                     visible=_syncing_visible),
            Sep,
            MenuItem("Open dashboard", self._act_open_dashboard),
            MenuItem("Voice Orb", self._act_voice_orb),
            MenuItem("Re-pair…", self._act_repair),
            MenuItem("View logs", self._act_view_logs),
            MenuItem("Restart", self._act_restart),
            MenuItem(_pause_label, self._act_pause, visible=_pause_visible),
            Sep,
            MenuItem("Quit", self._act_quit),
        )

    def _icon_for_state(self):
        if self._svc is not None:
            if self._svc.is_paused:
                color = (240, 179, 65, 255)  # amber
            elif self._svc.is_connected:
                color = (66, 160, 90, 255)  # green
            else:
                color = (224, 85, 43, 255)  # red
        else:
            # Supervised mode — the service writes its real state to a file we
            # read. Always green (connected) or red (anything else: reconnecting,
            # stopped, or briefly-unknown-at-startup) — never a grey "supervised"
            # limbo, which confused users into thinking it was broken.
            state = _supervised_state(self._supervised_pid)
            color = ((66, 160, 90, 255) if state == "connected"
                     else (224, 85, 43, 255))  # green | red
        return _icon_image(color)

    def _refresh_menu(self) -> None:
        # pystray updates the title + menu by calling update_menu on the
        # icon object. The label callbacks re-evaluate, so a single
        # call refreshes everything.
        if self._icon:
            self._icon.icon = self._icon_for_state()
            try:
                self._icon.update_menu()
            except Exception:
                pass

    def _poll_sync_state(self) -> None:
        """Refresh the cross-process "syncing" flag and fire the one-shot
        notification on an idle→syncing transition.

        Reads ``sync_state.json`` (written by the service's CodingSyncAgent in
        whatever process it lives) and compares the last transfer time against
        the window. Fires exactly one desktop notification when we cross from
        not-syncing to syncing — never on subsequent ticks while it stays true.
        """
        last_transfer_at, _active, done, total = _read_sync_state()
        now = time.time()
        syncing = last_transfer_at > 0.0 and (now - last_transfer_at) < _SYNC_WINDOW_SEC
        if syncing and not self._prev_syncing:
            _notify_syncing()
        self._prev_syncing = syncing
        self._syncing = syncing
        self._sync_done = done
        self._sync_total = total

    def _refresh_loop(self) -> None:
        while not self._stop.is_set():
            self._poll_sync_state()
            self._refresh_menu()
            if self._stop.wait(_STATE_REFRESH_SEC):
                break

    # ── Entry ─────────────────────────────────────────────────────────

    def run(self) -> None:
        setup_logging(level="INFO")
        creds = credentials.load()
        if not creds.paired:
            # Block until the user pairs — they'll do this through the
            # menu's re-pair action, but launching directly into the
            # dialog is friendlier for first-run.
            self._act_repair(None, None)

        self._start_service()
        # Background thread to update icon color + menu labels.
        threading.Thread(target=self._refresh_loop, daemon=True, name="tray-refresh").start()

        icon = self._pystray.Icon(
            "jc-client",
            self._icon_for_state(),
            title="JarvisCopilot client",
            menu=self._build_menu(),
        )
        self._icon = icon
        try:
            icon.run()  # blocks
        finally:
            self._stop.set()
            self._stop_service()


def _format_status_line(svc: Optional[service.Service]) -> str:
    creds = credentials.load()
    if not creds.paired:
        return "● Not paired"
    if not svc:
        return "● Stopped"
    if svc.is_paused:
        return f"● Paused ({creds.server_url})"
    if svc.is_connected:
        return f"● Connected to {creds.server_url}"
    return f"● Reconnecting to {creds.server_url}…"


def _format_sync_line(svc: Optional[service.Service]) -> str:
    """"Sync: N active" / "Sync: idle" for the Coding-Session file sync.

    When we own the service, reads its in-process CodingSyncAgent count. In
    supervised mode (``svc is None``) there's no IPC, so we fall back to the
    cross-process state file's ``active`` field. Best-effort: any error (no
    agent yet, mid-reconnect) renders as idle rather than crashing the menu."""
    n = 0
    if svc is not None:
        try:
            n = svc.coding_sync_active_count()
        except Exception:
            n = 0
    else:
        try:
            n = _read_sync_state()[1]
        except Exception:
            n = 0
    if n <= 0:
        return "Sync: idle"
    return f"Sync: {n} active"


def _format_supervised_status_line(pid: Optional[int]) -> str:
    creds = credentials.load()
    if not creds.paired:
        return "● Not paired"
    if not pid or not _pid_alive(pid):
        return "● Service not running"
    state = _supervised_state(pid)
    if state == "connected":
        return f"● Connected to {creds.server_url}"
    # Alive but not connected (reconnecting / briefly-unknown at startup): show
    # "Reconnecting", never a grey "Supervised (pid …)" limbo.
    return f"● Reconnecting to {creds.server_url}…"


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False


def _read_connection_state(pid: Optional[int]) -> Optional[str]:
    """The supervised service's persisted connection state, iff it was written
    by the CURRENTLY-running service (pid match). Returns 'connected' /
    'reconnecting' / 'stopped', or None if missing / from a stale prior run.

    This is the RELIABLE signal — the service writes it on every transition, so
    a long-lived healthy connection still reads 'connected' (the old log-tail
    heuristic returned 'unknown' → grey 'Supervised' once the recent log filled
    with sync/coding chatter)."""
    import json as _json
    try:
        from jc_client.logger import state_dir
        data = _json.loads((state_dir() / "connection_state.json").read_text())
    except Exception:
        return None
    # Only trust it if it belongs to the service we're actually supervising —
    # otherwise it could be a leftover from a previous (crashed) run.
    if pid and int(data.get("pid") or 0) != int(pid):
        return None
    state = str(data.get("state") or "")
    return state if state in ("connected", "reconnecting", "stopped") else None


def _supervised_state(pid: Optional[int]) -> str:
    """The supervised service's state: 'connected', 'reconnecting', 'stopped',
    or 'unknown'. Prefers the state file the service writes; falls back to a log
    tail for older service builds that don't write it."""
    if not pid or not _pid_alive(pid):
        return "stopped"
    st = _read_connection_state(pid)
    if st:
        return st
    path = log_path()
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            f.seek(max(0, size - 4096))
            tail = f.read().decode("utf-8", errors="replace")
    except OSError:
        return "unknown"
    last_state = "unknown"
    for line in tail.splitlines():
        if "connected to" in line:
            last_state = "connected"
        elif "reconnecting in" in line:
            last_state = "reconnecting"
    return last_state


def run() -> int:
    try:
        app = TrayApp()
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    app.run()
    # If icon.run() returned (icon couldn't show, e.g. no UI context under
    # a LaunchAgent), exit non-zero so KeepAlive restarts us. Otherwise
    # we'd silently drop the service.
    return 3
