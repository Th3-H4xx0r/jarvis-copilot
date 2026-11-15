using System.Diagnostics;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;
using Jarvis.Core.Model;
using Jarvis.Core.Ui;
using Jarvis.Ui;

namespace Jarvis.Orb;

/// The Jarvis orb, as the Mac draws it (OrbView / LiquidGlassOrb): the liquid-glass shader on the
/// GPU, a soft ring and breathing pulse for the mood (never a recolour), a beat with the music.
/// Redrawn only as often as OrbMotion says — never while idle (a still frame), 12 fps while agents
/// work or wait, 30 fps listening, the display's rate on the voice stage — and not at all while
/// it's off screen. `Size` is the visible sphere; the shader surface around it is Size / 0.53.
public sealed class JarvisOrb : FrameworkElement
{
    private static readonly Dictionary<int, BitmapSource> Stills = new();

    private readonly VisualCollection _kids;
    private readonly Ellipse _halo = new() { IsHitTestVisible = false };
    private readonly Rectangle _surface = new() { IsHitTestVisible = false };
    private readonly Ellipse _ring = new() { IsHitTestVisible = false, Visibility = Visibility.Collapsed };
    private readonly ScaleTransform _scale = new(1, 1);
    private readonly OrbEffect? _effect;
    private readonly Stopwatch _clock = Stopwatch.StartNew();
    private DispatcherTimer? _timer;
    private bool _rendering;
    private double _shownLevel;
    private OrbMood _mood = OrbMood.Idle;
    private bool _listening, _dancing;

    public JarvisOrb(double size, bool stage = false)
    {
        Size = size;
        Stage = stage;
        _kids = new VisualCollection(this) { _halo, _surface, _ring };
        _effect = OrbEffect.TryCreate();
        if (_effect != null)
        {
            _surface.Fill = Brushes.White;
            _surface.Effect = _effect;
        }
        _halo.Visibility = Visibility.Collapsed;
        RenderTransformOrigin = new Point(0.5, 0.5);
        RenderTransform = _scale;
        IsHitTestVisible = false;
        Loaded += (_, _) => Restart();
        Unloaded += (_, _) => StopClock();
        IsVisibleChanged += (_, _) => Restart();
    }

    /// The visible sphere's diameter (DIPs).
    public double Size { get; }
    /// The voice stage's orb: the display's rate while shown, swelling with the voice, no ring.
    public bool Stage { get; }

    public OrbMood Mood
    {
        get => _mood;
        set { if (_mood == value) return; _mood = value; Restart(); }
    }

    /// The tab row's orb while Voice is open (pulses, no ring, 30 fps).
    public bool Listening
    {
        get => _listening;
        set { if (_listening == value) return; _listening = value; Restart(); }
    }

    /// Music is playing: the orb moves with a soft beat.
    public bool Dancing
    {
        get => _dancing;
        set { if (_dancing == value) return; _dancing = value; Restart(); }
    }

    /// The voice level (0…1) the stage orb swells with.
    public double Level { get; set; }

    /// The stage's soft halo behind the orb (JcAccent.deep at 18%, 30% while talking).
    public void SetHalo(bool on, bool active)
    {
        _halo.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        if (!on) return;
        _halo.Fill = K.A("JcAccent", (active ? 0.30 : 0.18) * 0.75);
        _halo.Effect ??= new BlurEffect { Radius = Size * 0.6, KernelType = KernelType.Gaussian };
    }

    protected override int VisualChildrenCount => _kids.Count;
    protected override Visual GetVisualChild(int index) => _kids[index];

    protected override Size MeasureOverride(Size availableSize)
    {
        foreach (UIElement k in _kids) k.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        return new Size(Size, Size);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        var surf = Size / OrbMotion.SphereShare;
        var c = new Point(finalSize.Width / 2, finalSize.Height / 2);
        _surface.Arrange(new Rect(c.X - surf / 2, c.Y - surf / 2, surf, surf));
        var ring = Size * 1.08;
        _ring.Arrange(new Rect(c.X - ring / 2, c.Y - ring / 2, ring, ring));
        var halo = Size * 1.5;
        _halo.Arrange(new Rect(c.X - halo / 2, c.Y - halo / 2, halo, halo));
        var dpi = VisualTreeHelper.GetDpi(this).DpiScaleX;
        if (_effect != null) _effect.Surface = surf * dpi;
        else if (_surface.Fill == null) _surface.Fill = new ImageBrush(Still((int)Math.Ceiling(surf * dpi)));
        return finalSize;
    }

    private static BitmapSource Still(int px)
    {
        px = Math.Clamp(px, 8, 512);
        if (Stills.TryGetValue(px, out var b)) return b;
        var bgra = OrbShader.RenderBgra(px, 0);
        b = BitmapSource.Create(px, px, 96, 96, PixelFormats.Pbgra32, null, bgra, px * 4);
        b.Freeze();
        Stills[px] = b;
        return b;
    }

    /// Seconds between frames, or null for a still frame.
    private double? Interval()
    {
        if (_effect == null || !SystemParameters.ClientAreaAnimation) return null;
        if (Stage) return 0;     // every display frame
        return OrbMotion.Interval(_mood, _listening, _dancing);
    }

    private void Restart()
    {
        StopClock();
        UpdateRing();
        Frame();
        if (!IsVisible || !IsLoaded) return;
        switch (Interval())
        {
            case null: break;
            case 0:
                _rendering = true;
                CompositionTarget.Rendering += OnRendering;
                break;
            case { } s:
                _timer = new DispatcherTimer(DispatcherPriority.Render) { Interval = TimeSpan.FromSeconds(s) };
                _timer.Tick += (_, _) => Frame();
                _timer.Start();
                break;
        }
    }

    private void StopClock()
    {
        _timer?.Stop();
        _timer = null;
        if (_rendering) CompositionTarget.Rendering -= OnRendering;
        _rendering = false;
    }

    private void OnRendering(object? sender, EventArgs e) => Frame();

    private void UpdateRing()
    {
        var key = Stage || _listening ? null : OrbMotion.TintKey(_mood);
        if (key == null)
        {
            _ring.Visibility = Visibility.Collapsed;
            _ring.Effect = null;
            return;
        }
        _ring.Visibility = Visibility.Visible;
        _ring.StrokeThickness = OrbMotion.RingWidth(Size);
        _ring.Stroke = K.A(key);
        _ring.Effect = new DropShadowEffect { Color = K.C(key), Opacity = 0.7, BlurRadius = Size * 0.36, ShadowDepth = 0 };
    }

    private void Frame()
    {
        var elapsed = _clock.Elapsed.TotalSeconds;
        if (_effect != null && Interval() != null) _effect.Clock = OrbMotion.ShaderTime(elapsed);
        double scale;
        if (Stage)
        {
            var target = Math.Clamp(Level * 4, 0, 1);
            _shownLevel += (target - _shownLevel) * (target > _shownLevel ? 0.35 : 0.10);
            scale = OrbMotion.SpeechScale(_shownLevel);
        }
        else
        {
            var pulses = OrbMotion.Pulses(_mood, _listening);
            var pulse = pulses ? OrbMotion.Pulse(elapsed, _mood) : 0;
            var beat = _dancing ? OrbMotion.Beat(elapsed) : 0;
            scale = OrbMotion.Scale(pulses, pulse, beat);
            if (_ring.Visibility == Visibility.Visible) _ring.Opacity = OrbMotion.RingOpacity(pulse);
        }
        _scale.ScaleX = scale;
        _scale.ScaleY = scale;
    }
}
