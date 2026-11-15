using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Jarvis.Core.Gaming;
using Jarvis.Core.Holo;
using Jarvis.Platform;
using Jarvis.Ui;

namespace Jarvis.HoloDrop;

/// The arrival card: a picture or video frame fills it edge to edge (the hero), with small round
/// 28 px icon buttons for Open, Save, Copy and Dismiss over its bottom edge; links and text get a
/// compact title row. Placed at the drop's spot on the main monitor (else bottom-right), never
/// activated, gone after 14 s unless the pointer is on it. Shown only through the gate.
public sealed class HoloArrivalCard : NoActivateWindow
{
    private readonly HoloArrival _card;
    private readonly HoloDropService _service;
    private readonly DispatcherTimer _stay = new() { Interval = HoloDropService.CardStays };

    public HoloArrivalCard(HoloArrival card, HoloDropService service)
    {
        _card = card;
        _service = service;
        Title = "Holo Drop";
        Background = Brushes.Transparent;
        SizeToContent = SizeToContent.WidthAndHeight;
        _stay.Tick += (_, _) => { if (!IsMouseOver) Close(); };
        MouseLeave += (_, _) => { _stay.Stop(); _stay.Start(); };
        card.Changed += () => Dispatcher.BeginInvoke(Build);
        Closed += (_, _) => _stay.Stop();
        Build();
    }

    public void Present()
    {
        Show();
        UpdateLayout();
        Place();
        _stay.Start();
    }

    private void Build()
    {
        var buttons = Th.Row(6,
            Th.Icon("", "Open", () => _service.OpenFromCard(_card)),
            Th.Icon("", _card.SavedFile != null ? "Saved" : "Save", () => _service.SaveFromCard(_card)),
            Th.Icon("", _card.Copied ? "Copied" : "Copy", () => _service.CopyFromCard(_card)),
            Th.Icon("", "Dismiss", Close));
        buttons.Margin = new Thickness(8);
        var from = Th.Text(_card.FromLine(DateTimeOffset.Now), 11, "JcTextDim");

        if (_card.IsPicture && _card.LocalFile is { } file && Picture(file) is { } pic)
        {
            var (w, h) = HoloCardLayout.HeroSize(pic.PixelHeight > 0 ? (double)pic.PixelWidth / pic.PixelHeight : 4.0 / 3);
            var hero = new Image { Source = pic, Stretch = Stretch.UniformToFill, Width = w, Height = h };
            buttons.VerticalAlignment = VerticalAlignment.Bottom;
            buttons.HorizontalAlignment = HorizontalAlignment.Right;
            from.VerticalAlignment = VerticalAlignment.Top;
            from.Margin = new Thickness(10, 8, 0, 0);
            Content = new Border
            {
                CornerRadius = new CornerRadius(14),
                ClipToBounds = true,
                Background = Th.B("JcBackground"),
                Child = new Grid { Children = { hero, from, buttons } },
            };
            return;
        }

        var title = _card.State switch
        {
            HoloArrivalState.Receiving => "Receiving…",
            HoloArrivalState.Failed => _card.Error ?? "Didn't arrive",
            _ => _card.Drop.DisplayName,
        };
        var body = new StackPanel { Width = HoloCardLayout.CompactWidth };
        var head = Th.Row(8, _card.State == HoloArrivalState.Receiving ? new JcLoader { Size = 14 } : Th.Dot("JcAccent"), Th.Text(title, 13, bold: true));
        body.Children.Add(head);
        if (_card.Drop.Kind == HoloKind.Text) body.Children.Add(Th.Text(_card.Drop.Text, 12, "JcTextDim", wrap: true));
        if (_card.Note is { } note) body.Children.Add(Th.Text(note, 11, "JcTextFaint", wrap: true));
        body.Children.Add(from);
        buttons.Margin = new Thickness(0, 8, 0, 0);
        body.Children.Add(buttons);
        Content = new Border { CornerRadius = new CornerRadius(14), Background = Th.B("JcBackground"), Padding = new Thickness(12), Child = body };
    }

    private static BitmapSource? Picture(string path)
    {
        try
        {
            var img = new BitmapImage();
            img.BeginInit();
            img.UriSource = new Uri(path);
            img.DecodePixelWidth = 840;
            img.CacheOption = BitmapCacheOption.OnLoad;
            img.EndInit();
            img.Freeze();
            return img;
        }
        catch (Exception e) when (e is NotSupportedException or System.IO.IOException or UriFormatException) { return null; }
    }

    private void Place()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (Monitors.Primary() is not { } m || hwnd == IntPtr.Zero) return;
        var scale = Monitors.Scale(m.Handle);
        Monitors.Place(hwnd, HoloCardLayout.Frame(_card.Drop.Position, m.Work, (int)(ActualWidth * scale), (int)(ActualHeight * scale)));
    }
}

/// Cards and the landed toast, marshalled to the Dispatcher (the service calls from any thread,
/// already through the gate).
public sealed class HoloCards : IHoloCards
{
    private readonly Func<HoloDropService?> _service;

    public HoloCards(Func<HoloDropService?> service) => _service = service;

    public void Show(HoloArrival card) => Application.Current.Dispatcher.Invoke(() =>
    {
        if (_service() is { } s) new HoloArrivalCard(card, s).Present();
    });

    public void Toast(string line, bool failed) => Application.Current.Dispatcher.Invoke(() => new HoloToast(line, failed).Present());
}

/// A one-line pill under the island: "Landed on iPhone", gone after 3 s.
public sealed class HoloToast : NoActivateWindow
{
    public HoloToast(string line, bool failed)
    {
        Background = Brushes.Transparent;
        SizeToContent = SizeToContent.WidthAndHeight;
        Content = new Border
        {
            CornerRadius = new CornerRadius(14),
            Background = Th.B("JcBackground"),
            Padding = new Thickness(14, 8, 14, 8),
            Child = Th.Text(line, 12, failed ? "JcRed" : "JcText"),
        };
        var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
        t.Tick += (_, _) => { t.Stop(); Close(); };
        t.Start();
    }

    public void Present()
    {
        Show();
        UpdateLayout();
        var hwnd = new WindowInteropHelper(this).Handle;
        if (Monitors.Primary() is not { } m || hwnd == IntPtr.Zero) return;
        var scale = Monitors.Scale(m.Handle);
        int w = (int)(ActualWidth * scale), h = (int)(ActualHeight * scale);
        var left = m.Bounds.Left + (m.Bounds.Width - w) / 2;
        var top = m.Bounds.Top + (int)(44 * scale);
        Monitors.Place(hwnd, new RectI(left, top, left + w, top + h));
    }
}
