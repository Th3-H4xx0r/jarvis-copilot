using System.Runtime.InteropServices;
using Jarvis.Platform;

namespace Jarvis.Input;

/// Held keys (push-to-talk, Flow) through Raw Input with RIDEV_INPUTSINK on a message-only
/// window: keyboard reports only, no hook, nothing injected, nothing blocked. Registered only
/// while at least one key is watched.
public sealed class HoldKeyWatcher : IDisposable
{
    private readonly MessageWindow _window = new("JarvisHoldKeys");
    private readonly Dictionary<uint, string> _watched = new();
    private readonly HashSet<uint> _down = new();
    private bool _registered;

    public HoldKeyWatcher() => _window.Add(OnMessage);

    /// name, down
    public event Action<string, bool>? Changed;
    /// Any other key went down while a watched key is held (cancels a hold that hasn't started).
    public event Action? OtherKey;

    public void Watch(string name, uint vk)
    {
        foreach (var kv in _watched.Where(kv => kv.Value == name).ToList()) _watched.Remove(kv.Key);
        _watched[vk] = name;
        Register(true);
    }

    public void Unwatch(string name)
    {
        foreach (var kv in _watched.Where(kv => kv.Value == name).ToList()) _watched.Remove(kv.Key);
        if (_watched.Count == 0) Register(false);
    }

    private void Register(bool on)
    {
        if (on == _registered) return;
        var dev = new[]
        {
            new Native.RAWINPUTDEVICE
            {
                usUsagePage = 0x01, usUsage = 0x06,   // generic desktop, keyboard
                dwFlags = on ? Native.RIDEV_INPUTSINK : Native.RIDEV_REMOVE,
                hwndTarget = on ? _window.Handle : IntPtr.Zero,
            },
        };
        if (Native.RegisterRawInputDevices(dev, 1, (uint)Marshal.SizeOf<Native.RAWINPUTDEVICE>())) _registered = on;
    }

    private unsafe IntPtr? OnMessage(int msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg != Native.WM_INPUT) return null;
        uint size = 0;
        var header = (uint)Marshal.SizeOf<Native.RAWINPUTHEADER>();
        Native.GetRawInputData(lParam, Native.RID_INPUT, IntPtr.Zero, ref size, header);
        if (size == 0 || size > 1024) return null;
        var buf = stackalloc byte[(int)size];
        if (Native.GetRawInputData(lParam, Native.RID_INPUT, (IntPtr)buf, ref size, header) != size) return null;
        var h = *(Native.RAWINPUTHEADER*)buf;
        if (h.dwType != Native.RIM_TYPEKEYBOARD) return null;
        var kb = *(Native.RAWKEYBOARD*)(buf + header);
        var vk = (uint)kb.VKey;
        var up = (kb.Flags & Native.RI_KEY_BREAK) != 0;
        var e0 = (kb.Flags & Native.RI_KEY_E0) != 0;
        // Raw Input reports generic Alt/Ctrl; the E0 flag marks the right-hand key.
        if (vk == 0x12) vk = e0 ? 0xA5u : 0xA4u;
        if (vk == 0x11) vk = e0 ? 0xA3u : 0xA2u;
        if (_watched.TryGetValue(vk, out var name))
        {
            if (up) { if (_down.Remove(vk)) Changed?.Invoke(name, false); }
            else if (_down.Add(vk)) Changed?.Invoke(name, true);   // ignore auto-repeat
        }
        else if (!up && _down.Count > 0)
        {
            OtherKey?.Invoke();
        }
        return null;   // DefWindowProc must still see WM_INPUT
    }

    public void Dispose()
    {
        Register(false);
        _window.Dispose();
    }
}
