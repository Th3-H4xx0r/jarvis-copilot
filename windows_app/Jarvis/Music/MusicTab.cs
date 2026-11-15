using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Jarvis.Core.Music;
using Jarvis.Ui;

namespace Jarvis.Music;

/// The island's Music tab: artwork, title and artist, an anchored progress bar (redrawn only
/// while the tab is visible), and previous / play-pause / next.
public sealed class MusicTab : Border
{
    private readonly MediaSessions _media;
    private readonly Image _art = new() { Width = 56, Height = 56, Stretch = Stretch.UniformToFill };
    private readonly TextBlock _title = Th.Text("Nothing playing", 14, bold: true);
    private readonly TextBlock _artist = Th.Text("", 12, "JcTextDim");
    private readonly ProgressBar _bar = new() { Height = 3, Minimum = 0, Maximum = 1, Foreground = Th.B("JcText"), Background = Th.B("JcButton"), BorderThickness = new Thickness(0) };
    private readonly TextBlock _times = Th.Text("", 11, "JcTextFaint");
    private readonly Button _play;
    private readonly DispatcherTimer _tick = new() { Interval = TimeSpan.FromSeconds(0.5) };

    public MusicTab(MediaSessions media)
    {
        _media = media;
        _play = Th.Icon("", "Play / pause", () => _ = _media.PlayPauseAsync(), 34);
        var controls = Th.Row(10, Th.Icon("", "Previous", () => _ = _media.PreviousAsync(), 30), _play,
            Th.Icon("", "Next", () => _ = _media.NextAsync(), 30));
        controls.HorizontalAlignment = HorizontalAlignment.Center;
        var artBox = new Border { CornerRadius = new CornerRadius(8), ClipToBounds = true, Child = _art, Background = Th.B("JcButton") };
        var head = Th.Row(12, artBox, Th.Column(2, _title, _artist));
        Child = Th.Column(12, head, Th.Column(4, _bar, _times), controls);
        Margin = new Thickness(0, 10, 0, 0);
        _media.Changed += () => Dispatcher.BeginInvoke(Render);
        _tick.Tick += (_, _) => Progress();
        IsVisibleChanged += (_, _) => { if (IsVisible) { Render(); _tick.Start(); } else _tick.Stop(); };
    }

    private void Render()
    {
        var now = _media.Now;
        _title.Text = now is { Title.Length: > 0 } ? now.Title : "Nothing playing";
        _artist.Text = now == null ? "" : string.Join(" · ", new[] { now.Artist, now.App }.Where(s => s.Length > 0));
        ((TextBlock)_play.Content).Text = now?.IsPlaying == true ? "" : "";
        _art.Source = Art(_media.Artwork);
        Progress();
    }

    private void Progress()
    {
        if (_media.Now is not { } n || n.Duration <= 0) { _bar.Value = 0; _times.Text = ""; return; }
        var pos = n.PositionAt(DateTimeOffset.UtcNow);
        _bar.Value = pos / n.Duration;
        _times.Text = $"{Fmt(pos)} / {Fmt(n.Duration)}";
    }

    private static string Fmt(double s) => TimeSpan.FromSeconds(s).ToString(s >= 3600 ? @"h\:mm\:ss" : @"m\:ss");

    private static ImageSource? Art(byte[]? bytes)
    {
        if (bytes == null) return null;
        try
        {
            var img = new BitmapImage();
            img.BeginInit();
            img.StreamSource = new System.IO.MemoryStream(bytes);
            img.CacheOption = BitmapCacheOption.OnLoad;
            img.EndInit();
            img.Freeze();
            return img;
        }
        catch (Exception e) when (e is NotSupportedException or System.IO.IOException) { return null; }
    }
}
