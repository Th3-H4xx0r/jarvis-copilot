"""Who is allowed to touch the menubar item.

macOS 27 backs the status item with an ``NSSceneStatusItem``, so
``-[NSStatusItem setMenu:]`` now goes through FrontBoardServices and calls
``-[BSServiceMainRunLoopQueue assertBarrierOnQueue]`` — a hard SIGTRAP when the
caller is not on the main run loop. The tray's ``tray-refresh`` thread had
always mutated the item directly, which earlier releases tolerated; on 27 the
first tick killed jc-client about two seconds after every launch.

These tests pin the marshalling that keeps it alive: the refresh thread may
compute whatever it likes, but the AppKit half has to land on the main thread.
"""
from __future__ import annotations

import subprocess
import sys
import threading
from pathlib import Path

import pytest

from jc_client.tray import TrayApp


class _RecordingIcon:
    """Stands in for pystray's Icon, remembering which thread touched it."""

    def __init__(self) -> None:
        self.touches: list[threading.Thread] = []
        self._icon = None

    @property
    def icon(self):
        return self._icon

    @icon.setter
    def icon(self, value) -> None:
        self._icon = value
        self.touches.append(threading.current_thread())

    def update_menu(self) -> None:
        self.touches.append(threading.current_thread())


def _tray_with(icon) -> TrayApp:
    app = TrayApp.__new__(TrayApp)
    app._icon = icon
    # The picture is not what these tests pin, and building the real one drags
    # in the service-state lookups.
    app._icon_for_state = lambda: "image"
    return app


def test_a_refresh_on_the_main_thread_still_applies_immediately():
    """Startup refreshes run on the main thread and must not be deferred —
    ``run()`` relabels the menu between building the icon and entering the
    loop, and a deferred call would land after the user already saw it."""
    icon = _RecordingIcon()
    _tray_with(icon)._refresh_menu()
    assert len(icon.touches) == 2, "expected the image and the menu to be set"
    assert all(t is threading.current_thread() for t in icon.touches)


@pytest.mark.skipif(sys.platform != "darwin", reason="AppKit threading rule")
def test_a_refresh_from_the_worker_thread_touches_nothing_on_that_thread():
    """The whole bug in one assertion: on macOS the refresh thread must hand
    the status item off, not touch it. There is no run loop here, so the
    handed-off work stays queued — which is exactly what proves it was
    handed off rather than run in place."""
    pytest.importorskip("PyObjCTools")
    icon = _RecordingIcon()
    app = _tray_with(icon)

    worker = threading.Thread(target=app._refresh_menu, name="tray-refresh")
    worker.start()
    worker.join(5)

    assert icon.touches == [], "the refresh thread touched AppKit directly"


# The child process that test_the_status_item_survives... runs. It drives the
# real TrayApp._refresh_menu against a real NSStatusItem, which is the only way
# to exercise the assert that actually kills the app.
_CHILD = '''
import threading, sys
import AppKit
from PIL import Image
import pystray
from PyObjCTools import AppHelper
from jc_client.tray import TrayApp

AppKit.NSApplication.sharedApplication()
AppKit.NSApp.setActivationPolicy_(1)  # accessory: no Dock tile for the test

icon = pystray.Icon(
    "jc-refresh-test",
    Image.new("RGBA", (18, 18), (0, 0, 0, 0)),
    menu=pystray.Menu(pystray.MenuItem("row", None, enabled=False)),
)
icon.visible = True          # creates the button, on the main thread
icon._menu_handle = None     # so a re-attach below is visible

app = TrayApp.__new__(TrayApp)
app._icon = icon
app._icon_for_state = lambda: Image.new("RGBA", (18, 18), (1, 2, 3, 255))

def report():
    # Report from ON the main loop: stopEventLoop() terminates the app, so
    # nothing placed after runEventLoop() ever executes.
    print("APPLIED" if icon._menu_handle is not None else "NOT-APPLIED", flush=True)
    AppHelper.stopEventLoop()

threading.Thread(target=app._refresh_menu, name="tray-refresh").start()
AppHelper.callLater(2.0, report)
AppHelper.runEventLoop()
'''


@pytest.mark.skipif(sys.platform != "darwin", reason="AppKit threading rule")
def test_the_status_item_survives_a_refresh_from_a_background_thread():
    """The regression itself, against a real status item in a child process.

    Before the fix this child dies with SIGTRAP (returncode -5) inside
    ``-[BSServiceMainRunLoopQueue assertBarrierOnQueue]``. A clean exit means
    the refresh reached AppKit on the main run loop — and ``APPLIED`` means it
    actually ran rather than being quietly dropped.
    """
    for module in ("AppKit", "PyObjCTools", "pystray", "PIL"):
        pytest.importorskip(module)

    package_parent = Path(__file__).resolve().parent.parent
    proc = subprocess.run(
        [sys.executable, "-c", _CHILD],
        cwd=package_parent, capture_output=True, text=True, timeout=60,
    )
    assert proc.returncode == 0, (
        f"the status item refused the refresh: rc={proc.returncode}\n"
        f"{proc.stdout}\n{proc.stderr}"
    )
    assert "APPLIED" in proc.stdout, proc.stdout
