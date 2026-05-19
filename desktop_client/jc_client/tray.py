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
from jc_client.logger import log_path, setup as setup_logging

log = logging.getLogger(__name__)


_STATE_REFRESH_SEC = 2.0


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

    # ── Service lifecycle ────────────────────────────────────────────

    def _start_service(self) -> None:
        if self._svc_thread and self._svc_thread.is_alive():
            return
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

    def _act_view_logs(self, _icon, _item) -> None:
        path = log_path()
        if sys.platform == "darwin":
            subprocess.Popen(["open", str(path)])
        elif sys.platform == "win32":
            os.startfile(str(path))  # type: ignore[attr-defined]
        else:
            subprocess.Popen(["xdg-open", str(path)])

    def _act_restart(self, _icon, _item) -> None:
        self._stop_service()
        self._start_service()

    def _act_pause(self, _icon, _item) -> None:
        if self._svc:
            if self._svc.is_paused:
                self._svc.resume()
            else:
                self._svc.pause()
            self._refresh_menu()

    def _act_quit(self, icon, _item) -> None:
        self._stop.set()
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
            return _format_status_line(self._svc)

        def _pause_label(_item):
            return "Resume" if (self._svc and self._svc.is_paused) else "Pause"

        return Menu(
            MenuItem(_status_text, None, enabled=False),
            Sep,
            MenuItem("Open dashboard", self._act_open_dashboard),
            MenuItem("Re-pair…", self._act_repair),
            MenuItem("View logs", self._act_view_logs),
            MenuItem("Restart", self._act_restart),
            MenuItem(_pause_label, self._act_pause),
            Sep,
            MenuItem("Quit", self._act_quit),
        )

    def _icon_for_state(self):
        if not self._svc:
            color = (90, 90, 90, 255)
        elif self._svc.is_paused:
            color = (240, 179, 65, 255)  # amber
        elif self._svc.is_connected:
            color = (66, 160, 90, 255)  # green
        else:
            color = (224, 85, 43, 255)  # red
        img = _icon_image(color)
        return img

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


def run() -> int:
    try:
        app = TrayApp()
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    app.run()
    return 0
