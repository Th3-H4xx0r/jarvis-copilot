using System.Windows;
using System.Windows.Media;
using Jarvis.Core.Model;
using Jarvis.Ui;

namespace Jarvis.Voice;

/// The orb: a soft radial-gradient disc that breathes by mood and swells with the mic level.
/// Black and white, with amber while it waits on him and green while it works. Animates only
/// while visible (CompositionTarget.Rendering), never on a timer of its own.
public sealed class OrbView : FrameworkElement
{
    public static readonly DependencyProperty MoodProperty = DependencyProperty.Register(
        nameof(Mood), typeof(OrbMood), typeof(OrbView), new FrameworkPropertyMetadata(OrbMood.Idle, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty LevelProperty = DependencyProperty.Register(
        nameof(Level), typeof(double), typeof(OrbView), new FrameworkPropertyMetadata(0.0));

    private readonly DateTime _start = DateTime.UtcNow;
    private bool _animating;
    private double _shownLevel;

    public OrbMood Mood { get => (OrbMood)GetValue(MoodProperty); set => SetValue(MoodProperty, value); }
    public double Level { get => (double)GetValue(LevelProperty); set => SetValue(LevelProperty, value); }

    public OrbView()
    {
        IsVisibleChanged += (_, _) => Update();
        Loaded += (_, _) => Update();
        Unloaded += (_, _) => Stop();
    }

    private void Update()
    {
        if (IsVisible && IsLoaded) { if (!_animating) { _animating = true; CompositionTarget.Rendering += OnFrame; } }
        else Stop();
    }

    private void Stop()
    {
        if (!_animating) return;
        _animating = false;
        CompositionTarget.Rendering -= OnFrame;
    }

    private void OnFrame(object? sender, EventArgs e) => InvalidateVisual();

    private Color Tint() => ((SolidColorBrush)Th.B(Mood switch
    {
        OrbMood.Waiting => "JcAmber",
        OrbMood.Working => "JcGreen",
        OrbMood.Error => "JcRed",
        _ => "JcAccent",
    })).Color;

    protected override void OnRender(DrawingContext dc)
    {
        var side = Math.Min(ActualWidth, ActualHeight);
        if (side <= 0) return;
        var t = (DateTime.UtcNow - _start).TotalSeconds;
        _shownLevel += (Math.Clamp(Level * 6, 0, 1) - _shownLevel) * 0.25;
        var breathe = Mood == OrbMood.Idle ? 0.02 * Math.Sin(t * 1.6) : 0.05 * Math.Sin(t * 3.2);
        var r = side / 2 * (0.78 + breathe + 0.18 * _shownLevel);
        var c = Tint();
        var brush = new RadialGradientBrush
        {
            GradientOrigin = new Point(0.4, 0.35),
            GradientStops =
            {
                new GradientStop(Color.FromArgb(255, c.R, c.G, c.B), 0),
                new GradientStop(Color.FromArgb(150, c.R, c.G, c.B), 0.55),
                new GradientStop(Color.FromArgb(0, c.R, c.G, c.B), 1),
            },
        };
        brush.Freeze();
        dc.DrawEllipse(brush, null, new Point(ActualWidth / 2, ActualHeight / 2), r, r);
    }
}

/// The reply with karaoke: spoken words full white, the rest dim.
public sealed class KaraokeText : System.Windows.Controls.TextBlock
{
    public KaraokeText()
    {
        TextWrapping = TextWrapping.Wrap;
        FontSize = 15;
        LineHeight = 21;
    }

    public void Show(string text, int spokenWords)
    {
        Inlines.Clear();
        var words = text.Split(' ', StringSplitOptions.None);
        var spoken = string.Join(' ', words.Take(spokenWords));
        var rest = string.Join(' ', words.Skip(spokenWords));
        Inlines.Add(new System.Windows.Documents.Run(spoken) { Foreground = Th.B("JcText") });
        if (rest.Length > 0) Inlines.Add(new System.Windows.Documents.Run((spoken.Length > 0 ? " " : "") + rest) { Foreground = Th.B("JcTextFaint") });
    }
}
