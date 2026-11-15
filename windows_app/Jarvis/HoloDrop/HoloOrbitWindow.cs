using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Jarvis.Core.Gaming;
using Jarvis.Core.Holo;
using Jarvis.Core.Ui;
using Jarvis.Platform;
using Jarvis.Ui;

namespace Jarvis.HoloDrop;

/// The Orbit (Ctrl+Alt+H): what's in front in the middle, his devices around it; a click sends
/// with the device's default action. Nothing grabbed → Paste or drop a file onto it. Opens on the
/// monitor under the cursor, never activated; closes 1.2 s after a send lands.
public sealed class HoloOrbitWindow : NoActivateWindow
{
    private const double Side = 420, Ring = 150, Bubble = 76;
    private readonly HoloDropService _service;
    private readonly HoloSender _sender;
    private readonly Canvas _canvas = new() { Width = Side, Height = Side };
    private readonly TextBlock _status = Th.Text("", 12, "JcTextDim", wrap: true);
    private HoloItem? _item;
    private IReadOnlyList<HoloDevice> _devices;

    public HoloOrbitWindow(HoloDropService service, HoloSender sender, HoloItem? item, IReadOnlyList<HoloDevice> devices)
    {
        _service = service;
        _sender = sender;
        _item = item;
        _devices = devices;
        Title = "Holo Drop";
        Background = Brushes.Transparent;
        Width = Side;
        Height = Side + 40;
        AllowDrop = true;
        Drop += (_, e) =>
        {
            if (e.Data.GetData(DataFormats.FileDrop) is string[] files && files.Length > 0) _item = HoloItem.Files(files);
            else if (e.Data.GetData(DataFormats.UnicodeText) is string text) _item = HoloItem.FromText(text);
            Render();
        };
        Content = new Border
        {
            Background = Th.B("JcBackground"),
            CornerRadius = new CornerRadius(Side / 2),
            Child = new Grid { Children = { _canvas } },
        };
        _service.ShowInOrbit = (_, line) => { Dispatcher.BeginInvoke(() => Done(line)); return IsVisible; };
        Closed += (_, _) => _service.ShowInOrbit = null;
        Render();
    }

    public void Present()
    {
        Show();
        var hwnd = new WindowInteropHelper(this).Handle;
        if (Monitors.At(Monitors.Cursor()) is not { } m || hwnd == IntPtr.Zero) return;
        var scale = Monitors.Scale(m.Handle);
        var c = Monitors.Cursor();
        int w = (int)(Width * scale), h = (int)(Height * scale);
        var left = (int)Math.Clamp(c.X - w / 2.0, m.Work.Left, m.Work.Right - w);
        var top = (int)Math.Clamp(c.Y - h / 2.0, m.Work.Top, m.Work.Bottom - h);
        Monitors.Place(hwnd, new RectI(left, top, left + w, top + h));
    }

    /// Fling: send to the device nearest the angle without a click.
    public void SendToward(double angleDeg)
    {
        if (_item == null) return;
        var placed = HoloOrbitLayout.Place(HoloSendDefaults.Targets(_devices, _item));
        if (HoloOrbitLayout.Pick(angleDeg, placed) is { } d) _ = SendAsync(d);
    }

    private void Render()
    {
        _canvas.Children.Clear();
        var centre = new PointD(Side / 2, Side / 2);
        var middle = new StackPanel { Width = 160, HorizontalAlignment = HorizontalAlignment.Center };
        middle.Children.Add(Th.Text(_item?.Caption ?? "Nothing in front", 13, bold: true, wrap: true));
        if (_item == null) middle.Children.Add(Th.Button("Paste", Paste, size: 12));
        middle.Children.Add(_status);
        Canvas.SetLeft(middle, centre.X - 80);
        Canvas.SetTop(middle, centre.Y - 30);
        _canvas.Children.Add(middle);

        var targets = _item == null ? _devices : HoloSendDefaults.Targets(_devices, _item);
        var placed = HoloOrbitLayout.Place(targets);
        var spots = HoloOrbitLayout.Positions(placed, centre, Ring);
        var nearest = HoloOrbitLayout.Nearest(targets);
        foreach (var (device, _) in placed)
        {
            var d = device;
            var b = new Button
            {
                Width = Bubble,
                Height = Bubble,
                Style = Th.S(nearest?.Id == d.Id ? "JcPrimaryButtonStyle" : "JcButtonStyle"),
                Content = Th.Text(d.Name, 11, nearest?.Id == d.Id ? "JcPrimaryText" : "JcText", wrap: true),
                IsEnabled = _item != null,
                Focusable = false,
            };
            b.Click += (_, _) => _ = SendAsync(d);
            var p = spots[d.Id];
            Canvas.SetLeft(b, p.X - Bubble / 2);
            Canvas.SetTop(b, p.Y - Bubble / 2);
            _canvas.Children.Add(b);
        }
        if (targets.Count == 0) _status.Text = "No device can take this right now.";
    }

    private void Paste()
    {
        try
        {
            if (Clipboard.ContainsFileDropList()) _item = HoloItem.Files(Clipboard.GetFileDropList().Cast<string>());
            else if (Clipboard.ContainsText()) _item = HoloItem.FromText(Clipboard.GetText());
        }
        catch (COMException) { }
        Render();
    }

    private async Task SendAsync(HoloDevice d)
    {
        if (_item is not { } item) return;
        _status.Text = $"Sending to {d.Name}…";
        var sent = await _sender.SendDetailedAsync(item, d, HoloSendDefaults.Action(item));
        _service.Track(sent, d.Name);
        if (sent.Error is { } err) { _status.Text = err; return; }
        if (sent.Outcome is { } o) Done(HoloDropRecord.LandedLine(d.Name, o.Wire, null));
        else _status.Text = $"Sent to {d.Name}.";
    }

    private void Done(string line)
    {
        _status.Text = line;
        var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.2) };
        t.Tick += (_, _) => { t.Stop(); Close(); };
        t.Start();
    }
}

/// The mouse fling (off by default): Raw Input mouse is registered only while Ctrl+Alt are held,
/// fling is on, and no game is on (FlingWatchRule). A fast long drag gives an angle; no hook, and
/// nothing is blocked or injected.
public sealed class HoloFlingWatcher : IDisposable
{
    private readonly MessageWindow _window = new("JarvisFling");
    private readonly FlingDetector _fling = new();
    private readonly System.Diagnostics.Stopwatch _clock = System.Diagnostics.Stopwatch.StartNew();
    private bool _registered, _down;

    public HoloFlingWatcher() => _window.Add(OnMessage);

    public event Action<double>? Flung;

    public void Update(bool flingOn, bool ctrlAltDown, Core.Model.GameMode mode)
    {
        var want = FlingWatchRule.ShouldRegister(flingOn, ctrlAltDown, mode);
        if (want == _registered) return;
        var dev = new[]
        {
            new Native.RAWINPUTDEVICE
            {
                usUsagePage = 0x01, usUsage = 0x02,   // generic desktop, mouse
                dwFlags = want ? Native.RIDEV_INPUTSINK : Native.RIDEV_REMOVE,
                hwndTarget = want ? _window.Handle : IntPtr.Zero,
            },
        };
        if (Native.RegisterRawInputDevices(dev, 1, (uint)Marshal.SizeOf<Native.RAWINPUTDEVICE>())) _registered = want;
        _down = false;
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
        if (((Native.RAWINPUTHEADER*)buf)->dwType != Native.RIM_TYPEMOUSE) return null;
        var m = *(Native.RAWMOUSE*)(buf + header);
        var t = _clock.Elapsed.TotalSeconds;
        var p = Monitors.Cursor();
        if ((m.usButtonFlags & Native.RI_MOUSE_LEFT_BUTTON_DOWN) != 0) { _down = true; _fling.Down(t, p); }
        else if ((m.usButtonFlags & Native.RI_MOUSE_LEFT_BUTTON_UP) != 0 && _down)
        {
            _down = false;
            if (_fling.Up(t, p) is { } angle) Flung?.Invoke(angle);
        }
        else if (_down) _fling.Move(t, p);
        return null;
    }

    public void Dispose()
    {
        Update(false, false, Core.Model.GameMode.Off);
        _window.Dispose();
    }
}
