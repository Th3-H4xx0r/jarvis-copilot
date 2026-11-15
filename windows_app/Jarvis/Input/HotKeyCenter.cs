using Jarvis.Core.Input;
using Jarvis.Platform;

namespace Jarvis.Input;

/// Global chords through RegisterHotKey on a message-only window. No keyboard hook anywhere
/// (anti-cheat), and a chord another app already owns simply fails to bind (reported, not forced).
public sealed class HotKeyCenter : IDisposable
{
    private readonly MessageWindow _window = new("JarvisHotKeys");
    private readonly Dictionary<int, ShortcutAction> _ids = new();
    private readonly Dictionary<ShortcutAction, int> _byAction = new();
    private int _next = 1;

    public HotKeyCenter() => _window.Add(OnMessage);

    public event Action<ShortcutAction>? Pressed;
    /// The chord is taken by another app (Settings shows it).
    public event Action<ShortcutAction, Shortcut>? Failed;

    public void Bind(ShortcutAction a, Shortcut? s)
    {
        if (_byAction.Remove(a, out var old))
        {
            Native.UnregisterHotKey(_window.Handle, old);
            _ids.Remove(old);
        }
        if (s is not { } chord) return;
        var id = _next++;
        if (!Native.RegisterHotKey(_window.Handle, id, (uint)chord.Mods | Native.MOD_NOREPEAT, chord.Vk))
        {
            Failed?.Invoke(a, chord);
            return;
        }
        _ids[id] = a;
        _byAction[a] = id;
    }

    /// Unbind everything (while the Shortcuts recorder listens, so a chord can be re-recorded).
    public void Suspend()
    {
        foreach (var id in _ids.Keys) Native.UnregisterHotKey(_window.Handle, id);
        _ids.Clear();
        _byAction.Clear();
    }

    private IntPtr? OnMessage(int msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg != Native.WM_HOTKEY) return null;
        if (_ids.TryGetValue(wParam.ToInt32(), out var a)) Pressed?.Invoke(a);
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        Suspend();
        _window.Dispose();
    }
}
