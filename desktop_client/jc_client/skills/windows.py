"""Windows-specific skills.

PowerShell + a small touch of ctypes / win32 APIs for window enumeration.
We deliberately keep dependencies minimal (no pywin32 hard-require) so
the client installs cleanly on a vanilla Python.
"""
from __future__ import annotations

import ctypes
import ctypes.wintypes as wt
import logging
import subprocess

from jc_client.skills import skill

log = logging.getLogger(__name__)


def _ps(script: str, *, timeout: float = 15.0) -> str:
    """Run a PowerShell snippet, return stdout stripped of trailing newline."""
    res = subprocess.run(
        ["powershell", "-NoProfile", "-NonInteractive", "-Command", script],
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    if res.returncode != 0 and res.stderr.strip():
        raise RuntimeError(res.stderr.strip()[:500])
    return (res.stdout or "").rstrip("\r\n")


# ── App control ────────────────────────────────────────────────────────────


@skill(
    "open_app",
    "Launch an application by name or path. Common names supported via "
    "the Win32 shell verb: 'chrome', 'edge', 'firefox', 'code', "
    "'notepad', 'explorer', 'cmd', 'powershell'.",
    {
        "type": "object",
        "properties": {"name": {"type": "string"}},
        "required": ["name"],
    },
    destructive=True,
)
def open_app(name: str) -> dict:
    if not name:
        raise ValueError("name required")
    # `Start-Process` with no path goes through the App Paths registry,
    # so 'chrome' / 'code' / 'notepad' work without us hard-coding paths.
    safe = name.replace("'", "''")
    _ps(f"Start-Process -FilePath '{safe}'")
    return {"ok": True, "name": name}


@skill(
    "quit_app",
    "Close an application by process name (without .exe).",
    {
        "type": "object",
        "properties": {"name": {"type": "string"}},
        "required": ["name"],
    },
    destructive=True,
)
def quit_app(name: str) -> dict:
    if not name:
        raise ValueError("name required")
    safe = name.replace("'", "''").rstrip(".exe")
    _ps(f"Get-Process -Name '{safe}' -ErrorAction SilentlyContinue | Stop-Process -Force")
    return {"ok": True, "name": name}


# ── Window management via Win32 ────────────────────────────────────────────

_user32 = ctypes.windll.user32  # type: ignore[attr-defined]


def _get_window_title(hwnd: int) -> str:
    length = _user32.GetWindowTextLengthW(hwnd)
    if length == 0:
        return ""
    buf = ctypes.create_unicode_buffer(length + 1)
    _user32.GetWindowTextW(hwnd, buf, length + 1)
    return buf.value


def _get_window_process(hwnd: int) -> str:
    pid = wt.DWORD()
    _user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    try:
        out = _ps(
            f"(Get-Process -Id {int(pid.value)} -ErrorAction SilentlyContinue).ProcessName"
        )
        return out
    except Exception:
        return ""


@skill(
    "current_window",
    "Return the title + process of the currently-focused window.",
    {"type": "object"},
)
def current_window() -> dict:
    hwnd = _user32.GetForegroundWindow()
    return {"app": _get_window_process(hwnd), "title": _get_window_title(hwnd), "hwnd": int(hwnd)}


@skill(
    "list_windows",
    "List visible top-level windows as [{app, title, hwnd}].",
    {"type": "object"},
)
def list_windows() -> dict:
    EnumProc = ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    results: list[int] = []

    def _cb(hwnd, _lparam):
        if _user32.IsWindowVisible(hwnd) and _get_window_title(hwnd):
            results.append(hwnd)
        return True

    _user32.EnumWindows(EnumProc(_cb), 0)
    windows = []
    for h in results:
        title = _get_window_title(h)
        if not title:
            continue
        windows.append(
            {
                "app": _get_window_process(h),
                "title": title,
                "hwnd": int(h),
            }
        )
    return {"windows": windows, "count": len(windows)}


@skill(
    "focus_window",
    "Bring a window matching `title_substring` to the foreground.",
    {
        "type": "object",
        "properties": {"title_substring": {"type": "string"}},
        "required": ["title_substring"],
    },
)
def focus_window(title_substring: str) -> dict:
    sub = (title_substring or "").lower()
    if not sub:
        raise ValueError("title_substring required")
    for w in list_windows()["windows"]:
        if sub in w["title"].lower() or sub in w["app"].lower():
            hwnd = w["hwnd"]
            # SW_RESTORE = 9: restore from minimized.
            _user32.ShowWindow(hwnd, 9)
            _user32.SetForegroundWindow(hwnd)
            return {"ok": True, "matched": w}
    return {"ok": False, "error": f"no window matches {title_substring!r}"}


# ── Lock / volume ──────────────────────────────────────────────────────────


@skill(
    "lock_screen",
    "Lock the screen (show the sign-in screen).",
    {"type": "object"},
    destructive=True,
)
def lock_screen() -> dict:
    ctypes.windll.user32.LockWorkStation()  # type: ignore[attr-defined]
    return {"ok": True}


@skill(
    "volume_get",
    "Return the master output volume as 0-100.",
    {"type": "object"},
)
def volume_get() -> dict:
    # Use the COM API via PowerShell. Faster + zero install vs nirsoft.
    out = _ps(
        "Add-Type -AssemblyName PresentationCore;"
        "$obj = (New-Object -ComObject WScript.Shell);"
        "[audio]::Volume * 100"
    ) if False else _volume_get_ps()
    try:
        return {"level": int(round(float(out)))}
    except Exception:
        return {"level": 0}


def _volume_get_ps() -> str:
    # Use the AudioDeviceCmdlets-free path: query via Windows.Media.Audio
    # through Add-Type. The block below is the canonical "no extra
    # module" Windows volume read.
    return _ps(
        r"""
$src = @'
using System;
using System.Runtime.InteropServices;
[Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioEndpointVolume {
    int f(); int g(); int h(); int i();
    int SetMasterVolumeLevelScalar(float fLevel, Guid pguidEventContext);
    int j(); int GetMasterVolumeLevelScalar(out float pfLevel);
}
[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDevice {
    int Activate(ref Guid id, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object o);
}
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDeviceEnumerator {
    int f(); int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
}
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
public class MMDeviceEnumeratorComObject { }
public class Audio {
    public static float Volume {
        get {
            var enumerator = new MMDeviceEnumeratorComObject() as IMMDeviceEnumerator;
            IMMDevice dev = null; enumerator.GetDefaultAudioEndpoint(0, 1, out dev);
            object o; Guid IID = typeof(IAudioEndpointVolume).GUID;
            dev.Activate(ref IID, 23, IntPtr.Zero, out o);
            var v = (IAudioEndpointVolume)o; float r = 0; v.GetMasterVolumeLevelScalar(out r);
            return r * 100;
        }
        set {
            var enumerator = new MMDeviceEnumeratorComObject() as IMMDeviceEnumerator;
            IMMDevice dev = null; enumerator.GetDefaultAudioEndpoint(0, 1, out dev);
            object o; Guid IID = typeof(IAudioEndpointVolume).GUID;
            dev.Activate(ref IID, 23, IntPtr.Zero, out o);
            var v = (IAudioEndpointVolume)o; v.SetMasterVolumeLevelScalar(value/100, Guid.Empty);
        }
    }
}
'@
Add-Type -TypeDefinition $src -ErrorAction SilentlyContinue
[Audio]::Volume
"""
    )


@skill(
    "volume_set",
    "Set the master output volume (0-100).",
    {
        "type": "object",
        "properties": {"level": {"type": "integer", "minimum": 0, "maximum": 100}},
        "required": ["level"],
    },
    destructive=True,
)
def volume_set(level: int) -> dict:
    v = max(0, min(100, int(level)))
    # Reuse the same Add-Type block via a setter call. We define Audio
    # then assign [Audio]::Volume = $v in one shot.
    script = _volume_get_ps().replace("[Audio]::Volume", f"[Audio]::Volume = {v}")
    _ps(script)
    return {"ok": True, "level": v}
