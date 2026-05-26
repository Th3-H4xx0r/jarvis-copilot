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

    def _act_quit(self, icon, _item) -> None:
        self._stop.set()
        # Only stop our own service handle. The supervised process keeps
        # running — that's the whole point of LaunchAgent/systemd.
        self._stop_service()
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

        def _pause_label(_item):
            return "Resume" if (self._svc and self._svc.is_paused) else "Pause"

        def _pause_visible(_item):
            # Hide pause/resume when we don't own the service — there's
            # no way to signal the supervised process to pause from here.
            return self._svc is not None

        return Menu(
            MenuItem(_status_text, None, enabled=False),
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
            # Supervised mode — derive state from PID + log tail.
            state = _supervised_state(self._supervised_pid)
            if state == "connected":
                color = (66, 160, 90, 255)  # green
            elif state == "reconnecting":
                color = (224, 85, 43, 255)  # red
            else:
                color = (90, 90, 90, 255)  # grey (stopped / unknown)
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

    def _refresh_loop(self) -> None:
        while not self._stop.is_set():
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


def _format_supervised_status_line(pid: Optional[int]) -> str:
    creds = credentials.load()
    if not creds.paired:
        return "● Not paired"
    if not pid or not _pid_alive(pid):
        return "● Service not running"
    state = _supervised_state(pid)
    if state == "connected":
        return f"● Connected to {creds.server_url}"
    if state == "reconnecting":
        return f"● Reconnecting to {creds.server_url}…"
    return f"● Supervised (pid {pid})"


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False


def _supervised_state(pid: Optional[int]) -> str:
    """Derive the supervised service's state by tailing the log file.
    Returns 'connected', 'reconnecting', or 'unknown'. Cheap — reads
    the last ~4 KB of the log."""
    if not pid or not _pid_alive(pid):
        return "stopped"
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
