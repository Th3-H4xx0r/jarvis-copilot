using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using H.NotifyIcon;
using Jarvis.Core.State;
using Jarvis.Core.Tray;
using Jarvis.Ui;

namespace Jarvis.Tray;

/// The notification-area icon. Left click opens the island; right click shows the menu built by
/// Core's TrayMenu (status, roster, Holo Drop…, Weekly recap, Settings, Re-pair, Logs, Restart,
/// Quit), refreshed from jc-client each time it opens.
public sealed class TrayIcon : IDisposable
{
    private readonly AppState _state;
    private readonly TaskbarIcon _icon;
    private readonly NativeMenu _menu = new();
    private bool _menuOpen;
    private readonly Func<bool> _keepAwake;
    private readonly Func<bool> _recording;

    public TrayIcon(AppState state, Func<bool> keepAwake, Func<bool> recording)
    {
        _state = state;
        _keepAwake = keepAwake;
        _recording = recording;
        _icon = new TaskbarIcon
        {
            ToolTipText = "Jarvis",
            Icon = DrawIcon(),
            NoLeftClickDelay = true,
        };
        _icon.TrayLeftMouseUp += (_, _) => Command?.Invoke(TrayCommand.OpenIsland);
        _icon.TrayRightMouseUp += async (_, _) =>
        {
            if (_menuOpen) return;
            // A fresh roster if jc-client answers quickly; never hold the menu up for it.
            await Task.WhenAny(_state.RefreshRosterAsync(), Task.Delay(300));
            OpenMenu();
        };
        _state.Changed += UpdateTip;
        _icon.ForceCreate(false);
    }

    /// Commands the app handles itself (jc-client's own are sent from here).
    public event Action<TrayCommand>? Command;

    /// `Jarvis.exe --diag open-tray-menu` (desktop verification).
    public void OpenMenu()
    {
        if (_menuOpen) return;
        _menuOpen = true;
        try { _menu.Show(Entries()); }
        finally { _menuOpen = false; }
    }

    /// The menu has closed before an entry runs, so a slow jc-client call never holds it up.
    private List<NativeMenu.Entry> Entries() =>
        TrayMenu.Build(_state.Roster, _state.Connected, _keepAwake(), _recording()).Select(item =>
        {
            if (item.Separator) return new NativeMenu.Entry("", Separator: true);
            Action? run = item.Command is { } c
                ? () =>
                {
                    if (TrayMenu.RunLinkAction(c, _state) is { } task) _ = task;
                    else Command?.Invoke(c);
                }
                : null;
            // Headers and roster rows are information, not commands: shown, never greyed out.
            return new NativeMenu.Entry(item.Detail.Length > 0 ? $"{item.Label}  ·  {item.Detail}" : item.Label,
                run, Enabled: item.Enabled || item.Command == null, Checked: item.Checked == true, Bold: item.Header);
        }).ToList();

    private void UpdateTip()
    {
        var tip = _state.WaitingCount > 0 ? $"Jarvis · {_state.WaitingCount} waiting on you"
            : _state.WorkingCount > 0 ? $"Jarvis · {_state.WorkingCount} working"
            : _state.Connected ? "Jarvis" : "Jarvis · not running";
        if (_icon.ToolTipText != tip) _icon.ToolTipText = tip;
    }

    /// The Jarvis app icon (jarvis.ico, the same one as the Mac and iPhone apps), at the tray's
    /// size for this screen's scale.
    private static System.Drawing.Icon DrawIcon()
    {
        var path = System.IO.Path.Combine(AppContext.BaseDirectory, "jarvis.ico");
        var side = Math.Max(16, GetSystemMetrics(49 /* SM_CXSMICON */));
        try { return new System.Drawing.Icon(path, side, side); }
        catch (Exception e) when (e is System.IO.IOException or ArgumentException or UnauthorizedAccessException)
        {
            return System.Drawing.Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? System.Drawing.SystemIcons.Application;
        }
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    public void Dispose()
    {
        _icon.Dispose();
        _menu.Dispose();
    }
}
