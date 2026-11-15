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

    /// A white ring on black: the Jarvis mark, drawn so no image asset is needed. A System.Drawing
    /// icon: H.NotifyIcon can't convert a WPF RenderTargetBitmap (NotImplementedException).
    private static System.Drawing.Icon DrawIcon()
    {
        static System.Drawing.Color C(string key) =>
            Th.B(key) is SolidColorBrush b ? System.Drawing.Color.FromArgb(b.Color.A, b.Color.R, b.Color.G, b.Color.B)
                                           : System.Drawing.Color.White;
        using var bmp = new System.Drawing.Bitmap(32, 32);
        using (var g = System.Drawing.Graphics.FromImage(bmp))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            using var fill = new System.Drawing.SolidBrush(C("JcBackground"));
            using var ring = new System.Drawing.Pen(C("JcAccent"), 3);
            g.FillEllipse(fill, 1, 1, 30, 30);
            g.DrawEllipse(ring, 7, 7, 18, 18);
        }
        return System.Drawing.Icon.FromHandle(bmp.GetHicon());
    }

    public void Dispose()
    {
        _icon.Dispose();
        _menu.Dispose();
    }
}
