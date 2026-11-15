using System.Runtime.InteropServices;
using System.Windows.Interop;

namespace Jarvis.Tray;

/// A plain Win32 popup menu for the notification-area icon, shown the way Windows documents for
/// tray menus: the owner window is made foreground first and TrackPopupMenuEx returns the picked
/// item, so the menu always closes on a click or a click elsewhere. (A WPF ContextMenu opened from
/// the tray never gets foreground in a no-activate app, so it stayed open and dropped clicks.)
/// Dark like the rest of Jarvis (uxtheme's app mode, the same switch Explorer's menus follow).
internal sealed partial class NativeMenu : IDisposable
{
    public sealed record Entry(string Text, Action? Run = null, bool Enabled = true, bool Checked = false,
        bool Bold = false, bool Separator = false);

    private readonly HwndSource _owner;

    public NativeMenu()
    {
        // A hidden top-level window that may take the foreground (the click on the tray icon gives
        // this process the right to): no WS_EX_NOACTIVATE, never shown.
        _owner = new HwndSource(new HwndSourceParameters("JarvisTrayMenu")
        {
            Width = 0,
            Height = 0,
            WindowStyle = unchecked((int)0x80000000),   // WS_POPUP
            ExtendedWindowStyle = 0x80,                 // WS_EX_TOOLWINDOW
        });
        try
        {
            SetPreferredAppMode(2);   // ForceDark
            FlushMenuThemes();
        }
        catch (EntryPointNotFoundException) { }   // older Windows: light menu
    }

    /// Shows the menu at the cursor and runs the picked entry's action after it has closed.
    public void Show(IReadOnlyList<Entry> entries)
    {
        var menu = CreatePopupMenu();
        try
        {
            for (var i = 0; i < entries.Count; i++)
            {
                var e = entries[i];
                if (e.Separator) { AppendMenuW(menu, MF_SEPARATOR, 0, null); continue; }
                var flags = MF_STRING | (e.Enabled ? 0 : MF_GRAYED) | (e.Checked ? MF_CHECKED : 0);
                AppendMenuW(menu, flags, (nuint)(i + 1), e.Text.Replace("&", "&&"));
                if (e.Bold) SetMenuDefaultItem(menu, (uint)(i + 1), 0);
            }
            GetCursorPos(out var pt);
            SetForegroundWindow(_owner.Handle);
            var picked = TrackPopupMenuEx(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY | TPM_BOTTOMALIGN,
                pt.X, pt.Y, _owner.Handle, IntPtr.Zero);
            PostMessageW(_owner.Handle, 0 /* WM_NULL */, IntPtr.Zero, IntPtr.Zero);
            if (picked > 0 && picked <= entries.Count) entries[picked - 1].Run?.Invoke();
        }
        finally
        {
            DestroyMenu(menu);
        }
    }

    public void Dispose() => _owner.Dispose();

    private const uint MF_STRING = 0, MF_GRAYED = 1, MF_CHECKED = 8, MF_SEPARATOR = 0x800;
    private const uint TPM_RIGHTBUTTON = 2, TPM_BOTTOMALIGN = 0x20, TPM_NONOTIFY = 0x80, TPM_RETURNCMD = 0x100;

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int X, Y; }

    [LibraryImport("user32.dll")]
    private static partial IntPtr CreatePopupMenu();

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DestroyMenu(IntPtr menu);

    [LibraryImport("user32.dll", StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool AppendMenuW(IntPtr menu, uint flags, nuint id, string? text);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetMenuDefaultItem(IntPtr menu, uint item, uint byPos);

    [LibraryImport("user32.dll")]
    private static partial int TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr hwnd, IntPtr tpm);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetForegroundWindow(IntPtr hwnd);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetCursorPos(out POINT pt);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool PostMessageW(IntPtr hwnd, int msg, IntPtr w, IntPtr l);

    // Undocumented ordinals (stable since Windows 10 1903); DllImport because they're ordinals.
    [DllImport("uxtheme.dll", EntryPoint = "#135")]
    private static extern int SetPreferredAppMode(int mode);

    [DllImport("uxtheme.dll", EntryPoint = "#136")]
    private static extern void FlushMenuThemes();
}
