using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using Jarvis.Core.Stats;
using Jarvis.Ui;

namespace Jarvis.Stats;

/// The last hour of every reading at 1 Hz, shared by every chart on the dashboard.
public sealed class SeriesBuffer
{
    private const int Keep = 3600;
    private readonly Dictionary<string, Queue<(double T, double V)>> _series = new();

    public void Add(StatsSample s)
    {
        foreach (var (k, v) in s.R)
        {
            if (!_series.TryGetValue(k, out var q)) _series[k] = q = new Queue<(double, double)>();
            q.Enqueue((s.T, v));
            while (q.Count > Keep) q.Dequeue();
        }
    }

    /// Fills a reading's past from the server's history (the dashboard just opened).
    public void Seed(string key, IEnumerable<(double T, double V)> points)
    {
        if (_series.TryGetValue(key, out var q) && q.Count > 30) return;
        var merged = new Queue<(double, double)>(points.Concat(q ?? new Queue<(double, double)>()).OrderBy(p => p.T).TakeLast(Keep));
        _series[key] = merged;
    }

    public IReadOnlyList<(double T, double V)> Window(string key, double seconds, double now) =>
        _series.TryGetValue(key, out var q) ? q.Where(p => now - p.T <= seconds).ToList() : Array.Empty<(double, double)>();
}

/// What every widget view gets each second.
public sealed record WidgetFrame(StatsSample Sample, IReadOnlySet<string> Estimated, bool DriverOff, SeriesBuffer Series,
    IReadOnlyDictionary<string, string> Labels, IReadOnlyDictionary<string, string> Units);

/// One widget drawn in look B: a glass panel with the widget's label, then its kind's body.
public abstract class WidgetView : Border
{
    protected readonly Widget W;
    protected readonly TextBlock Label;

    protected WidgetView(Widget w)
    {
        W = w;
        Background = Th.B("JcStatsGlass");
        BorderBrush = Th.B("JcStatsHairline");
        BorderThickness = new Thickness(1);
        CornerRadius = new CornerRadius(18);
        Padding = new Thickness(18, 16, 18, 16);
        Margin = new Thickness(7);
        ClipToBounds = true;
        Label = Text("", 12.5, "JcStatsLabel", FontWeights.Medium);
    }

    public Widget Widget => W;

    public abstract void Update(WidgetFrame f);

    public static WidgetView For(Widget w) => w.Kind switch
    {
        "hero" => new HeroView(w),
        "chart" => new ChartView(w),
        "bars" => new BarsView(w),
        "ring" => new RingView(w),
        "sparkline" => new SparkView(w),
        "text" => new TextView(w),
        "session" or "moments" => new ListView(w),
        _ => new NumberView(w),
    };

    protected static TextBlock Text(string s, double size, string brush, FontWeight? weight = null) => new()
    {
        Text = s, FontSize = size, Foreground = Th.B(brush), FontWeight = weight ?? FontWeights.Normal,
        FontFamily = (FontFamily)Application.Current.FindResource("JcFont"), TextTrimming = TextTrimming.CharacterEllipsis,
    };

    protected string Title(WidgetFrame f) => W.Style.Label ?? (W.Readings.Count > 0 && f.Labels.TryGetValue(W.Readings[0], out var l) ? l : W.Kind);

    protected static string Unit(WidgetFrame f, string key) => f.Units.TryGetValue(key, out var u) ? u : "";

    protected string Value(WidgetFrame f, string key) => WidgetText.Value(key, f.Sample.R, W.Style.Decimals, f.DriverOff);

    protected static bool Has(WidgetFrame f, string key) => f.Sample.R.ContainsKey(key);

    protected Brush Tint(WidgetFrame f, string key) =>
        WidgetText.Level(f.Sample.R.TryGetValue(key, out var v) ? v : null, W.Style) switch
        {
            "crit" => Th.B("JcSysRed"),
            "warn" => Th.B("JcAmber"),
            _ => Th.B("JcText"),
        };

    protected Brush LineBrush(int i)
    {
        if (i == 0 && W.Style.Color is { } c)
            try { return new SolidColorBrush((Color)ColorConverter.ConvertFromString(c)); } catch (FormatException) { }
        return Th.B(i switch { 0 => "JcStatsLine", 1 => "JcStatsSecondLine", _ => "JcStatsThirdLine" });
    }

    /// A smooth line (and optional area) through the points, scaled into w×h.
    protected static (Geometry Line, Geometry Area) Curve(IReadOnlyList<(double T, double V)> pts, double w, double h, double min, double max, double t0, double t1)
    {
        var line = new StreamGeometry();
        var area = new StreamGeometry();
        if (pts.Count < 2 || w <= 0 || h <= 0) return (line, area);
        var span = Math.Max(1e-6, max - min);
        var tspan = Math.Max(1, t1 - t0);
        Point P((double T, double V) p) => new((p.T - t0) / tspan * w, h - (Math.Clamp(p.V, min, max) - min) / span * h);
        using (var g = line.Open())
        {
            g.BeginFigure(P(pts[0]), false, false);
            for (var i = 1; i < pts.Count; i++)
            {
                var a = P(pts[i - 1]);
                var b = P(pts[i]);
                var mx = (a.X + b.X) / 2;
                g.BezierTo(new Point(mx, a.Y), new Point(mx, b.Y), b, true, false);
            }
        }
        using (var g = area.Open())
        {
            g.BeginFigure(new Point(P(pts[0]).X, h), true, true);
            g.LineTo(P(pts[0]), false, false);
            for (var i = 1; i < pts.Count; i++)
            {
                var a = P(pts[i - 1]);
                var b = P(pts[i]);
                var mx = (a.X + b.X) / 2;
                g.BezierTo(new Point(mx, a.Y), new Point(mx, b.Y), b, false, false);
            }
            g.LineTo(new Point(P(pts[^1]).X, h), false, false);
        }
        line.Freeze();
        area.Freeze();
        return (line, area);
    }

    protected static (double Min, double Max) Range(string key, IEnumerable<double> values)
    {
        if (key.EndsWith("load") || key == "disk.used") return (0, 100);
        var list = values.ToList();
        if (list.Count == 0) return (0, 1);
        var max = list.Max();
        var min = key.StartsWith("fps") || key.StartsWith("power") ? 0 : Math.Min(list.Min(), max * 0.8);
        return (min, max <= min ? min + 1 : max * 1.08);
    }

    protected string Est(WidgetFrame f, string key) => f.Estimated.Contains(key) ? "  est." : "";
}

/// Big number + unit, a meta row, a glowing area chart along the bottom (look B's hero).
public sealed class HeroView : WidgetView
{
    private readonly TextBlock _value = Text("", 56, "JcText", FontWeights.SemiBold);
    private readonly TextBlock _unit = Text("", 20, "JcStatsLabel", FontWeights.Medium);
    // His ask: the temperature big, right next to the usage ("96% · 67°C").
    private readonly TextBlock _dot = Text(" · ", 56, "JcStatsLabel", FontWeights.Light);
    private readonly TextBlock _temp = Text("", 56, "JcText", FontWeights.SemiBold);
    private readonly TextBlock _tempUnit = Text("°C", 20, "JcStatsLabel", FontWeights.Medium);
    private readonly WrapPanel _meta = new() { Margin = new Thickness(0, 10, 0, 0) };
    private readonly Path _line = new() { StrokeThickness = 2 }, _area = new();
    private readonly Grid _chart = new() { VerticalAlignment = VerticalAlignment.Bottom, IsHitTestVisible = false };

    public HeroView(Widget w) : base(w)
    {
        _area.Fill = Th.B("JcStatsArea");
        _chart.Children.Add(_area);
        _chart.Children.Add(_line);
        var number = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 0) };
        _unit.VerticalAlignment = VerticalAlignment.Bottom;
        _unit.Margin = new Thickness(4, 0, 0, 8);
        number.Children.Add(_value);
        number.Children.Add(_unit);
        _tempUnit.VerticalAlignment = VerticalAlignment.Bottom;
        _tempUnit.Margin = new Thickness(2, 0, 0, 8);
        number.Children.Add(_dot);
        number.Children.Add(_temp);
        number.Children.Add(_tempUnit);
        var col = new StackPanel();
        col.Children.Add(Label);
        col.Children.Add(number);
        col.Children.Add(_meta);
        var root = new Grid();
        root.Children.Add(_chart);
        root.Children.Add(col);
        Padding = new Thickness(20, 18, 20, 0);
        Child = root;
        SizeChanged += (_, e) =>
        {
            _chart.Height = Math.Max(20, e.NewSize.Height * 0.46);
            _value.FontSize = _temp.FontSize = _dot.FontSize = Math.Clamp(Math.Min(e.NewSize.Height / 4.2, e.NewSize.Width / 7), 28, 110);
            _unit.FontSize = _tempUnit.FontSize = Math.Max(16, _value.FontSize * 0.3);
            _unit.Margin = new Thickness(4, 0, 0, _value.FontSize * 0.15);
            _tempUnit.Margin = new Thickness(2, 0, 0, _value.FontSize * 0.15);
        };
    }

    public override void Update(WidgetFrame f)
    {
        var key = W.Readings.FirstOrDefault() ?? "";
        Label.Text = Title(f);
        // A load's hero shows its temperature beside it at the same size; the thresholds are the temperature's.
        var tempKey = key.EndsWith("load") ? (W.Style.Meta ?? Array.Empty<string>()).FirstOrDefault(IsTemp) : null;
        _value.Text = Value(f, key);
        _value.Foreground = !Has(f, key) ? Th.B("JcStatsLabel") : tempKey != null ? Th.B("JcText") : Tint(f, key);
        _unit.Text = Has(f, key) ? Unit(f, key) + Est(f, key) : "";
        var showTemp = tempKey != null && Has(f, tempKey);
        _dot.Visibility = _temp.Visibility = _tempUnit.Visibility = showTemp ? Visibility.Visible : Visibility.Collapsed;
        if (showTemp)
        {
            _temp.Text = Value(f, tempKey!);
            _temp.Foreground = Tint(f, tempKey!);
        }
        _meta.Children.Clear();
        foreach (var m in W.Style.Meta ?? Array.Empty<string>())
        {
            if (!Has(f, m) || m == tempKey) continue;
            var t = Text("", 13, "JcStatsMeta");
            t.Inlines.Add(new System.Windows.Documents.Run(Value(f, m) + Unit(f, m)) { Foreground = Th.B("JcText"), FontWeight = FontWeights.SemiBold });
            t.Inlines.Add(new System.Windows.Documents.Run("  " + (f.Labels.TryGetValue(m, out var l) ? Short(l) : m)));
            t.Margin = new Thickness(0, 0, 18, 4);
            _meta.Children.Add(t);
        }
        if (W.Style.Chart == "none") { _chart.Visibility = Visibility.Collapsed; return; }
        var window = W.Style.Window ?? 600;
        var pts = f.Series.Window(key, window, f.Sample.T);
        var (min, max) = Range(key, pts.Select(p => p.V));
        var (line, area) = Curve(pts, _chart.ActualWidth + 40, _chart.ActualHeight, min, max, f.Sample.T - window, f.Sample.T);
        _line.Data = line;
        _line.Stroke = LineBrush(0);
        _line.Margin = new Thickness(-20, 0, -20, 0);
        _area.Data = W.Style.Chart == "line" ? null : area;
        _area.Margin = _line.Margin;
    }

    private static string Short(string label) => label.Replace("GPU ", "").Replace("CPU ", "").ToLowerInvariant();

    private static bool IsTemp(string k) => k.EndsWith(".temp") || k.StartsWith("temp.");
}

/// Label, a mid-size number, unit; amber/red past its thresholds.
public sealed class NumberView : WidgetView
{
    private readonly TextBlock _value = Text("", 34, "JcText", FontWeights.SemiBold);
    private readonly TextBlock _unit = Text("", 15, "JcStatsLabel", FontWeights.Medium);

    // A faint area chart along the bottom, as on the big panels (style.chart "none" turns it off).
    private readonly Path _line = new() { StrokeThickness = 1.5, Opacity = 0.8 }, _area = new() { Opacity = 0.7 };
    private readonly Grid _chart = new() { VerticalAlignment = VerticalAlignment.Bottom, IsHitTestVisible = false };

    public NumberView(Widget w) : base(w)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 0) };
        _unit.VerticalAlignment = VerticalAlignment.Bottom;
        _unit.Margin = new Thickness(3, 0, 0, 5);
        row.Children.Add(_value);
        row.Children.Add(_unit);
        var col = new StackPanel();
        col.Children.Add(Label);
        col.Children.Add(row);
        _area.Fill = Th.B("JcStatsArea");
        _chart.Children.Add(_area);
        _chart.Children.Add(_line);
        var root = new Grid();
        root.Children.Add(_chart);
        root.Children.Add(col);
        Padding = new Thickness(18, 16, 18, 0);
        Child = root;
        SizeChanged += (_, e) => _chart.Height = Math.Max(16, e.NewSize.Height * 0.38);
        SizeChanged += (_, e) =>
        {
            _value.FontSize = Math.Clamp(Math.Min(e.NewSize.Height / 2.4, e.NewSize.Width / 4.5), 22, 110);
            _unit.FontSize = Math.Max(14, _value.FontSize * 0.32);
            _unit.Margin = new Thickness(4, 0, 0, _value.FontSize * 0.16);
        };
    }

    public override void Update(WidgetFrame f)
    {
        var key = W.Readings.FirstOrDefault() ?? "";
        Label.Text = Title(f);
        _value.Text = Value(f, key);
        _value.Foreground = Has(f, key) ? Tint(f, key) : Th.B("JcStatsLabel");
        _unit.Text = Has(f, key) ? (W.Style.Unit ?? Unit(f, key)) + Est(f, key) : "";
        if (W.Style.Chart == "none") { _chart.Visibility = Visibility.Collapsed; return; }
        var window = W.Style.Window ?? 600;
        var pts = f.Series.Window(key, window, f.Sample.T);
        var (min, max) = Range(key, pts.Select(p => p.V));
        var (line, area) = Curve(pts, _chart.ActualWidth + 36, _chart.ActualHeight, min, max, f.Sample.T - window, f.Sample.T);
        _line.Data = line;
        _line.Stroke = Tint(f, key) == Th.B("JcText") ? LineBrush(0) : Tint(f, key);
        _line.Margin = _area.Margin = new Thickness(-18, 0, -18, 0);
        _area.Data = W.Style.Chart == "line" ? null : area;
    }
}

/// Up to three readings as lines (or an area for the first) over the widget's window.
public sealed class ChartView : WidgetView
{
    private readonly Grid _plot = new() { Margin = new Thickness(0, 12, 0, 0) };
    private readonly StackPanel _legend = new() { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };

    public ChartView(Widget w) : base(w)
    {
        var head = new DockPanel();
        DockPanel.SetDock(_legend, Dock.Right);
        head.Children.Add(_legend);
        head.Children.Add(Label);
        var root = new DockPanel();
        DockPanel.SetDock(head, Dock.Top);
        root.Children.Add(head);
        root.Children.Add(_plot);
        Child = root;
    }

    public override void Update(WidgetFrame f)
    {
        Label.Text = Title(f);
        var window = W.Style.Window ?? 600;
        _plot.Children.Clear();
        _legend.Children.Clear();
        for (var i = 0; i < 4; i++)
            _plot.Children.Add(new Rectangle { Height = 1, Fill = Th.B("JcStatsTrack"), VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, _plot.ActualHeight * i / 3, 0, 0) });
        var keys = W.Readings.Take(3).ToList();
        var all = keys.SelectMany(k => f.Series.Window(k, window, f.Sample.T).Select(p => p.V)).ToList();
        var (min, max) = Range(keys.FirstOrDefault() ?? "", all);
        for (var i = 0; i < keys.Count; i++)
        {
            var pts = f.Series.Window(keys[i], window, f.Sample.T);
            var (line, area) = Curve(pts, _plot.ActualWidth, _plot.ActualHeight, min, max, f.Sample.T - window, f.Sample.T);
            if (i == 0 && W.Style.Chart != "line") _plot.Children.Add(new Path { Data = area, Fill = Th.B("JcStatsArea") });
            var brush = LineBrush(i);
            _plot.Children.Add(new Path { Data = line, Stroke = brush, StrokeThickness = i == 0 ? 2 : 1.4, StrokeDashArray = i == 2 ? new DoubleCollection { 3, 3 } : null });
            var tag = Text($"{(f.Labels.TryGetValue(keys[i], out var l) ? l : keys[i])} {Value(f, keys[i])}{(Has(f, keys[i]) ? Unit(f, keys[i]) : "")}", 11.5, "JcStatsMeta");
            tag.Foreground = brush;
            tag.Margin = new Thickness(14, 0, 0, 0);
            _legend.Children.Add(tag);
        }
    }
}

/// Thin gradient bars, one per reading, scaled to a sensible maximum for the reading.
public sealed class BarsView : WidgetView
{
    private readonly StackPanel _rows = new() { Margin = new Thickness(0, 12, 0, 0) };
    private readonly TextBlock _headline = Text("", 30, "JcText", FontWeights.SemiBold);

    public BarsView(Widget w) : base(w)
    {
        var col = new StackPanel();
        col.Children.Add(Label);
        col.Children.Add(_headline);
        col.Children.Add(_rows);
        Child = col;
    }

    public override void Update(WidgetFrame f)
    {
        Label.Text = Title(f);
        var head = W.Style.Meta?.FirstOrDefault();
        _headline.Visibility = head != null && Has(f, head) ? Visibility.Visible : Visibility.Collapsed;
        if (head != null) _headline.Text = Value(f, head) + " " + Unit(f, head) + Est(f, head);
        var keys = W.Readings.ToList();
        if (keys.Count == 1 && keys[0] == "gpu.fan")   // Cooling: every fan the PC reports
            keys = keys.Concat(f.Sample.R.Keys.Where(k => k.StartsWith("fan.")).OrderBy(k => k)).ToList();
        var total = keys.Where(k => k.StartsWith("power.")).Sum(k => f.Sample.R.GetValueOrDefault(k));
        _rows.Children.Clear();
        foreach (var k in keys)
        {
            var have = f.Sample.R.TryGetValue(k, out var v);
            var max = Max(k, f.Sample.R, total);
            var track = new Grid { Height = 6, VerticalAlignment = VerticalAlignment.Center };
            track.Children.Add(new Border { Background = Th.B("JcStatsTrack"), CornerRadius = new CornerRadius(3) });
            var fill = new Border { Background = Th.B("JcStatsBar"), CornerRadius = new CornerRadius(3), HorizontalAlignment = HorizontalAlignment.Left };
            track.Children.Add(fill);
            track.SizeChanged += (_, e) => fill.Width = have && max > 0 ? Math.Clamp(v / max, 0, 1) * e.NewSize.Width : 0;
            var row = new Grid { Margin = new Thickness(0, 0, 0, 10) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(78) });
            row.ColumnDefinitions.Add(new ColumnDefinition());
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(74) });
            var name = Text(Short(f.Labels.TryGetValue(k, out var l) ? l : k), 12.5, "JcStatsMeta");
            var val = Text(have ? Value(f, k) + " " + Unit(f, k) : "—", 12.5, "JcStatsMeta");
            val.TextAlignment = TextAlignment.Right;
            Grid.SetColumn(track, 1);
            Grid.SetColumn(val, 2);
            track.Margin = new Thickness(0, 0, 10, 0);
            row.Children.Add(name);
            row.Children.Add(track);
            row.Children.Add(val);
            _rows.Children.Add(row);
        }
    }

    private static double Max(string k, IReadOnlyDictionary<string, double> r, double powerTotal) => k switch
    {
        "ram.used" => r.GetValueOrDefault("ram.total"),
        "gpu.vram_used" => r.GetValueOrDefault("gpu.vram_total"),
        _ when k.StartsWith("power.") => powerTotal,
        _ when k.StartsWith("fan.") || k == "gpu.fan" => 3200,
        _ when k.StartsWith("temp.") || k.EndsWith("temp") => 100,
        _ => 100,
    };

    private static string Short(string label) => label.Replace(" power (model)", "").Replace(" power", "").Replace("System drive used", "Disk C:")
        .Replace("RAM used", "RAM").Replace("VRAM used", "VRAM");
}

/// A ring gauge (0–100 for loads, else to the crit threshold).
public sealed class RingView : WidgetView
{
    private readonly Path _arc = new() { StrokeThickness = 9, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, Stroke = Th.B("JcStatsLine") };
    private readonly Ellipse _track = new() { StrokeThickness = 9, Stroke = Th.B("JcStatsTrack") };
    private readonly TextBlock _value = Text("", 24, "JcText", FontWeights.SemiBold);
    private readonly Grid _ring = new() { Margin = new Thickness(0, 8, 0, 0) };

    public RingView(Widget w) : base(w)
    {
        _value.HorizontalAlignment = HorizontalAlignment.Center;
        _value.VerticalAlignment = VerticalAlignment.Center;
        _ring.Children.Add(_track);
        _ring.Children.Add(_arc);
        _ring.Children.Add(_value);
        var root = new DockPanel();
        DockPanel.SetDock(Label, Dock.Top);
        root.Children.Add(Label);
        root.Children.Add(_ring);
        Child = root;
    }

    public override void Update(WidgetFrame f)
    {
        var key = W.Readings.FirstOrDefault() ?? "";
        Label.Text = Title(f);
        var side = Math.Max(10, Math.Min(_ring.ActualWidth, _ring.ActualHeight) - 12);
        _track.Width = _track.Height = side;
        _arc.StrokeThickness = _track.StrokeThickness = Math.Clamp(side / 14, 6, 16);
        _value.FontSize = Math.Clamp(side / 4.5, 16, 60);
        _value.Text = Has(f, key) ? Value(f, key) + Unit(f, key) : "—";
        var v = f.Sample.R.GetValueOrDefault(key);
        var max = key.EndsWith("load") ? 100 : W.Style.Crit ?? 100;
        var frac = Math.Clamp(v / max, 0, 0.999);
        var r = side / 2;
        var c = new Point(_ring.ActualWidth / 2, _ring.ActualHeight / 2);
        var a = frac * 2 * Math.PI;
        var geo = new StreamGeometry();
        using (var g = geo.Open())
        {
            g.BeginFigure(new Point(c.X, c.Y - r), false, false);
            g.ArcTo(new Point(c.X + r * Math.Sin(a), c.Y - r * Math.Cos(a)), new Size(r, r), 0, frac > 0.5, SweepDirection.Clockwise, true, false);
        }
        geo.Freeze();
        _arc.Data = Has(f, key) ? geo : null;
        _arc.Stroke = Tint(f, key) == Th.B("JcText") ? LineBrush(0) : Tint(f, key);
    }
}

/// Label + value on one line, a small line under it.
public sealed class SparkView : WidgetView
{
    private readonly TextBlock _value = Text("", 22, "JcText", FontWeights.SemiBold);
    private readonly Path _line = new() { StrokeThickness = 1.5 };
    private readonly Grid _plot = new() { Margin = new Thickness(0, 8, 0, 0) };

    public SparkView(Widget w) : base(w)
    {
        _plot.Children.Add(_line);
        var head = new DockPanel();
        DockPanel.SetDock(_value, Dock.Right);
        head.Children.Add(_value);
        head.Children.Add(Label);
        var root = new DockPanel();
        DockPanel.SetDock(head, Dock.Top);
        root.Children.Add(head);
        root.Children.Add(_plot);
        Child = root;
    }

    public override void Update(WidgetFrame f)
    {
        var key = W.Readings.FirstOrDefault() ?? "";
        Label.Text = Title(f);
        _value.Text = Has(f, key) ? Value(f, key) + " " + Unit(f, key) : "—";
        var window = W.Style.Window ?? 300;
        var pts = f.Series.Window(key, window, f.Sample.T);
        var (min, max) = Range(key, pts.Select(p => p.V));
        _line.Data = Curve(pts, _plot.ActualWidth, _plot.ActualHeight, min, max, f.Sample.T - window, f.Sample.T).Line;
        _line.Stroke = LineBrush(0);
    }
}

/// A heading on the dashboard.
public sealed class TextView : WidgetView
{
    public TextView(Widget w) : base(w)
    {
        Background = Brushes.Transparent;
        BorderThickness = new Thickness(0);
        Label.FontSize = 18;
        Label.Foreground = Th.B("JcText");
        Child = Label;
    }

    public override void Update(WidgetFrame f) => Label.Text = W.Style.Label ?? "";
}

/// The current game (or the last sessions / marked moments, filled by the window from the server).
public sealed class ListView : WidgetView
{
    private readonly StackPanel _rows = new() { Margin = new Thickness(0, 10, 0, 0) };

    public ListView(Widget w) : base(w)
    {
        var col = new StackPanel();
        col.Children.Add(Label);
        col.Children.Add(_rows);
        Child = col;
    }

    public IReadOnlyList<string> Lines { get; set; } = Array.Empty<string>();

    public override void Update(WidgetFrame f)
    {
        Label.Text = W.Style.Label ?? (W.Kind == "session" ? "Game session" : "Marked moments");
        _rows.Children.Clear();
        var lines = W.Kind == "session" && f.Sample.Game is { } g
            ? new[] { $"Playing {System.IO.Path.GetFileNameWithoutExtension(g)}", $"{Value(f, "fps")} fps · 1% low {Value(f, "fps.low1")}" }.Concat(Lines).ToList()
            : Lines.ToList();
        if (lines.Count == 0) lines.Add(W.Kind == "session" ? "No game running" : "Nothing marked yet");
        foreach (var l in lines.Take(6)) _rows.Children.Add(Text(l, 13, "JcStatsMeta"));
    }
}
