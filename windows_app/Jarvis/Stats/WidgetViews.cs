using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
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
        _series[key] = new Queue<(double, double)>(points.Concat(q ?? new Queue<(double, double)>()).OrderBy(p => p.T).TakeLast(Keep));
    }

    public IReadOnlyList<(double T, double V)> Window(string key, double seconds, double now) =>
        _series.TryGetValue(key, out var q) ? q.Where(p => now - p.T <= seconds).ToList() : Array.Empty<(double, double)>();
}

/// What every widget view gets each second.
public sealed record WidgetFrame(StatsSample Sample, IReadOnlySet<string> Estimated, bool DriverOff, SeriesBuffer Series,
    IReadOnlyDictionary<string, string> Labels, IReadOnlyDictionary<string, string> Units,
    GameSession? Session = null, GameSession? LastSession = null, double Price = 0, string Currency = "USD");

/// The Apple look's colours and icons per reading group (docs/superpowers/specs/2026-11-15-pc-stats-apple-look.md).
public static class StatsLook
{
    public static string Group(string key) => key switch
    {
        _ when key.EndsWith(".temp") || key.StartsWith("temp.") || key == "gpu.hotspot" => "temps",
        _ when key.StartsWith("gpu.vram") || key.StartsWith("ram.") || key.StartsWith("disk.") => "memory",
        _ when key.StartsWith("fan.") || key == "gpu.fan" => "cooling",
        _ when key.StartsWith("gpu.") => "gpu",
        _ when key.StartsWith("cpu.") => "cpu",
        _ when key.StartsWith("fps") || key == "frametime" => "frames",
        _ when key.StartsWith("power.") => "power",
        _ when key.StartsWith("net.") => "network",
        _ => "other",
    };

    /// The app's one accent (white today), for anything that isn't data.
    public static Color Accent => Application.Current.TryFindResource("JcAccentColor") is Color c ? c : Colors.White;

    /// A reading's data colour (charts, rings, bars, sparklines, header icon); grey for anything unknown.
    public static Color Tint(string key) =>
        Application.Current.TryFindResource("JcStatsMetric." + Group(key)) is Color c ? c : Fade(Accent, 0.7);

    /// In a chart mixing parts, gpu.temp / cpu.temp take their part's colour so the lines differ.
    public static Color PartTint(string key) => key.StartsWith("gpu.") && key != "gpu.vram_used" && key != "gpu.fan" ? Tint("gpu.load")
        : key.StartsWith("cpu.") ? Tint("cpu.load") : Tint(key);

    public static Color Fade(Color c, double opacity) => Color.FromArgb((byte)(c.A * opacity), c.R, c.G, c.B);

    public static Color Warn => Application.Current.TryFindResource("JcAmberColor") is Color c ? c : Colors.Orange;
    public static Color Crit => Application.Current.TryFindResource("JcRedColor") is Color c ? c : Colors.Red;

    /// Segoe Fluent Icons glyph for the group.
    public static string Icon(string key) => Group(key) switch
    {
        "gpu" => "", "cpu" => "", "frames" => "", "power" => "", "memory" => "",
        "network" => "", "cooling" => "", "temps" => "", _ => "",
    };

    public static SolidColorBrush Brush(Color c, double opacity = 1) => new(Color.FromArgb((byte)(c.A * opacity), c.R, c.G, c.B));

    public static readonly FontFamily Rounded = new("Segoe UI Variable Display, Segoe UI");
    public static readonly FontFamily Icons = new("Segoe Fluent Icons, Segoe MDL2 Assets");
}

/// One widget in the Apple look: a dark grey card (JcStatsCard), a tinted icon + label header (context on the right),
/// then its kind's body.
public abstract class WidgetView : Border
{
    protected readonly Widget W;
    protected readonly TextBlock Label, Context, Icon;
    protected Color Tint;

    protected WidgetView(Widget w)
    {
        W = w;
        var key = w.Readings.FirstOrDefault() ?? "";
        Tint = w.Style.Color is { } c && TryColor(c) is { } custom ? custom : StatsLook.Tint(key);
        Background = Th.B("JcStatsCard");
        BorderBrush = Th.B("JcStatsHairline");
        BorderThickness = new Thickness(1);
        CornerRadius = new CornerRadius(16);
        Padding = new Thickness(20, 16, 20, 16);
        Margin = new Thickness(6);
        ClipToBounds = true;
        Icon = new TextBlock { Text = StatsLook.Icon(key), FontFamily = StatsLook.Icons, FontSize = 13, Foreground = StatsLook.Brush(Tint), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 1, 8, 0) };
        Label = Caps(Th.B("JcStatsSecondary"));
        Context = Caps(Th.B("JcStatsTertiary"));
        Context.HorizontalAlignment = HorizontalAlignment.Right;
    }

    public Widget Widget => W;

    public abstract void Update(WidgetFrame f);

    public static WidgetView For(Widget w) => w.Kind switch
    {
        "hero" => new HeroView(w),
        "chart" => new ChartView(w),
        "bars" => new BarsView(w),
        "ring" => new RingView(w),
        "sparkline" => new NumberView(w),
        "stats" => new StatsView(w),
        "text" => new TextView(w),
        "session" => new SessionView(w),
        "moments" => new ListView(w),
        _ => new NumberView(w),
    };

    /// The header row: icon + label left, context right.
    protected FrameworkElement Header()
    {
        var left = new StackPanel { Orientation = Orientation.Horizontal };
        left.Children.Add(Icon);
        left.Children.Add(Label);
        var row = new DockPanel { LastChildFill = true };
        DockPanel.SetDock(Context, Dock.Right);
        row.Children.Add(Context);
        row.Children.Add(left);
        return row;
    }

    /// The app's section-label style: small, semibold, muted, upper case (set through the Text property).
    protected static TextBlock Caps(Brush brush) => new UpperText
    {
        FontSize = 13, Foreground = brush, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center,
        FontFamily = (FontFamily)Application.Current.FindResource("JcFont"), TextTrimming = TextTrimming.CharacterEllipsis,
    };

    protected static TextBlock Text(string s, double size, Brush brush, FontWeight? weight = null) => new()
    {
        Text = s, FontSize = size, Foreground = brush, FontWeight = weight ?? FontWeights.Normal,
        FontFamily = (FontFamily)Application.Current.FindResource("JcFont"), TextTrimming = TextTrimming.CharacterEllipsis,
        VerticalAlignment = VerticalAlignment.Center,
    };

    /// Big rounded numerals with tabular digits.
    protected static TextBlock Numeral(double size) => new()
    {
        FontSize = size, FontFamily = StatsLook.Rounded, FontWeight = FontWeights.SemiBold, Foreground = Th.B("JcText"),
        VerticalAlignment = VerticalAlignment.Bottom,
    };

    protected static TextBlock UnitText(double size) => new()
    {
        FontSize = size, FontFamily = StatsLook.Rounded, FontWeight = FontWeights.Medium, Foreground = Th.B("JcStatsSecondary"),
        VerticalAlignment = VerticalAlignment.Bottom,
    };

    protected string Title(WidgetFrame f) => W.Style.Label ?? (W.Readings.Count > 0 ? LabelOf(f, W.Readings[0]) : W.Kind);

    protected static string Unit(WidgetFrame f, string key) => key.EndsWith(".temp") || key.StartsWith("temp.") || key == "gpu.hotspot" ? "°" : f.Units.TryGetValue(key, out var u) ? u : "";

    protected static string RawUnit(WidgetFrame f, string key) => f.Units.TryGetValue(key, out var u) ? u : "";

    protected string Value(WidgetFrame f, string key) => WidgetText.Value(key, f.Sample.R, W.Style.Decimals, f.DriverOff);

    protected static bool Has(WidgetFrame f, string key) => f.Sample.R.ContainsKey(key);

    /// Primary white; orange past warn, red past crit.
    protected Brush Level(WidgetFrame f, string key) =>
        WidgetText.Level(f.Sample.R.TryGetValue(key, out var v) ? v : null, W.Style) switch
        {
            "crit" => Th.B("JcStatsCrit"),
            "warn" => Th.B("JcStatsWarn"),
            _ => Th.B("JcText"),
        };

    /// A reading's name: the catalog's, else "fan.fan_1" → "Fan 1" (the server's rule for named fans and temperatures).
    protected static string LabelOf(WidgetFrame f, string key)
    {
        if (f.Labels.TryGetValue(key, out var l)) return l;
        var slug = key.Contains('.') ? key[(key.IndexOf('.') + 1)..] : key;
        var words = slug.Split('_', StringSplitOptions.RemoveEmptyEntries).Select((w, i) => w.ToUpperInvariant() switch
        {
            "NVME" => "NVMe",
            "DIMM" or "SSD" or "CPU" or "GPU" or "VRM" or "PCH" => w.ToUpperInvariant(),
            _ => i == 0 ? char.ToUpperInvariant(w[0]) + w[1..] : w,
        });
        return string.Join(' ', words);
    }

    /// The widget's readings with "temp.*" / "fan.*" expanded to every such key in the sample.
    protected static List<string> Expand(WidgetFrame f, IEnumerable<string> keys)
    {
        var out_ = new List<string>();
        foreach (var k in keys)
        {
            if (k.EndsWith(".*"))
            {
                var prefix = k[..^1];
                out_.AddRange(f.Sample.R.Keys.Where(x => x.StartsWith(prefix) && !out_.Contains(x)).OrderBy(x => x));
            }
            else if (!out_.Contains(k)) out_.Add(k);
        }
        return out_;
    }

    /// "GPU clock" → "Clock", "VRAM used" → "VRAM", "1% low" stays.
    protected static string MetaLabel(WidgetFrame f, string key)
    {
        var l = LabelOf(f, key);
        foreach (var p in new[] { "GPU ", "CPU " }) if (l.StartsWith(p)) l = l[p.Length..];
        l = l.Replace(" used", "");
        return l.Length > 0 ? char.ToUpperInvariant(l[0]) + l[1..] : l;
    }

    private static Color? TryColor(string s)
    {
        try { return (Color)ColorConverter.ConvertFromString(s); } catch (FormatException) { return null; }
    }

    protected static string Stats(IReadOnlyList<(double T, double V)> pts, string unit, int? decimals)
    {
        if (pts.Count < 2) return "";
        var d = decimals ?? (pts.Max(p => p.V) >= 100 ? 0 : unit is "GB" or "MB/s" ? 1 : 0);
        string F(double v) => v.ToString("F" + d, System.Globalization.CultureInfo.InvariantCulture);
        return $"Min {F(pts.Min(p => p.V))}   ·   Avg {F(pts.Average(p => p.V))}   ·   Max {F(pts.Max(p => p.V))}";
    }
}

/// A chart in the Apple look: smoothed line in the tint, a soft gradient fill, three faint gridlines
/// with their values at the right edge.
public sealed class Chart : Grid
{
    private readonly Canvas _canvas = new() { ClipToBounds = true };
    private readonly Canvas _axis = new() { Width = 40 };

    public Chart()
    {
        ColumnDefinitions.Add(new ColumnDefinition());
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        SetColumn(_axis, 1);
        Children.Add(_canvas);
        Children.Add(_axis);
    }

    public bool Axis { get; set; } = true;

    public void Draw(IReadOnlyList<IReadOnlyList<(double T, double V)>> series, IReadOnlyList<Color> colors, (double Min, double Max) range,
        double t0, double t1, bool fill, string unit)
    {
        _canvas.Children.Clear();
        _axis.Children.Clear();
        _axis.Visibility = Axis ? Visibility.Visible : Visibility.Collapsed;
        double w = _canvas.ActualWidth, h = _canvas.ActualHeight;
        if (w < 10 || h < 10) return;
        // A history shorter than the window fills the width instead of hugging the right edge.
        var firsts = series.Where(x => x.Count > 1).Select(x => x[0].T).ToList();
        if (firsts.Count > 0) t0 = Math.Max(t0, firsts.Min());
        for (var i = 0; i < 3; i++)
        {
            var y = h * i / 2.0;
            _canvas.Children.Add(new Line { X1 = 0, X2 = w, Y1 = Math.Min(h - 0.5, y + 0.5), Y2 = Math.Min(h - 0.5, y + 0.5), Stroke = Th.B("JcStatsGrid"), StrokeThickness = 1 });
            if (!Axis) continue;
            var v = range.Max - (range.Max - range.Min) * i / 2.0;
            var t = new TextBlock { Text = v >= 100 || unit == "%" ? v.ToString("F0") : v.ToString("0.#"), FontSize = 11, Foreground = Th.B("JcStatsTertiary"), FontFamily = StatsLook.Rounded };
            Canvas.SetLeft(t, 8);
            Canvas.SetTop(t, Math.Clamp(y - 8, 0, h - 16));
            _axis.Children.Add(t);
        }
        for (var s = series.Count - 1; s >= 0; s--)
        {
            var pts = ChartMath.Smooth(series[s]);
            if (pts.Count < 2) continue;
            var color = colors[Math.Min(s, colors.Count - 1)];
            double X(double t) => (t - t0) / Math.Max(1, t1 - t0) * w;
            double Y(double v) => h - (Math.Clamp(v, range.Min, range.Max) - range.Min) / Math.Max(1e-6, range.Max - range.Min) * (h - 2) - 1;
            var line = new StreamGeometry();
            using (var g = line.Open())
            {
                g.BeginFigure(new Point(X(pts[0].T), Y(pts[0].V)), false, false);
                g.PolyLineTo(pts.Skip(1).Select(p => new Point(X(p.T), Y(p.V))).ToList(), true, true);
            }
            line.Freeze();
            if (fill && s == 0)
            {
                var area = new StreamGeometry();
                using (var g = area.Open())
                {
                    g.BeginFigure(new Point(X(pts[0].T), h), true, true);
                    g.PolyLineTo(pts.Select(p => new Point(X(p.T), Y(p.V))).Append(new Point(X(pts[^1].T), h)).ToList(), false, true);
                }
                area.Freeze();
                var grad = new LinearGradientBrush(StatsLook.Fade(color, 0.22), StatsLook.Fade(color, 0), 90);
                _canvas.Children.Add(new Path { Data = area, Fill = grad });
            }
            _canvas.Children.Add(new Path { Data = line, Stroke = new SolidColorBrush(color), StrokeThickness = s == 0 ? 2 : 1.6, StrokeLineJoin = PenLineJoin.Round });
        }
    }
}

/// Header, a very large number (with its temperature beside it at the same size for a load),
/// a meta line, then the chart and its Min · Avg · Max line.
public sealed class HeroView : WidgetView
{
    private readonly TextBlock _value = Numeral(64), _unit = UnitText(22), _dot = UnitText(64), _temp = Numeral(64), _tempUnit = UnitText(22);
    private readonly TextBlock _meta = Text("", 14, Th.B("JcStatsSecondary")), _stats = Text("", 13, Th.B("JcStatsSecondary"));
    private readonly Chart _chart = new() { Margin = new Thickness(0, 14, 0, 8) };
    private double _size = 64;

    public HeroView(Widget w) : base(w)
    {
        _dot.Text = " · ";
        _dot.FontWeight = FontWeights.Light;
        var number = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 10, 0, 0) };
        foreach (var t in new[] { _value, _unit, _dot, _temp, _tempUnit }) number.Children.Add(t);
        var top = new StackPanel();
        top.Children.Add(Header());
        top.Children.Add(number);
        _meta.Margin = new Thickness(0, 4, 0, 0);
        top.Children.Add(_meta);
        var root = new DockPanel();
        DockPanel.SetDock(top, Dock.Top);
        DockPanel.SetDock(_stats, Dock.Bottom);
        root.Children.Add(top);
        root.Children.Add(_stats);
        root.Children.Add(_chart);
        Child = root;
        SizeChanged += (_, e) =>
        {
            var size = _size = Math.Clamp(Math.Min(e.NewSize.Height / 4.6, e.NewSize.Width / 7.5), 30, 96);
            _value.FontSize = _temp.FontSize = _dot.FontSize = size;
            _unit.FontSize = _tempUnit.FontSize = Math.Max(15, size * 0.34);
            _unit.Margin = _tempUnit.Margin = new Thickness(3, 0, 0, size * 0.14);
        };
    }

    public override void Update(WidgetFrame f)
    {
        var key = W.Readings.FirstOrDefault() ?? "";
        Label.Text = Title(f);
        var tempKey = key.EndsWith("load") ? (W.Style.Meta ?? Array.Empty<string>()).FirstOrDefault(m => m.EndsWith(".temp") || m.StartsWith("temp.")) : null;
        var have = Has(f, key);
        _value.Text = Value(f, key);
        _value.Foreground = !have ? Th.B("JcStatsSecondary") : tempKey != null ? Th.B("JcText") : Level(f, key);
        _value.FontSize = have ? _size : 22;
        _unit.Text = have ? Unit(f, key) : "";
        if (_unit.Text == "°") { _value.Text += "°"; _unit.Text = ""; }
        var showTemp = tempKey != null && Has(f, tempKey);
        _dot.Visibility = _temp.Visibility = _tempUnit.Visibility = showTemp ? Visibility.Visible : Visibility.Collapsed;
        if (showTemp) { _temp.Text = Value(f, tempKey!) + "°"; _temp.Foreground = Level(f, tempKey!); _tempUnit.Text = ""; }
        _meta.Inlines.Clear();
        foreach (var m in (W.Style.Meta ?? Array.Empty<string>()).Where(m => m != tempKey && Has(f, m)))
        {
            if (_meta.Inlines.Count > 0) _meta.Inlines.Add(new System.Windows.Documents.Run("      "));
            _meta.Inlines.Add(new System.Windows.Documents.Run(MetaLabel(f, m) + "  "));
            _meta.Inlines.Add(new System.Windows.Documents.Run($"{Value(f, m)} {Unit(f, m)}".Trim()) { Foreground = Th.B("JcText"), FontWeight = FontWeights.SemiBold });
        }
        if (f.Estimated.Contains(key)) _meta.Inlines.Add(new System.Windows.Documents.Run((_meta.Inlines.Count > 0 ? "      " : "") + "Estimated"));
        var window = W.Style.Window ?? 600;
        Context.Text = window >= 3600 ? $"{window / 3600} h" : $"{window / 60} min";
        if (W.Style.Chart == "none") { _chart.Visibility = _stats.Visibility = Visibility.Collapsed; return; }
        var pts = f.Series.Window(key, window, f.Sample.T);
        var unit = RawUnit(f, key);
        _chart.Draw(new[] { pts }, new[] { Tint }, ChartMath.Range(key, unit, pts.Select(p => p.V)), f.Sample.T - window, f.Sample.T, W.Style.Chart != "line", unit);
        _stats.Text = Stats(pts, unit, W.Style.Decimals);
    }
}

/// Header, a large number, and a small chart along the bottom (style.chart "none" hides it).
public sealed class NumberView : WidgetView
{
    private readonly TextBlock _value = Numeral(48), _unit = UnitText(18), _foot = Text("", 13, Th.B("JcStatsSecondary"));
    private readonly Chart _chart = new() { Axis = false, Margin = new Thickness(0, 10, 0, 6) };
    private double _size = 48;

    public NumberView(Widget w) : base(w)
    {
        var number = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
        number.Children.Add(_value);
        number.Children.Add(_unit);
        var top = new StackPanel();
        top.Children.Add(Header());
        top.Children.Add(number);
        var root = new DockPanel();
        DockPanel.SetDock(top, Dock.Top);
        DockPanel.SetDock(_foot, Dock.Bottom);
        root.Children.Add(top);
        root.Children.Add(_foot);
        root.Children.Add(_chart);
        Child = root;
        SizeChanged += (_, e) =>
        {
            var size = _size = Math.Clamp(Math.Min(e.NewSize.Height / 3.6, e.NewSize.Width / 4.2), 26, 84);
            _value.FontSize = size;
            _unit.FontSize = Math.Max(14, size * 0.36);
            _unit.Margin = new Thickness(3, 0, 0, size * 0.14);
        };
    }

    public override void Update(WidgetFrame f)
    {
        var key = W.Readings.FirstOrDefault() ?? "";
        Label.Text = Title(f);
        var have = Has(f, key);
        _value.Text = Value(f, key);
        _value.Foreground = have ? Level(f, key) : Th.B("JcStatsSecondary");
        _value.FontSize = have ? _size : 20;
        _unit.Text = have ? (W.Style.Unit ?? Unit(f, key)) : "";
        if (_unit.Text == "°") { _value.Text += "°"; _unit.Text = ""; }
        Context.Text = f.Estimated.Contains(key) ? "estimated" : "Now";
        if (W.Style.Chart == "none") { _chart.Visibility = _foot.Visibility = Visibility.Collapsed; return; }
        var window = W.Style.Window ?? 600;
        var pts = f.Series.Window(key, window, f.Sample.T);
        var unit = RawUnit(f, key);
        _chart.Draw(new[] { pts }, new[] { Tint }, ChartMath.Range(key, unit, pts.Select(p => p.V)), f.Sample.T - window, f.Sample.T, W.Style.Chart != "line", unit);
        _foot.Text = Stats(pts, unit, W.Style.Decimals).Replace("   ·   ", "  ·  ");
    }
}

/// Up to three readings over the widget's window, with a legend of current values.
public sealed class ChartView : WidgetView
{
    private readonly Chart _chart = new() { Margin = new Thickness(0, 12, 0, 0) };
    private readonly StackPanel _legend = new() { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };

    public ChartView(Widget w) : base(w)
    {
        var top = new StackPanel();
        top.Children.Add(Header());
        top.Children.Add(_legend);
        var root = new DockPanel();
        DockPanel.SetDock(top, Dock.Top);
        root.Children.Add(top);
        root.Children.Add(_chart);
        Child = root;
    }

    public override void Update(WidgetFrame f)
    {
        Label.Text = Title(f);
        var window = W.Style.Window ?? 600;
        Context.Text = window >= 3600 ? $"{window / 3600} h" : $"{window / 60} min";
        var keys = W.Readings.Take(3).ToList();
        // Lines from different parts take their own colours; same-group lines step down to 55%.
        var mixed = keys.Select(StatsLook.PartTint).Distinct().Count() > 1;
        var colors = new List<Color>();
        foreach (var k in keys)
        {
            var c = mixed ? StatsLook.PartTint(k) : StatsLook.Tint(k);
            colors.Add(colors.Contains(c) ? StatsLook.Fade(c, 0.55) : c);
        }
        var series = keys.Select(k => f.Series.Window(k, window, f.Sample.T)).ToList();
        var unit = keys.Count > 0 ? RawUnit(f, keys[0]) : "";
        _chart.Draw(series, colors, ChartMath.Range(keys.FirstOrDefault() ?? "", unit, series.SelectMany(s => s.Select(p => p.V))), f.Sample.T - window, f.Sample.T, W.Style.Chart != "line", unit);
        _legend.Children.Clear();
        for (var i = 0; i < keys.Count; i++)
        {
            var dot = new Ellipse { Width = 8, Height = 8, Fill = StatsLook.Brush(colors[i]), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(i == 0 ? 0 : 16, 0, 6, 0) };
            var label = Text($"{LabelOf(f, keys[i])}  {Value(f, keys[i])} {(Has(f, keys[i]) ? RawUnit(f, keys[i]) : "")}", 13, Th.B("JcStatsSecondary"));
            _legend.Children.Add(dot);
            _legend.Children.Add(label);
        }
    }
}

/// Rows of label + value with an 8 px bar under each, in the tint of each reading.
public sealed class BarsView : WidgetView
{
    private readonly StackPanel _rows = new() { Margin = new Thickness(0, 12, 0, 0) };
    private readonly TextBlock _headline = Numeral(36), _headUnit = UnitText(15);

    public BarsView(Widget w) : base(w)
    {
        var head = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 0) };
        head.Children.Add(_headline);
        head.Children.Add(_headUnit);
        _headUnit.Margin = new Thickness(3, 0, 0, 5);
        var col = new StackPanel();
        col.Children.Add(Header());
        col.Children.Add(head);
        col.Children.Add(_rows);
        Child = col;
    }

    public override void Update(WidgetFrame f)
    {
        Label.Text = Title(f);
        var head = W.Style.Meta?.FirstOrDefault();
        var showHead = head != null && Has(f, head);
        _headline.Visibility = _headUnit.Visibility = showHead ? Visibility.Visible : Visibility.Collapsed;
        if (showHead) { _headline.Text = Value(f, head!); _headUnit.Text = RawUnit(f, head!); }
        Context.Text = showHead && f.Estimated.Contains(head!) ? "estimated" : "Now";
        var keys = Expand(f, W.Readings);
        if (keys.Count == 1 && keys[0] == "gpu.fan")   // older dashboards: Cooling lists every fan
            keys = Expand(f, new[] { "gpu.fan", "fan.*" });
        keys = keys.Where(k => Has(f, k) || !W.Readings.Any(r => r.EndsWith(".*"))).ToList();
        var total = keys.Where(k => k.StartsWith("power.")).Sum(k => f.Sample.R.GetValueOrDefault(k));
        _rows.Children.Clear();
        // Fit the card: about 34 px a row (less when crowded), never more rows than fit.
        var room = ActualHeight - 70 - (showHead ? 50 : 0);
        var rowH = room > 0 ? Math.Clamp(room / Math.Max(1, keys.Count), 26, 44) : 40;
        if (room > 0) keys = keys.Take(Math.Max(1, (int)(room / 26))).ToList();
        var compact = rowH < 34;
        foreach (var k in keys)
        {
            var have = f.Sample.R.TryGetValue(k, out var v);
            var max = Max(k, f.Sample.R, total);
            var name = Text(Short(LabelOf(f, k)), compact ? 13 : 14, Th.B("JcStatsSecondary"));
            var val = Text(have ? $"{Value(f, k)} {(Unit(f, k) == "°" ? "°" : RawUnit(f, k))}".Replace(" °", "°") : "—", compact ? 13 : 14, Th.B("JcText"), FontWeights.SemiBold);
            if (have && (k.EndsWith(".temp") || k.StartsWith("temp.") || k == "gpu.hotspot") && v >= 85) val.Foreground = new SolidColorBrush(v >= 95 ? StatsLook.Crit : StatsLook.Warn);
            val.FontFamily = StatsLook.Rounded;
            var line = new DockPanel();
            DockPanel.SetDock(val, Dock.Right);
            line.Children.Add(val);
            line.Children.Add(name);
            var track = new Grid { Height = compact ? 6 : 8, Margin = new Thickness(0, compact ? 3 : 5, 0, 0) };
            track.Children.Add(new Border { Background = StatsLook.Brush(StatsLook.Accent, 0.08), CornerRadius = new CornerRadius(4) });
            var hot = (k.EndsWith(".temp") || k.StartsWith("temp.") || k == "gpu.hotspot") && v >= 95;
            var fill = new Border { Background = new SolidColorBrush(hot ? StatsLook.Crit : StatsLook.Tint(k)), CornerRadius = new CornerRadius(4), HorizontalAlignment = HorizontalAlignment.Left };
            track.Children.Add(fill);
            track.SizeChanged += (_, e) => fill.Width = have && max > 0 ? Math.Clamp(v / max, 0.02, 1) * e.NewSize.Width : 0;
            var row = new StackPanel { Margin = new Thickness(0, 0, 0, Math.Max(4, rowH - (compact ? 26 : 30))) };
            row.Children.Add(line);
            row.Children.Add(track);
            _rows.Children.Add(row);
        }
    }

    private static double Max(string k, IReadOnlyDictionary<string, double> r, double powerTotal) => k switch
    {
        "ram.used" or "ram.commit" => r.GetValueOrDefault("ram.total"),
        "gpu.vram_used" => r.GetValueOrDefault("gpu.vram_total"),
        _ when k.StartsWith("power.") => powerTotal,
        _ when k.StartsWith("fan.") || k == "gpu.fan" => 3200,
        _ when k.EndsWith(".temp") || k.StartsWith("temp.") || k == "gpu.hotspot" => 100,
        _ => 100,
    };

    private static string Short(string label) => label.Replace(" power (model)", "").Replace(" power", "").Replace("System drive used", "Disk C:")
        .Replace("RAM used", "RAM").Replace("VRAM used", "VRAM");
}

/// An Activity-style ring: thick, round caps, the tint over a 20% track; the value in the middle.
public sealed class RingView : WidgetView
{
    private readonly Path _arc = new() { StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round };
    private readonly Ellipse _track = new();
    private readonly TextBlock _value = Numeral(30), _sub = Text("", 13, Th.B("JcStatsSecondary"));
    private readonly Grid _ring = new() { Margin = new Thickness(0, 6, 0, 0) };
    private readonly StackPanel _center = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };

    public RingView(Widget w) : base(w)
    {
        _value.HorizontalAlignment = _sub.HorizontalAlignment = HorizontalAlignment.Center;
        _center.Children.Add(_value);
        _center.Children.Add(_sub);
        _ring.Children.Add(_track);
        _ring.Children.Add(_arc);
        _ring.Children.Add(_center);
        var root = new DockPanel();
        var header = Header();
        DockPanel.SetDock(header, Dock.Top);
        root.Children.Add(header);
        root.Children.Add(_ring);
        Child = root;
    }

    public override void Update(WidgetFrame f)
    {
        var key = W.Readings.FirstOrDefault() ?? "";
        Label.Text = Title(f);
        Context.Text = "Now";
        var side = Math.Max(10, Math.Min(_ring.ActualWidth, _ring.ActualHeight) - 4);
        var stroke = Math.Max(6, side * 0.13);
        _track.Width = _track.Height = side;
        _track.StrokeThickness = _arc.StrokeThickness = stroke;
        _track.Stroke = StatsLook.Brush(Tint, 0.18);
        var level = WidgetText.Level(f.Sample.R.TryGetValue(key, out var lv) ? lv : null, W.Style);
        _arc.Stroke = new SolidColorBrush(level == "crit" ? StatsLook.Crit : Tint);
        _value.FontSize = Math.Clamp(side / 4, 16, 64);
        var have = Has(f, key);
        _value.Text = have ? Value(f, key) + Unit(f, key) : "—";
        var temp = key.Replace(".load", ".temp");
        _sub.Text = key.EndsWith("load") && Has(f, temp) ? $"{Value(f, temp)}°" : "";
        _sub.FontSize = Math.Clamp(side / 9, 12, 22);
        var v = f.Sample.R.GetValueOrDefault(key);
        var max = key.EndsWith("load") ? 100 : W.Style.Crit ?? 100;
        var frac = Math.Clamp(v / max, 0, 0.9999);
        var r = (side - stroke) / 2;
        var c = new Point(_ring.ActualWidth / 2, _ring.ActualHeight / 2);
        var a = frac * 2 * Math.PI;
        var geo = new StreamGeometry();
        using (var g = geo.Open())
        {
            g.BeginFigure(new Point(c.X, c.Y - r), false, false);
            g.ArcTo(new Point(c.X + r * Math.Sin(a), c.Y - r * Math.Cos(a)), new Size(r, r), 0, frac > 0.5, SweepDirection.Clockwise, true, false);
        }
        geo.Freeze();
        _arc.Data = have && frac > 0 ? geo : null;
    }
}

/// A detail tile: a grid of labelled numbers, each with a small sparkline under it (iStat-style).
public sealed class StatsView : WidgetView
{
    private readonly UniformGrid _cells = new() { Margin = new Thickness(0, 10, 0, 0) };
    private readonly Dictionary<string, (TextBlock Label, TextBlock Value, TextBlock Unit, Chart Spark)> _parts = new();

    public StatsView(Widget w) : base(w)
    {
        var root = new DockPanel();
        var header = Header();
        DockPanel.SetDock(header, Dock.Top);
        root.Children.Add(header);
        root.Children.Add(_cells);
        Child = root;
    }

    public override void Update(WidgetFrame f)
    {
        Label.Text = Title(f);
        Context.Text = "Now";
        var keys = Expand(f, W.Readings).Take(12).ToList();
        _cells.Columns = ActualWidth > 460 && keys.Count > 4 ? 3 : 2;
        _cells.Rows = (int)Math.Ceiling(keys.Count / (double)_cells.Columns);
        if (_parts.Count != keys.Count || keys.Any(k => !_parts.ContainsKey(k)))
        {
            _cells.Children.Clear();
            _parts.Clear();
            foreach (var k in keys)
            {
                var label = Text("", 13, Th.B("JcStatsSecondary"));
                var value = Numeral(28);
                var unit = UnitText(13);
                unit.Margin = new Thickness(3, 0, 0, 5);
                var spark = new Chart { Axis = false, Height = 22, Margin = new Thickness(0, 6, 14, 0), IsHitTestVisible = false };
                var num = new StackPanel { Orientation = Orientation.Horizontal };
                num.Children.Add(value);
                num.Children.Add(unit);
                var cell = new StackPanel { Margin = new Thickness(0, 0, 0, 8), VerticalAlignment = VerticalAlignment.Top };
                cell.Children.Add(label);
                cell.Children.Add(num);
                cell.Children.Add(spark);
                _cells.Children.Add(cell);
                _parts[k] = (label, value, unit, spark);
            }
        }
        // From the card's own (grid-fixed) height, so the sparklines can't feed back into the layout.
        var cellH = (ActualHeight - Padding.Top - Padding.Bottom - 34) / Math.Max(1, _cells.Rows);
        foreach (var k in keys)
        {
            var (label, value, unit, spark) = _parts[k];
            label.Text = MetaLabel(f, k);
            var have = Has(f, k);
            value.FontSize = Math.Clamp(cellH * 0.34, 18, 40);
            value.Text = Value(f, k);
            value.Foreground = have ? Level(f, k) : Th.B("JcStatsSecondary");
            var u = have ? Unit(f, k) : "";
            if (u == "°") { value.Text += "°"; u = ""; }
            unit.Text = u;
            var tint = StatsLook.Tint(k);
            var pts = f.Series.Window(k, 300, f.Sample.T);
            spark.Height = Math.Max(18, Math.Floor(cellH - value.FontSize * 1.35 - 44));
            spark.Visibility = cellH > 70 ? Visibility.Visible : Visibility.Collapsed;
            if (spark.Visibility == Visibility.Visible)
                spark.Draw(new[] { pts }, new[] { tint }, ChartMath.Range(k, RawUnit(f, k), pts.Select(p => p.V)), f.Sample.T - 300, f.Sample.T, true, RawUnit(f, k));
        }
    }
}

/// The game being played: its name, how long, and four numbers (average fps, 1% low, energy and
/// cost so far, hottest GPU); with no game, the last one played.
public sealed class SessionView : WidgetView
{
    private readonly TextBlock _game = Numeral(30), _since = Text("", 14, Th.B("JcStatsSecondary"));
    private readonly UniformGrid _cells = new() { Columns = 2, Margin = new Thickness(0, 14, 0, 0) };
    private readonly (TextBlock Label, TextBlock Value)[] _parts = new (TextBlock, TextBlock)[4];
    private readonly Image _icon = new() { Stretch = Stretch.UniformToFill };
    private Border? _iconHost;

    public SessionView(Widget w) : base(w)
    {
        _game.VerticalAlignment = VerticalAlignment.Top;
        _game.TextTrimming = TextTrimming.CharacterEllipsis;
        _game.Margin = new Thickness(0, 10, 0, 0);
        for (var i = 0; i < 4; i++)
        {
            var label = Text("", 13, Th.B("JcStatsSecondary"));
            var value = Numeral(24);
            var cell = new StackPanel { Margin = new Thickness(0, 0, 0, 10) };
            cell.Children.Add(label);
            cell.Children.Add(value);
            _cells.Children.Add(cell);
            _parts[i] = (label, value);
        }
        var gameRow = new DockPanel { Margin = new Thickness(0, 12, 0, 0) };
        var iconHost = new Border { Width = 44, Height = 44, CornerRadius = new CornerRadius(10), ClipToBounds = true, Margin = new Thickness(0, 0, 12, 0), Child = _icon, VerticalAlignment = VerticalAlignment.Center };
        _iconHost = iconHost;
        DockPanel.SetDock(iconHost, Dock.Left);
        var names = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        _game.Margin = new Thickness(0);
        names.Children.Add(_game);
        names.Children.Add(_since);
        gameRow.Children.Add(iconHost);
        gameRow.Children.Add(names);
        var top = new StackPanel();
        top.Children.Add(Header());
        top.Children.Add(gameRow);
        var root = new DockPanel();
        DockPanel.SetDock(top, Dock.Top);
        root.Children.Add(top);
        root.Children.Add(_cells);
        Child = root;
    }

    public override void Update(WidgetFrame f)
    {
        Label.Text = W.Style.Label ?? "Game session";
        var s = f.Session ?? f.LastSession;
        Context.Text = f.Session != null ? "Live" : s != null ? "Last" : "";
        _cells.Visibility = s == null ? Visibility.Collapsed : Visibility.Visible;
        if (s == null) { if (_iconHost != null) _iconHost.Visibility = Visibility.Collapsed; _game.Text = "No game yet"; _game.Foreground = Th.B("JcStatsSecondary"); _since.Text = "Sessions start when a game is in front."; return; }
        _game.Foreground = Th.B("JcText");
        _game.Text = GameInfo.Cached(s.Exe)?.Name ?? Title(s.Exe);
        _icon.Source = GameInfo.Cached(s.Exe)?.Icon;
        if (_iconHost != null) _iconHost.Visibility = _icon.Source != null ? Visibility.Visible : Visibility.Collapsed;
        var mins = (int)Math.Round((s.End - s.Start) / 60);
        var len = mins >= 60 ? $"{mins / 60} h {mins % 60} min" : $"{Math.Max(1, mins)} min";
        _since.Text = f.Session != null ? $"Playing for {len}" : $"Played {len}";
        var cost = f.Price > 0 ? $"{s.EnergyWh / 1000 * f.Price:0.00} {f.Currency}" : $"{s.EnergyWh:0} Wh";
        Set(0, "Average", s.FpsAvg > 0 ? $"{s.FpsAvg:0} fps" : "—");
        Set(1, "1% low", s.FpsLow1 > 0 ? $"{s.FpsLow1:0} fps" : "—");
        Set(2, f.Price > 0 ? "Cost so far" : "Energy", cost);
        Set(3, "Hottest GPU", s.GpuTempMax > 0 ? $"{s.GpuTempMax:0}°" : "—");
    }

    private void Set(int i, string label, string value) { _parts[i].Label.Text = label; _parts[i].Value.Text = value; }

    /// "cod.exe" → "Cod", "cs2.exe" → "Cs2"; short exe names in capitals ("COD" reads better).
    private static string Title(string exe)
    {
        var n = System.IO.Path.GetFileNameWithoutExtension(exe);
        return n.Length <= 4 ? n.ToUpperInvariant() : char.ToUpperInvariant(n[0]) + n[1..];
    }
}

/// A heading on the dashboard.
public sealed class TextView : WidgetView
{
    public TextView(Widget w) : base(w)
    {
        Background = Brushes.Transparent;
        Label.FontSize = 22;
        Label.Foreground = Th.B("JcText");
        Child = Label;
    }

    public override void Update(WidgetFrame f) => Label.Text = W.Style.Label ?? "";
}

/// The current game, or recent sessions / marked moments (lines set by the window).
public sealed class ListView : WidgetView
{
    private readonly StackPanel _rows = new() { Margin = new Thickness(0, 12, 0, 0) };

    public ListView(Widget w) : base(w)
    {
        var col = new StackPanel();
        col.Children.Add(Header());
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
        foreach (var l in lines.Take(6)) _rows.Children.Add(Text(l, 14, Th.B("JcStatsSecondary")));
    }
}

/// A TextBlock that shows its text in capitals (the app's small section labels).
public sealed class UpperText : TextBlock
{
    static UpperText() => TextProperty.OverrideMetadata(typeof(UpperText),
        new FrameworkPropertyMetadata("", null, (_, v) => (v as string)?.ToUpperInvariant() ?? ""));
}
