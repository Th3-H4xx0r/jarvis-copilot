using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using Jarvis.Core.Gaming;
using Jarvis.Core.Holo;
using Jarvis.Core.Ui;
using Jarvis.Platform;
using Jarvis.Ui;

namespace Jarvis.HoloDrop;

/// The Orbit (Ctrl+Alt+H), drawn as the Mac's (HoloOrbitView.swift): a 400x520 black panel,
/// HOLO DROP and a close button on top, his devices on a dashed ring around the item card, the
/// nearest one lit, a status line and the action chips at the bottom (only the chosen chip
/// filled). A click on a device sends with the chosen action; nothing grabbed → Paste or drop a
/// file. Opens on the monitor under the cursor, never activated, so Esc and Ctrl+V are read from
/// the key state while it's open (no hook). Stays open on clicks elsewhere (so a file can be
/// dragged onto it from Explorer); closes on its ✕, Esc, or after a send lands. Starts with the
/// clipboard when nothing was grabbed; Clipboard / File… / Screenshot pick something else.
public sealed class HoloOrbitWindow : NoActivateWindow
{
    private const double W = 400, H = 572, Ring = 138, CentreY = 248;
    private readonly HoloDropService _service;
    private readonly HoloSender _sender;
    private readonly Canvas _canvas = new() { Width = W, Height = H };
    private readonly TextBlock _status = K.T("", 11, null, K.W(0.5));
    private readonly DispatcherTimer _keys = new() { Interval = TimeSpan.FromMilliseconds(50) };
    private readonly Border _panel;
    private HoloItem? _item;
    private HoloAction? _override;
    private string? _aimed;
    private bool _busy, _closing, _escWas, _vWas, _fromClipboard;
    private IReadOnlyList<HoloDevice> _devices;

    public HoloOrbitWindow(HoloDropService service, HoloSender sender, HoloItem? item, IReadOnlyList<HoloDevice> devices)
    {
        _service = service;
        _sender = sender;
        _devices = devices;
        // Nothing grabbed from the window in front: start with what's on his clipboard.
        _item = item ?? ClipboardItem();
        _fromClipboard = item == null && _item != null;
        Title = "Holo Drop";
        Background = Brushes.Transparent;
        Width = W;
        Height = H;
        AllowDrop = true;
        _panel = new Border
        {
            Background = Th.B("JcOrbitPanel"),
            BorderBrush = K.W(0.12),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(26),
            Child = _canvas,
        };
        Content = _panel;
        DragEnter += (_, _) => _panel.BorderBrush = K.W(0.6);
        DragLeave += (_, _) => _panel.BorderBrush = K.W(0.12);
        Drop += (_, e) =>
        {
            _panel.BorderBrush = K.W(0.12);
            if (e.Data.GetData(DataFormats.FileDrop) is string[] files && files.Length > 0) _item = HoloItem.Files(files);
            else if (e.Data.GetData(DataFormats.UnicodeText) is string text) _item = HoloItem.FromText(text);
            _fromClipboard = false;
            Render();
        };
        _service.ShowInOrbit = (_, line) => { Dispatcher.BeginInvoke(() => Done(line)); return IsVisible; };
        _keys.Tick += (_, _) => WatchKeys();
        Closed += (_, _) =>
        {
            _keys.Stop();
            _service.ShowInOrbit = null;
        };
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
        // Whatever is held down as it opens (the click or the keys that opened it) isn't a new press.
        _escWas = Down(0x1B);
        _vWas = Down(0x56);
        _keys.Start();
    }

    /// Fling: send to the device nearest the angle without a click.
    public void SendToward(double angleDeg)
    {
        if (_item == null) return;
        var placed = HoloOrbitLayout.Place(Targets());
        if (HoloOrbitLayout.Pick(angleDeg, placed) is { } d) _ = SendAsync(d);
    }

    public void CloseOrbit()
    {
        if (_closing) return;
        _closing = true;
        Close();
    }

    private static bool Down(int vk) => (Native.GetAsyncKeyState(vk) & 0x8000) != 0;

    /// Esc closes and Ctrl+V pastes. A click elsewhere does NOT close it (as on the Mac): he
    /// clicks in Explorer to drag a file onto it.
    private void WatchKeys()
    {
        var esc = Down(0x1B);
        if (esc && !_escWas) { CloseOrbit(); return; }
        _escWas = esc;
        var v = Down(0x56);
        if (v && !_vWas && Down(0x11) && IsMouseOver) Paste();
        _vWas = v;
    }

    private IReadOnlyList<HoloDevice> Targets() => _item == null ? _devices : HoloSendDefaults.Targets(_devices, _item);

    private HoloDevice? Hot(IReadOnlyList<HoloDevice> targets) =>
        targets.FirstOrDefault(d => d.Id == _aimed) ?? HoloOrbitLayout.Nearest(targets);

    private HoloAction Action(IReadOnlyList<HoloDevice> targets) =>
        _override ?? (_item is { } i ? HoloSendDefaults.Action(i) : Hot(targets)?.DefaultAction ?? HoloAction.Open);

    private static void Place(UIElement e, double x, double y) { Canvas.SetLeft(e, x); Canvas.SetTop(e, y); }

    private void Render()
    {
        _canvas.Children.Clear();
        var targets = Targets();

        // ── header ──
        var title = K.T("HOLO DROP", 12, FontWeights.SemiBold, K.W(0.5));
        title.TextAlignment = TextAlignment.Center;
        title.Width = W;
        Place(title, 0, 21);
        _canvas.Children.Add(title);
        var xIcon = new Grid { Width = 26, Height = 26 };
        xIcon.Children.Add(new Ellipse { Fill = K.W(0.08) });
        xIcon.Children.Add(K.Glyph("\uE711", 10, K.W(0.7)));
        var close = new Tap(xIcon, PressLook.Shrink, "Close (Esc)");
        close.Click += CloseOrbit;
        Place(close, W - 16 - 26, 16);
        _canvas.Children.Add(close);

        // ── the ring ──
        var ring = new Ellipse
        {
            Width = Ring * 2, Height = Ring * 2, Stroke = K.W(0.06), StrokeThickness = 1,
            StrokeDashArray = new DoubleCollection { 3, 5 },
        };
        Place(ring, W / 2 - Ring, CentreY - Ring);
        _canvas.Children.Add(ring);
        if (targets.Count == 0)
        {
            var none = K.T(_devices.Count == 0 ? "Finding your devices…" : "No device can take this right now", 11, null, K.W(0.45));
            none.TextAlignment = TextAlignment.Center;
            none.Width = W;
            Place(none, 0, CentreY - Ring - 8);
            _canvas.Children.Add(none);
        }
        var placed = HoloOrbitLayout.Place(targets);
        var spots = HoloOrbitLayout.Positions(placed, new PointD(W / 2, CentreY), Ring);
        var hot = Hot(targets);
        foreach (var (device, _) in placed)
        {
            var bubble = Bubble(device, hot?.Id == device.Id);
            var p = spots[device.Id];
            Place(bubble, p.X - 40, p.Y + 10 - 26);
            _canvas.Children.Add(bubble);
        }

        // ── the item ──
        var card = ItemCard();
        Place(card, W / 2 - 62, CentreY - 76);
        _canvas.Children.Add(card);

        // ── footer: status, then the chips ──
        if (!_busy && _status.Tag is not "set")
            _status.Text = _item == null ? "Paste or drop a file" : "Click a device to drop it there";
        // The Mac's footer: the status line 12 pt above the chips, growing upward if it wraps.
        _status.TextAlignment = TextAlignment.Center;
        _status.TextWrapping = TextWrapping.Wrap;
        _status.VerticalAlignment = VerticalAlignment.Bottom;
        if (_status.Parent is Grid old) old.Children.Remove(_status);
        var statusBox = new Grid { Width = W - 40, Height = 34 };
        statusBox.Children.Add(_status);
        Place(statusBox, 20, H - 18 - 26 - 10 - 28 - 8 - 34);
        _canvas.Children.Add(statusBox);

        // Where the item comes from: the clipboard, a file, a screenshot (or drag one on).
        var sources = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
        sources.Children.Add(Source("\uE77F", "Clipboard", "What you last copied", () => { Paste(); }));
        sources.Children.Add(Source("\uE8E5", "File…", "Pick files to send", PickFiles));
        sources.Children.Add(Source("\uE722", "Screenshot", "This screen, without the Holo Drop panel", () => _ = ScreenshotAsync()));
        var sourceRow = new Grid { Width = W };
        sourceRow.Children.Add(sources);
        Place(sourceRow, 0, H - 18 - 26 - 10 - 28);
        _canvas.Children.Add(sourceRow);
        var chips = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
        var chosen = Action(targets);
        foreach (var a in Enum.GetValues<HoloAction>())
        {
            var on = a == chosen;
            var chip = new Tap(K.T(a.Title(), 10.5, on ? FontWeights.SemiBold : FontWeights.Normal, on ? Th.B("JcPrimaryText") : K.W(0.72)), PressLook.Dim)
            {
                Background = on ? Th.B("JcAccent") : K.W(0.10),
                CornerRadius = new CornerRadius(K.CapsuleRadius),
                Padding = new Thickness(8, 6, 8, 6),
                Margin = new Thickness(chips.Children.Count == 0 ? 0 : 5, 0, 0, 0),
                IsEnabled = !_busy,
            };
            var action = a;
            chip.Click += () => { _override = action; Render(); };
            chips.Children.Add(chip);
        }
        var chipRow = new Grid { Width = W };
        chipRow.Children.Add(chips);
        Place(chipRow, 0, H - 18 - 26);
        _canvas.Children.Add(chipRow);
    }

    private Tap Source(string glyph, string label, string tip, Action run)
    {
        var row = K.H(5, K.Glyph(glyph, 12, K.W(0.8)), K.T(label, 11, FontWeights.Medium, K.W(0.85)));
        var t = new Tap(row, PressLook.Dim, tip)
        {
            Background = K.W(0.08),
            BorderBrush = K.W(0.12),
            BorderThickness = new Thickness(0.5),
            CornerRadius = new CornerRadius(K.CapsuleRadius),
            Padding = new Thickness(10, 6, 11, 6),
            Margin = new Thickness(4, 0, 4, 0),
            IsEnabled = !_busy,
        };
        t.Click += run;
        return t;
    }

    private FrameworkElement Bubble(HoloDevice d, bool hot)
    {
        var circle = new Grid { Width = 52, Height = 52 };
        if (hot) circle.Children.Add(new Ellipse { Fill = K.W(0.08), Margin = new Thickness(-6) });
        circle.Children.Add(new Ellipse { Fill = Th.B("JcOrbitBubble"), Stroke = hot ? K.W(1) : K.W(0.2), StrokeThickness = 1 });
        circle.Children.Add(K.Glyph(DeviceGlyph(d.Kind), 19, K.W(d.Online ? 0.92 : 0.45)));
        var name = K.T(d.Name, 10.5, FontWeights.Medium, K.W(d.Online ? 0.92 : 0.45));
        name.MaxWidth = 80;
        name.HorizontalAlignment = HorizontalAlignment.Center;
        var col = new StackPanel { Width = 80 };
        circle.HorizontalAlignment = HorizontalAlignment.Center;
        col.Children.Add(circle);
        name.Margin = new Thickness(0, 6, 0, 0);
        col.Children.Add(name);
        var tap = new Tap(col, PressLook.Shrink, d.Online ? $"Drop on {d.Name}" : $"{d.Name} is away — Jarvis holds it until it's back")
        {
            IsEnabled = _item != null && !_busy,
        };
        tap.MouseEnter += (_, _) => { if (_aimed != d.Id) { _aimed = d.Id; Dispatcher.BeginInvoke(Render); } };
        tap.Click += () => _ = SendAsync(d);
        return tap;
    }

    private FrameworkElement ItemCard()
    {
        var art = new Grid { Height = 92, Background = Th.B("JcOrbitCardArt") };
        art.Children.Add(K.Glyph(ItemGlyph(_item), 28, K.W(0.45)));
        var caption = K.T(_item?.Caption ?? "Nothing in front", 11, FontWeights.Medium, K.W(0.85), wrap: true);
        caption.MaxHeight = 30;
        var detail = K.T(_item == null ? "Paste or drop a file" : _fromClipboard ? "From your clipboard" : ItemDetail(_item), 10, null, K.W(0.45));
        var text = new StackPanel { Margin = new Thickness(10, 8, 10, 8) };
        text.Children.Add(caption);
        detail.Margin = new Thickness(0, 2, 0, 0);
        text.Children.Add(detail);
        var col = new StackPanel();
        col.Children.Add(art);
        col.Children.Add(text);
        var card = new Border
        {
            Width = 124, Height = 152,
            Background = Th.B("JcOrbitCard"),
            CornerRadius = new CornerRadius(18),
            BorderBrush = K.W(_item == null ? 0.12 : 0.2),
            BorderThickness = new Thickness(1),
            Child = col,
            ClipToBounds = true,
            ToolTip = _item == null ? "Paste (Ctrl+V) or drop a file here" : null,
        };
        card.Clip = new RectangleGeometry(new Rect(0, 0, 124, 152), 18, 18);
        if (_item == null)
        {
            var paste = new Tap(card, PressLook.Dim, "Paste (Ctrl+V)");
            paste.Click += Paste;
            return paste;
        }
        return card;
    }

    private static string DeviceGlyph(string kind) => kind switch
    {
        "iphone" => "\uE8EA",
        "ipad" => "\uE70A",
        "mac" => "\uE7F8",
        "pc" => "\uE7F4",
        "web" => "\uE774",
        "glasses" => "\uE7B3",
        "pod" => "\uE7F5",
        _ => "\uE703",
    };

    private static string ItemGlyph(HoloItem? item) => item switch
    {
        HoloLinkItem => "\uE71B",
        HoloTextItem => "\uE8C1",
        HoloFilesItem => "\uE8A5",
        _ => "\uE896",
    };

    private static string ItemDetail(HoloItem item) => item switch
    {
        HoloLinkItem l => HoloItem.WebUri(l.Url)?.Host ?? "Link",
        HoloTextItem t => $"{t.Value.Length} characters",
        HoloFilesItem { Paths.Count: 1 } f => System.IO.Path.GetExtension(f.Paths[0]).TrimStart('.').ToUpperInvariant() + " file",
        HoloFilesItem f => $"{f.Paths.Count} files",
        _ => "",
    };

    private void Paste()
    {
        if (ClipboardItem() is { } item) { _item = item; _fromClipboard = true; }
        else SetStatus("Your clipboard is empty.", 0.6);
        Render();
    }

    /// Files, a picture (saved as a PNG) or text from the clipboard; null when it holds nothing usable.
    private static HoloItem? ClipboardItem()
    {
        try
        {
            if (Clipboard.ContainsFileDropList()) return HoloItem.Files(Clipboard.GetFileDropList().Cast<string>());
            if (Clipboard.ContainsImage() && Clipboard.GetImage() is { } image)
                return HoloItem.Files(new[] { SavePng(image, "Pasted image") });
            if (Clipboard.ContainsText()) return HoloItem.FromText(Clipboard.GetText());
        }
        catch (Exception e) when (e is COMException or System.IO.IOException or ExternalException) { }
        return null;
    }

    private void PickFiles()
    {
        var dialog = new Microsoft.Win32.OpenFileDialog { Multiselect = true, Title = "Send with Holo Drop" };
        if (dialog.ShowDialog(this) != true || dialog.FileNames.Length == 0) return;
        _item = HoloItem.Files(dialog.FileNames);
        _fromClipboard = false;
        Render();
    }

    /// The monitor the panel is on, with the panel hidden for the shot.
    private async Task ScreenshotAsync()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        Native.GetWindowRect(hwnd, out var r);
        var m = Monitors.At(new PointD((r.Left + r.Right) / 2.0, (r.Top + r.Bottom) / 2.0)) ?? Monitors.Primary();
        if (m == null) return;
        Opacity = 0;
        await Task.Delay(250);
        try
        {
            var b = m.Bounds;
            using var bmp = new System.Drawing.Bitmap(b.Right - b.Left, b.Bottom - b.Top);
            using (var g = System.Drawing.Graphics.FromImage(bmp))
                g.CopyFromScreen(b.Left, b.Top, 0, 0, bmp.Size);
            var path = System.IO.Path.Combine(TempFolder(), $"Screenshot {DateTime.Now:yyyy-MM-dd HH.mm.ss}.png");
            bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
            _item = HoloItem.Files(new[] { path });
            _fromClipboard = false;
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or ExternalException or System.IO.IOException)
        {
            SetStatus("Couldn't take the screenshot.", 1);
        }
        finally
        {
            Opacity = 1;
        }
        Render();
    }

    private static string TempFolder()
    {
        var dir = System.IO.Path.Combine(HoloTemp.DefaultRoot, "HoloDrop-" + Guid.NewGuid().ToString("N"));
        System.IO.Directory.CreateDirectory(dir);
        return dir;
    }

    private static string SavePng(System.Windows.Media.Imaging.BitmapSource image, string name)
    {
        var path = System.IO.Path.Combine(TempFolder(), name + ".png");
        var png = new System.Windows.Media.Imaging.PngBitmapEncoder();
        png.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(image));
        using var f = System.IO.File.Create(path);
        png.Save(f);
        return path;
    }

    private void SetStatus(string text, double opacity = 0.85)
    {
        _status.Text = text;
        _status.Tag = "set";
        _status.Foreground = K.W(opacity);
    }

    private async Task SendAsync(HoloDevice d)
    {
        if (_item is not { } item || _busy) return;
        var action = _override ?? HoloSendDefaults.Action(item);
        _aimed = d.Id;
        _busy = true;
        SetStatus($"Sending to {d.Name}…");
        Render();
        try
        {
            var sent = await _sender.SendDetailedAsync(item, d, action);
            _service.Track(sent, d.Name);
            if (sent.Error is { } err) { SetStatus(err, 1); return; }
            if (sent.Outcome is { } o) Done(HoloDropRecord.LandedLine(d.Name, o.Wire, null));
            else Done($"Sent to {d.Name}.", 2.2);
        }
        finally
        {
            _busy = false;
            if (!_closing) Render();
        }
    }

    private void Done(string line, double seconds = 1.2)
    {
        SetStatus(line, 1);
        var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(seconds) };
        t.Tick += (_, _) => { t.Stop(); CloseOrbit(); };
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
