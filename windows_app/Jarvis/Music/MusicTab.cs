using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;
using Jarvis.Core.Island;
using Jarvis.Core.Music;
using Jarvis.Ui;

namespace Jarvis.Music;

/// What's playing, laid out like Apple's Now Playing (the Mac's NowPlayingCard): the cover with
/// title and artist (a live waveform on the right), a thin progress bar between elapsed and
/// remaining time, then the transport in the middle with shuffle and repeat on the left and volume
/// on the right. Every row is pinned to IslandLayout's Music sizes, so the island is exactly as
/// tall as this. Its 1 s clock and 10 fps bars run only while the tab is on screen.
public sealed class MusicTab : Border
{
    private readonly MediaSessions _media;
    private readonly Border _art;
    private readonly Image _artImage = new() { Stretch = Stretch.UniformToFill };
    private readonly Grid _artPlaceholder = new();
    private readonly TextBlock _title = K.T("Not Playing", 14, FontWeights.SemiBold);
    private readonly TextBlock _artist = K.T("Spotify, a browser or any media app", 12, null, K.W(0.55));
    private readonly MusicBars _bars = new();
    private readonly TextBlock _elapsed = K.T("--:--", 11, FontWeights.Medium, K.W(0.55));
    private readonly TextBlock _left = K.T("--:--", 11, FontWeights.Medium, K.W(0.55));
    private readonly ThinBar _progress = new();
    private readonly ThinBar _volume = new();
    private readonly IconView _playIcon = new(Sym.Play, 26, K.W(1));
    private readonly Tap _shuffle, _repeat;
    private readonly Grid _controls;
    private readonly DispatcherTimer _tick = new() { Interval = TimeSpan.FromSeconds(1) };
    private double? _scrub;

    public MusicTab(MediaSessions media)
    {
        _media = media;
        // ── the cover, title and artist ──
        _artPlaceholder.Children.Add(new Rectangle { Fill = K.W(0.08) });
        _artPlaceholder.Children.Add(new IconView(Sym.MusicNote, 22, K.W(0.55)));
        var artInner = new Grid();
        artInner.Children.Add(_artPlaceholder);
        artInner.Children.Add(_artImage);
        _art = new Border
        {
            Width = IslandLayout.MusicArtwork, Height = IslandLayout.MusicArtwork, CornerRadius = new CornerRadius(10),
            Child = artInner, ClipToBounds = true,
            Effect = new DropShadowEffect { Color = Colors.Black, Opacity = 0.4, BlurRadius = 8, ShadowDepth = 2, Direction = 270 },
        };
        artInner.Clip = new RectangleGeometry(new Rect(0, 0, IslandLayout.MusicArtwork, IslandLayout.MusicArtwork), 10, 10);
        var titles = K.V(2, _title, _artist);
        var head = new DockPanel { Height = IslandLayout.MusicArtwork };
        DockPanel.SetDock(_art, Dock.Left);
        head.Children.Add(_art);
        _bars.Width = 18;
        _bars.Height = 16;
        DockPanel.SetDock(_bars, Dock.Right);
        head.Children.Add(_bars);
        titles.Margin = new Thickness(12, 0, 8, 0);
        titles.VerticalAlignment = VerticalAlignment.Center;
        head.Children.Add(titles);

        // ── progress ──
        System.Windows.Documents.Typography.SetNumeralAlignment(_elapsed, FontNumeralAlignment.Tabular);
        System.Windows.Documents.Typography.SetNumeralAlignment(_left, FontNumeralAlignment.Tabular);
        _elapsed.Width = 44;
        _left.Width = 44;
        _left.TextAlignment = TextAlignment.Right;
        var progress = new DockPanel { Height = IslandLayout.MusicProgress };
        DockPanel.SetDock(_elapsed, Dock.Left);
        DockPanel.SetDock(_left, Dock.Right);
        progress.Children.Add(_elapsed);
        progress.Children.Add(_left);
        _progress.Margin = new Thickness(10, 0, 10, 0);
        progress.Children.Add(_progress);
        _progress.Changed += (f, done) =>
        {
            var d = _media.Now?.Duration ?? 0;
            if (d <= 0) return;
            if (done) { _ = _media.SeekAsync(f * d); _scrub = null; }
            else _scrub = f * d;
            Progress();
        };

        // ── controls ──
        _shuffle = Toggle(Sym.Shuffle, "Shuffle", () => _ = _media.SetShuffleAsync(!_media.Shuffle));
        _repeat = Toggle(Sym.Repeat, "Repeat", () => _ = _media.SetRepeatAsync(!_media.Repeating));
        _volume.Width = 84;
        _volume.Value = MediaSessions.Volume / 100;
        _volume.Changed += (f, _) => MediaSessions.Volume = Math.Round(f * 100);
        var leftRow = K.H(6, _shuffle, _repeat);
        var volRow = K.H(6, new IconView(Sym.SpeakerFill, 11, K.W(0.55)), _volume, new IconView(Sym.SpeakerWave, 12, K.W(0.55)));
        volRow.ToolTip = "Volume";
        var transport = K.H(26,
            Transport(new IconView(Sym.Backward, 22, K.W(1)), "Previous", () => _ = _media.PreviousAsync()),
            Transport(_playIcon, "Play", () => _ = _media.PlayPauseAsync()),
            Transport(new IconView(Sym.Forward, 22, K.W(1)), "Next", () => _ = _media.NextAsync()));
        transport.HorizontalAlignment = HorizontalAlignment.Center;
        _controls = new Grid { Height = IslandLayout.MusicControls };
        _controls.Children.Add(K.Spread(leftRow, volRow));
        _controls.Children.Add(transport);

        var col = new StackPanel();
        K.Add(col, head, 0);
        K.Add(col, progress, IslandLayout.MusicGap);
        K.Add(col, _controls, IslandLayout.MusicGap);
        Child = col;

        _media.Changed += () => Dispatcher.BeginInvoke(Render);
        _tick.Tick += (_, _) => Progress();
        IsVisibleChanged += (_, _) =>
        {
            if (IsVisible) { _volume.Value = MediaSessions.Volume / 100; Render(); _tick.Start(); }
            else _tick.Stop();
            _bars.Running = IsVisible && _media.Now?.IsPlaying == true;
        };
    }

    private static Tap Transport(IconView icon, string tip, Action click)
    {
        var host = new Grid { Width = 34, Height = IslandLayout.MusicControls, Background = Brushes.Transparent };
        host.Children.Add(icon);
        var t = new Tap(host, PressLook.Shrink, tip);
        t.Click += click;
        return t;
    }

    private static Tap Toggle(Sym icon, string tip, Action click)
    {
        var host = new Grid { Width = 28, Height = 24 };
        host.Children.Add(new Border { CornerRadius = new CornerRadius(7) });
        host.Children.Add(new IconView(icon, 14, K.W(0.55)));
        var t = new Tap(host, PressLook.Shrink, tip);
        t.Click += click;
        return t;
    }

    private static void SetToggle(Tap t, bool on)
    {
        var host = (Grid)t.Child;
        ((Border)host.Children[0]).Background = on ? K.A("JcAccent", 0.18) : Brushes.Transparent;
        ((IconView)host.Children[1]).Foreground = on ? K.A("JcAccent") : K.W(0.55);
    }

    private void Render()
    {
        var now = _media.Now;
        _title.Text = now is { Title.Length: > 0 } ? now.Title : "Not Playing";
        _artist.Text = now == null ? "Spotify, a browser or any media app" : now.Artist.Length > 0 ? now.Artist : now.Album.Length > 0 ? now.Album : now.App;
        _artImage.Source = Art(_media.Artwork);
        _artPlaceholder.Visibility = _artImage.Source == null ? Visibility.Visible : Visibility.Collapsed;
        _playIcon.Set(now?.IsPlaying == true ? Sym.Pause : Sym.Play);
        _bars.Visibility = now == null ? Visibility.Hidden : Visibility.Visible;
        _bars.Playing = now?.IsPlaying == true;
        _bars.Running = IsVisible && now?.IsPlaying == true;
        SetToggle(_shuffle, _media.Shuffle);
        SetToggle(_repeat, _media.Repeating);
        _controls.IsEnabled = now != null;
        _controls.Opacity = now == null ? 0.4 : 1;
        Progress();
    }

    private void Progress()
    {
        var now = _media.Now;
        var duration = now?.Duration ?? 0;
        var position = _scrub ?? now?.PositionAt(DateTimeOffset.UtcNow) ?? 0;
        _elapsed.Text = now == null ? "--:--" : NowPlaying.Clock(position);
        _left.Text = now == null ? "--:--" : NowPlaying.Remaining(duration, position);
        _progress.Enabled = now != null && duration > 0;
        if (!_progress.Dragging) _progress.Value = duration > 0 ? position / duration : 0;
    }

    private static ImageSource? Art(byte[]? bytes)
    {
        if (bytes == null) return null;
        try
        {
            var img = new BitmapImage();
            img.BeginInit();
            img.StreamSource = new System.IO.MemoryStream(bytes);
            img.CacheOption = BitmapCacheOption.OnLoad;
            img.DecodePixelWidth = 112;
            img.EndInit();
            img.Freeze();
            return img;
        }
        catch (Exception e) when (e is NotSupportedException or System.IO.IOException) { return null; }
    }
}

/// Apple's thin bar: a faint track with a white fill that thickens while you hover or drag it.
/// Dragging reports the fraction, and `done` on release.
internal sealed class ThinBar : FrameworkElement
{
    private bool _hover;

    public ThinBar()
    {
        Height = 16;
        Cursor = Cursors.Hand;
        MouseEnter += (_, _) => { _hover = true; InvalidateVisual(); };
        MouseLeave += (_, _) => { _hover = false; InvalidateVisual(); };
        MouseLeftButtonDown += (_, e) =>
        {
            if (!Enabled) return;
            Dragging = true;
            CaptureMouse();
            Report(e.GetPosition(this).X, false);
            e.Handled = true;
        };
        MouseMove += (_, e) => { if (Dragging) Report(e.GetPosition(this).X, false); };
        MouseLeftButtonUp += (_, e) =>
        {
            if (!Dragging) return;
            Dragging = false;
            ReleaseMouseCapture();
            Report(e.GetPosition(this).X, true);
        };
    }

    private double _value;
    public double Value { get => _value; set { _value = Math.Clamp(value, 0, 1); InvalidateVisual(); } }
    public bool Enabled { get; set; } = true;
    public bool Dragging { get; private set; }
    public event Action<double, bool>? Changed;

    private void Report(double x, bool done)
    {
        Value = ActualWidth > 0 ? x / ActualWidth : 0;
        Changed?.Invoke(Value, done);
    }

    protected override void OnRender(DrawingContext dc)
    {
        // A transparent hit area the whole height, the bar centred in it.
        dc.DrawRectangle(Brushes.Transparent, null, new Rect(0, 0, ActualWidth, ActualHeight));
        var thick = Enabled && (_hover || Dragging) ? 7 : 4;
        var y = (ActualHeight - thick) / 2;
        dc.DrawRoundedRectangle(K.W(0.18), null, new Rect(0, y, ActualWidth, thick), thick / 2.0, thick / 2.0);
        var w = ActualWidth * _value;
        if (w > 0) dc.DrawRoundedRectangle(K.W(Enabled ? 0.92 : 0.35), null, new Rect(0, y, w, thick), thick / 2.0, thick / 2.0);
    }
}

/// The live waveform Apple shows next to what's playing: four bars that move while it plays (10
/// fps, only while visible) and settle when it pauses.
internal sealed class MusicBars : FrameworkElement
{
    private readonly DispatcherTimer _timer = new(DispatcherPriority.Render) { Interval = TimeSpan.FromSeconds(0.1) };
    private readonly DateTime _start = DateTime.UtcNow;
    private bool _running;

    public MusicBars() => _timer.Tick += (_, _) => InvalidateVisual();

    public bool Playing { get; set; }

    public bool Running
    {
        get => _running;
        set
        {
            _running = value;
            if (value) _timer.Start(); else _timer.Stop();
            InvalidateVisual();
        }
    }

    protected override void OnRender(DrawingContext dc)
    {
        var t = (DateTime.UtcNow - _start).TotalSeconds;
        for (var i = 0; i < 4; i++)
        {
            var h = Playing ? 4 + 12 * Math.Abs(Math.Sin(t * (2.2 + i * 0.65) + i)) : 3;
            var x = i * 5.5;
            dc.DrawRoundedRectangle(K.A("JcAccent"), null, new Rect(x, (ActualHeight - h) / 2, 3, h), 1.5, 1.5);
        }
    }
}
