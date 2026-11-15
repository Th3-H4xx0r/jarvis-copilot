"""Pure pieces of the Windows skills (skills/windows.py), importable on any OS so they can be
tested on the Mac: no ctypes.windll, no skill registration here."""
from __future__ import annotations

import re
from typing import Optional

# The same spotify: URIs the Mac's spotify_play takes.
SPOTIFY_URI = re.compile(r"spotify:(track|album|playlist|artist|episode|show):[A-Za-z0-9]{22}")

# Virtual-key codes of the media keys (they reach whatever app is playing).
VK_MEDIA_NEXT, VK_MEDIA_PREV, VK_MEDIA_PLAY_PAUSE = 0xB0, 0xB1, 0xB3
MEDIA_ACTIONS = ("play", "pause", "toggle", "next", "previous", "status")
MEDIA_VK = {"play": VK_MEDIA_PLAY_PAUSE, "pause": VK_MEDIA_PLAY_PAUSE, "toggle": VK_MEDIA_PLAY_PAUSE,
            "next": VK_MEDIA_NEXT, "previous": VK_MEDIA_PREV}

# The Mac's system_command names, as Windows shortcuts (pynput key names for key_press).
SYSTEM_COMBOS = {
    "copy": ["ctrl", "c"], "paste": ["ctrl", "v"], "cut": ["ctrl", "x"], "undo": ["ctrl", "z"],
    "redo": ["ctrl", "y"], "selectall": ["ctrl", "a"], "save": ["ctrl", "s"], "quit": ["alt", "f4"],
    "minimize": ["cmd", "down"], "switchapp": ["alt", "tab"], "newtab": ["ctrl", "t"],
    "closetab": ["ctrl", "w"], "newwindow": ["ctrl", "n"], "closewindow": ["alt", "f4"],
    "find": ["ctrl", "f"], "refresh": ["f5"], "screenshot": ["cmd", "shift", "s"], "spotlight": ["cmd", "s"],
}


def image_name(name: str) -> str:
    """A process image name for taskkill / Get-Process: ".exe" added only when missing
    (the old ``.rstrip(".exe")`` stripped characters: "explorer" became "explor")."""
    name = (name or "").strip()
    return name if name.lower().endswith(".exe") else name + ".exe"


def media_plan(action: str, playing: Optional[bool]) -> tuple:
    """``(vk or None, result)`` for a media_control action, with the Mac's rules: ``play``
    and ``pause`` do nothing when it's already in that state; ``status`` sends nothing."""
    act = (action or "").strip().lower()
    if act not in MEDIA_ACTIONS:
        raise ValueError(f"action must be one of {', '.join(MEDIA_ACTIONS)}")
    if act == "status":
        out = {"ok": True, "action": act}
        if playing is not None:
            out["playing"] = playing
        return None, out
    if act == "play" and playing is True:
        return None, {"ok": True, "action": act, "changed": False, "playing": True}
    if act == "pause" and playing is False:
        return None, {"ok": True, "action": act, "changed": False, "playing": False}
    return MEDIA_VK[act], {"ok": True, "action": act, "changed": True}


_VOLUME_CS = r"""
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
public class JcAudio {
    static IAudioEndpointVolume Ep() {
        var e = new MMDeviceEnumeratorComObject() as IMMDeviceEnumerator;
        IMMDevice dev = null; e.GetDefaultAudioEndpoint(0, 1, out dev);
        object o; Guid IID = typeof(IAudioEndpointVolume).GUID;
        dev.Activate(ref IID, 23, IntPtr.Zero, out o);
        return (IAudioEndpointVolume)o;
    }
    public static float Get() { float r = 0; Ep().GetMasterVolumeLevelScalar(out r); return r * 100; }
    public static void Set(float level) { Ep().SetMasterVolumeLevelScalar(level, Guid.Empty); }
}
'@
Add-Type -TypeDefinition $src -ErrorAction SilentlyContinue
"""


def volume_script(level: Optional[int] = None) -> str:
    """PowerShell that reads (level None) or sets the master volume (0–100) via Core Audio."""
    if level is None:
        return _VOLUME_CS + "[JcAudio]::Get()\n"
    v = max(0, min(100, int(level)))
    return _VOLUME_CS + f"[JcAudio]::Set({v / 100:.2f}); [JcAudio]::Get()\n"
