using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Imaging;
using Jarvis.Core.Flow;
using Jarvis.Core.Power;
using Jarvis.Core.Screen;
using Jarvis.Flow;
using Jarvis.Music;
using Jarvis.Platform;
using Jarvis.Terminal;
using Microsoft.Win32;
using NAudio.CoreAudioApi;
using Windows.Devices.Radios;

namespace Jarvis.Screen;

/// The Command Center's switches on Windows: radios (WinRT), dark mode (the Personalize keys +
/// ImmersiveColorSet broadcast), volume (the default speaker), media (media sessions), apps and
/// windows (EnumWindows), displays, lock, sleep and keep awake. A returned string is a problem
/// the phone shows; null is done. Only reached through a live share (never while a game is on).
public sealed class PcControls : IPcControls
{
    private readonly MediaSessions _media;
    private readonly PcPowerClient _power;
    private readonly Func<int, string?> _switchDisplay;
    private readonly Func<int> _currentDisplay;
    private readonly IKeySender _keys = new SendInputKeys();

    public PcControls(MediaSessions media, PcPowerClient power, Func<int, string?> switchDisplay, Func<int> currentDisplay)
    {
        _media = media;
        _power = power;
        _switchDisplay = switchDisplay;
        _currentDisplay = currentDisplay;
    }

    // ── reads ──────────────────────────────────────────────────────────

    public PcSnapshot Snapshot()
    {
        var radios = Radios();
        bool? State(RadioKind k) => radios.FirstOrDefault(r => r.Kind == k) is { } r ? r.State == RadioState.On : null;
        int? volume = null;
        bool? muted = null;
        try
        {
            using var e = new MMDeviceEnumerator();
            var dev = e.GetDefaultAudioEndpoint(DataFlow.Render, Role.Console);
            volume = (int)Math.Round(dev.AudioEndpointVolume.MasterVolumeLevelScalar * 100);
            muted = dev.AudioEndpointVolume.Mute;
        }
        catch (COMException) { }
        var displays = Monitors.All().Select(m => new PcDisplay(DisplayNumber(m.Name), m.Name.Replace(@"\\.\", ""), m.Primary, m.Bounds.Width, m.Bounds.Height)).ToList();
        return new PcSnapshot(State(RadioKind.WiFi), null, State(RadioKind.Bluetooth), !LightTheme(), volume, muted, null, false,
            _media.Now, displays, _currentDisplay(), _power.Last?.KeepAwake);
    }

    public static int DisplayNumber(string name) =>
        int.TryParse(new string(name.Reverse().TakeWhile(char.IsDigit).Reverse().ToArray()), out var n) ? n : 0;

    private static IReadOnlyList<Radio> Radios()
    {
        try { return Radio.GetRadiosAsync().AsTask().GetAwaiter().GetResult().ToList(); }
        catch (Exception e) when (e is COMException or UnauthorizedAccessException) { return Array.Empty<Radio>(); }
    }

    private static bool LightTheme() =>
        Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1) is int v && v != 0;

    private sealed record Win(IntPtr Hwnd, int Pid, string Title, bool Iconic);

    [ThreadStatic] private static List<Win>? _wins;

    private static unsafe IReadOnlyList<Win> TopWindows()
    {
        _wins = new List<Win>();
        Native.EnumWindows(&Visit, IntPtr.Zero);
        var o = _wins;
        _wins = null;
        return o;
    }

    [UnmanagedCallersOnly]
    private static int Visit(IntPtr hwnd, IntPtr data)
    {
        if (!Native.IsWindowVisible(hwnd) || Native.GetWindow(hwnd, Native.GW_OWNER) != IntPtr.Zero) return 1;
        var ex = Native.GetWindowLongPtr(hwnd, Native.GWL_EXSTYLE).ToInt64();
        if ((ex & Native.WS_EX_TOOLWINDOW) != 0) return 1;
        var buf = new char[256];
        var n = Native.GetWindowText(hwnd, buf, buf.Length);
        if (n == 0) return 1;
        Native.GetWindowThreadProcessId(hwnd, out var pid);
        if (pid == Environment.ProcessId) return 1;
        _wins?.Add(new Win(hwnd, (int)pid, new string(buf, 0, n), Native.IsIconic(hwnd)));
        return 1;
    }

    public IReadOnlyList<PcApp> Apps()
    {
        Native.GetWindowThreadProcessId(Native.GetForegroundWindow(), out var front);
        return TopWindows().GroupBy(w => w.Pid).Select(g =>
        {
            string name = "", exe = "", path = "";
            try
            {
                var p = Process.GetProcessById(g.Key);
                exe = p.ProcessName + ".exe";
                name = p.ProcessName;
                try
                {
                    path = p.MainModule?.FileName ?? "";
                    if (p.MainModule?.FileVersionInfo.FileDescription is { Length: > 0 } d) name = d;
                }
                catch (System.ComponentModel.Win32Exception) { }   // elevated: name only
            }
            catch (ArgumentException) { return null; }
            return new PcApp(g.Key, name, exe.ToLowerInvariant(), g.Key == front, g.All(w => w.Iconic), path);
        }).OfType<PcApp>().OrderBy(a => a.Name, StringComparer.OrdinalIgnoreCase).ToList();
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct SHFILEINFO
    {
        public IntPtr hIcon;
        public int iIcon;
        public uint dwAttributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szDisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string szTypeName;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SHGetFileInfo(string path, uint attrs, ref SHFILEINFO info, uint size, uint flags);

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr icon);

    public byte[]? IconPng(PcApp app, int side)
    {
        if (app.ExePath.Length == 0) return null;
        const uint SHGFI_ICON = 0x100, SHGFI_LARGEICON = 0x0;
        var info = new SHFILEINFO();
        if (SHGetFileInfo(app.ExePath, 0, ref info, (uint)Marshal.SizeOf<SHFILEINFO>(), SHGFI_ICON | SHGFI_LARGEICON) == IntPtr.Zero || info.hIcon == IntPtr.Zero) return null;
        try
        {
            var src = Imaging.CreateBitmapSourceFromHIcon(info.hIcon, Int32Rect.Empty, BitmapSizeOptions.FromWidthAndHeight(side, side));
            src.Freeze();
            var enc = new PngBitmapEncoder();
            enc.Frames.Add(BitmapFrame.Create(src));
            using var ms = new MemoryStream();
            enc.Save(ms);
            return ms.ToArray();
        }
        finally { DestroyIcon(info.hIcon); }
    }

    public IReadOnlyList<PcWindow> Windows(int pid)
    {
        var front = Native.GetForegroundWindow();
        return TopWindows().Where(w => w.Pid == pid).Select(w => new PcWindow(w.Hwnd.ToInt64(), w.Title, w.Iconic, w.Hwnd == front)).ToList();
    }

    public bool CanNewWindow(int pid) => Apps().FirstOrDefault(a => a.Pid == pid) is { ExePath.Length: > 0 } a && File.Exists(a.ExePath);

    // ── switches ───────────────────────────────────────────────────────

    private static string? SetRadio(RadioKind kind, bool on, string name)
    {
        try
        {
            if (Radio.RequestAccessAsync().AsTask().GetAwaiter().GetResult() != RadioAccessStatus.Allowed)
                return $"Windows won't let Jarvis switch {name} from here.";
            var radio = Radios().FirstOrDefault(r => r.Kind == kind);
            if (radio == null) return $"This PC has no {name}.";
            var r = radio.SetStateAsync(on ? RadioState.On : RadioState.Off).AsTask().GetAwaiter().GetResult();
            return r == RadioAccessStatus.Allowed ? null : $"Windows won't let Jarvis switch {name} from here.";
        }
        catch (Exception e) when (e is COMException or UnauthorizedAccessException) { return $"Windows won't let Jarvis switch {name} from here."; }
    }

    public string? SetWifi(bool on) => SetRadio(RadioKind.WiFi, on, "Wi-Fi");
    public string? SetBluetooth(bool on) => SetRadio(RadioKind.Bluetooth, on, "Bluetooth");

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint msg, IntPtr wParam, string lParam, uint flags, uint timeout, out IntPtr result);

    public string? SetDark(bool on)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            key.SetValue("AppsUseLightTheme", on ? 0 : 1, RegistryValueKind.DWord);
            key.SetValue("SystemUsesLightTheme", on ? 0 : 1, RegistryValueKind.DWord);
            const uint WM_SETTINGCHANGE = 0x1A, SMTO_ABORTIFHUNG = 0x2;
            SendMessageTimeout(new IntPtr(0xFFFF), WM_SETTINGCHANGE, IntPtr.Zero, "ImmersiveColorSet", SMTO_ABORTIFHUNG, 1000, out _);
            return null;
        }
        catch (Exception e) when (e is UnauthorizedAccessException or IOException) { return "Windows wouldn't change the theme."; }
    }

    public void SetVolume(int v)
    {
        try
        {
            using var e = new MMDeviceEnumerator();
            e.GetDefaultAudioEndpoint(DataFlow.Render, Role.Console).AudioEndpointVolume.MasterVolumeLevelScalar = Math.Clamp(v, 0, 100) / 100f;
        }
        catch (COMException) { }
    }

    public void SetMute(bool on)
    {
        try
        {
            using var e = new MMDeviceEnumerator();
            e.GetDefaultAudioEndpoint(DataFlow.Render, Role.Console).AudioEndpointVolume.Mute = on;
        }
        catch (COMException) { }
    }

    /// Monitor brightness (DDC/CI or the panel's WMI class) isn't wired up yet, so the tile is
    /// hidden (the snapshot sends no brightness) and a direct ask gets this answer.
    public string? SetBrightness(double v) => "This display's brightness can't be set from here.";

    public void Media(string key) => _media.MediaKeyAsync(key).GetAwaiter().GetResult();

    public string? ActivateApp(int pid)
    {
        var w = TopWindows().FirstOrDefault(x => x.Pid == pid);
        if (w == null) return "That app has no window to show.";
        TerminalJumper.Activate(w.Hwnd);
        return null;
    }

    public string? RaiseWindow(int pid, long hwnd)
    {
        var w = TopWindows().FirstOrDefault(x => x.Pid == pid && x.Hwnd.ToInt64() == hwnd);
        if (w == null) return "That window has closed.";
        TerminalJumper.Activate(w.Hwnd);
        return null;
    }

    public string? AppAction(string action, int pid)
    {
        var wins = TopWindows().Where(w => w.Pid == pid).ToList();
        switch (action)
        {
            case "app_hide":
                foreach (var w in wins) Native.ShowWindow(w.Hwnd, Native.SW_MINIMIZE);
                return null;
            case "app_show_all":
                foreach (var w in wins) Native.ShowWindow(w.Hwnd, Native.SW_RESTORE);
                return null;
            case "app_quit":
                const uint WM_CLOSE = 0x10;
                foreach (var w in wins) Native.PostMessage(w.Hwnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
                return null;
            case "app_new_window":
                var app = Apps().FirstOrDefault(a => a.Pid == pid);
                if (app is not { ExePath.Length: > 0 }) return "Jarvis can't start another window of that app.";
                try { Process.Start(new ProcessStartInfo(app.ExePath) { UseShellExecute = true }); return null; }
                catch (System.ComponentModel.Win32Exception) { return "Jarvis can't start another window of that app."; }
            default:
                return $"The PC app doesn't know “{action}” yet: update Jarvis on the PC.";
        }
    }

    public string? SwitchDisplay(int id) => _switchDisplay(id);

    [DllImport("user32.dll")]
    private static extern bool LockWorkStation();

    [DllImport("powrprof.dll")]
    private static extern bool SetSuspendState(bool hibernate, bool force, bool disableWake);

    public void Lock() => LockWorkStation();

    private const ushort VkWin = 0x5B;

    private void WinChord(ushort key) => _keys.Send(new[] { (VkWin, true), (key, true), (key, false), (VkWin, false) });

    public void QuickSettings() => WinChord(0x41);   // Win+A
    public void TaskView() => WinChord(0x09);        // Win+Tab
    public void ShowDesktop() => WinChord(0x44);     // Win+D
    public void Sleep() => SetSuspendState(false, false, false);

    public async Task<string?> SetKeepAwake(bool on)
    {
        var s = await _power.SetKeepAwakeAsync(on);
        return s == null ? "Jarvis isn't running on this PC." : null;
    }
}
