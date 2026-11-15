using System.Windows;
using System.Windows.Media;
using Jarvis.Core.Ui;

namespace Jarvis.Ui;

/// The Jarvis loader (Trace by default). Every indeterminate spinner in the app is this, never a
/// system progress ring. Animates only while visible, on CompositionTarget.Rendering; never gates
/// on window activation. Slows ×4 when Windows animations are off.
public sealed class JcLoader : FrameworkElement
{
    public static readonly DependencyProperty SizeProperty = DependencyProperty.Register(
        nameof(Size), typeof(double), typeof(JcLoader), new FrameworkPropertyMetadata(20.0, FrameworkPropertyMetadataOptions.AffectsMeasure));

    public static readonly DependencyProperty LoaderStyleProperty = DependencyProperty.Register(
        nameof(LoaderStyle), typeof(JcLoaderStyle), typeof(JcLoader), new FrameworkPropertyMetadata(JcLoaderGeometry.Default, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty ForegroundProperty = DependencyProperty.Register(
        nameof(Foreground), typeof(Brush), typeof(JcLoader), new FrameworkPropertyMetadata(Brushes.White, FrameworkPropertyMetadataOptions.AffectsRender));

    private readonly DateTime _start = DateTime.UtcNow;

    public double Size { get => (double)GetValue(SizeProperty); set => SetValue(SizeProperty, value); }
    public JcLoaderStyle LoaderStyle { get => (JcLoaderStyle)GetValue(LoaderStyleProperty); set => SetValue(LoaderStyleProperty, value); }
    public Brush Foreground { get => (Brush)GetValue(ForegroundProperty); set => SetValue(ForegroundProperty, value); }

    public bool IsAnimating { get; private set; }

    public JcLoader()
    {
        IsVisibleChanged += (_, _) => UpdateAnimation();
        Loaded += (_, _) => UpdateAnimation();
        Unloaded += (_, _) => Stop();
    }

    private void UpdateAnimation()
    {
        if (IsVisible && IsLoaded) Begin(); else Stop();
    }

    private void Begin()
    {
        if (IsAnimating) return;
        IsAnimating = true;
        CompositionTarget.Rendering += OnFrame;
    }

    private void Stop()
    {
        if (!IsAnimating) return;
        IsAnimating = false;
        CompositionTarget.Rendering -= OnFrame;
    }

    private void OnFrame(object? sender, EventArgs e) => InvalidateVisual();

    protected override Size MeasureOverride(Size availableSize) => new(Size, Size);

    protected override void OnRender(DrawingContext dc)
    {
        var period = JcLoaderGeometry.Period(LoaderStyle) * (SystemParameters.ClientAreaAnimation ? 1 : 4);
        var phase = (DateTime.UtcNow - _start).TotalSeconds / period % 1.0;
        var pen = new Pen(Foreground, JcLoaderGeometry.StrokeWidth(Size))
        {
            StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round,
        };
        pen.Freeze();
        foreach (var (points, opacity) in JcLoaderGeometry.Frame(LoaderStyle, Size, phase))
        {
            if (points.Count < 2) continue;
            var geo = new StreamGeometry();
            using (var ctx = geo.Open())
            {
                ctx.BeginFigure(new Point(points[0].X, points[0].Y), false, false);
                for (var i = 1; i < points.Count; i++) ctx.LineTo(new Point(points[i].X, points[i].Y), true, false);
            }
            geo.Freeze();
            dc.PushOpacity(opacity);
            dc.DrawGeometry(null, pen, geo);
            dc.Pop();
        }
    }
}
