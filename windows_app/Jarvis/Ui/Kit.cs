using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace Jarvis.Ui;

/// The island's kit, after the Mac island's SwiftUI (IslandViews / IslandPanes / ChatViews):
/// SF Pro sizes in Segoe UI Variable, white at the Mac's exact opacities, SF-Symbol-style vector
/// icons, and plain-drawn controls (no stock Button/ComboBox chrome anywhere in the island).
internal static class K
{
    public static readonly FontFamily Font = (FontFamily)Application.Current.FindResource("JcFont");
    public static readonly FontFamily Display = (FontFamily)Application.Current.FindResource("JcFontDisplay");
    public static readonly FontFamily Mono = (FontFamily)Application.Current.FindResource("JcMono");
    public static readonly FontFamily Fluent = new("Segoe Fluent Icons, Segoe MDL2 Assets");

    private static readonly Dictionary<(string, int), SolidColorBrush> Cache = new();

    public static Color C(string key) => ((SolidColorBrush)Th.B(key)).Color;

    /// The theme colour `key` at `opacity` (SwiftUI's `.opacity`), cached and frozen.
    public static SolidColorBrush A(string key, double opacity = 1)
    {
        var k = (key, (int)Math.Round(opacity * 1000));
        if (Cache.TryGetValue(k, out var b)) return b;
        var c = C(key);
        b = new SolidColorBrush(Color.FromArgb((byte)Math.Round(c.A * Math.Clamp(opacity, 0, 1)), c.R, c.G, c.B));
        b.Freeze();
        Cache[k] = b;
        return b;
    }

    /// White at `opacity`: most of the island's greys.
    public static SolidColorBrush W(double opacity) => A("JcText", opacity);

    /// `Text("…").font(.system(size:, weight:))`.
    public static TextBlock T(string s, double size, FontWeight? weight = null, Brush? fg = null, bool mono = false, bool wrap = false)
    {
        var t = new TextBlock
        {
            Text = s,
            FontFamily = mono ? Mono : size >= 17 ? Display : Font,
            FontSize = size,
            FontWeight = weight ?? FontWeights.Normal,
            Foreground = fg ?? W(1),
            TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
            TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
            SnapsToDevicePixels = true,
        };
        TextOptions.SetTextRenderingMode(t, TextRenderingMode.Grayscale);
        return t;
    }

    public static Border Capsule(UIElement child, Brush fill, double padX, double padY) => new()
    {
        Background = fill,
        CornerRadius = new CornerRadius(999),
        Padding = new Thickness(padX, padY, padX, padY),
        Child = child,
        VerticalAlignment = VerticalAlignment.Center,
    };

    public static Border Rounded(UIElement? child, Brush fill, double radius, double pad = 0, Brush? stroke = null, double strokeWidth = 0.5) => new()
    {
        Background = fill,
        CornerRadius = new CornerRadius(radius),
        Padding = new Thickness(pad),
        Child = child,
        BorderBrush = stroke,
        BorderThickness = stroke == null ? new Thickness(0) : new Thickness(strokeWidth),
    };

    public static StackPanel H(double gap, params UIElement[] children) => Stack(Orientation.Horizontal, gap, children);
    public static StackPanel V(double gap, params UIElement[] children) => Stack(Orientation.Vertical, gap, children);

    private static StackPanel Stack(Orientation o, double gap, UIElement[] children)
    {
        var p = new StackPanel { Orientation = o };
        foreach (var c in children) Add(p, c, gap);
        return p;
    }

    /// Adds `child` with `gap` before it (unless it's the first).
    public static void Add(StackPanel p, UIElement child, double gap)
    {
        if (p.Children.Count > 0 && child is FrameworkElement fe)
        {
            var m = fe.Margin;
            fe.Margin = p.Orientation == Orientation.Horizontal
                ? new Thickness(m.Left + gap, m.Top, m.Right, m.Bottom)
                : new Thickness(m.Left, m.Top + gap, m.Right, m.Bottom);
        }
        p.Children.Add(child);
    }

    /// A row with a leading part, a flexible gap and a trailing part (`HStack { …; Spacer(); … }`).
    public static Grid Spread(UIElement leading, UIElement? trailing, double gap = 8)
    {
        var g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (leading is FrameworkElement l && l.HorizontalAlignment == HorizontalAlignment.Stretch) l.HorizontalAlignment = HorizontalAlignment.Left;
        g.Children.Add(leading);
        if (trailing != null)
        {
            Grid.SetColumn(trailing, 1);
            if (trailing is FrameworkElement fe) fe.Margin = new Thickness(gap, fe.Margin.Top, fe.Margin.Right, fe.Margin.Bottom);
            g.Children.Add(trailing);
        }
        return g;
    }

    /// A Segoe Fluent Icons glyph (for symbols without a vector here).
    public static TextBlock Glyph(string glyph, double size, Brush fg) => new()
    {
        Text = glyph,
        FontFamily = Fluent,
        FontSize = size,
        Foreground = fg,
        VerticalAlignment = VerticalAlignment.Center,
        HorizontalAlignment = HorizontalAlignment.Center,
    };
}

/// SF-Symbol-like icons drawn as vectors on a 24-unit grid (stroke parts and fill parts).
internal enum Sym
{
    Terminal, Chat, MusicNote, ChevronUp, ChevronDown, ChevronRight, Plus, ArrowUp, Stop, Waveform, RadioWaves,
    BubbleLeft, Compose, Sparkles, Play, Pause, Backward, Forward, SpeakerFill, SpeakerWave, Shuffle, Repeat,
    Lock, MicFill, MicSlash, Moon, Doc, Hand, Gear,
}

internal sealed class IconView : FrameworkElement
{
    private sealed record Def(string? Stroke, string? Fill, double Weight = 1.9);

    private static readonly Dictionary<Sym, Def> Defs = new()
    {
        [Sym.Terminal] = new("M4.5,4.5 H19.5 A2.5,2.5 0 0 1 22,7 V17 A2.5,2.5 0 0 1 19.5,19.5 H4.5 A2.5,2.5 0 0 1 2,17 V7 A2.5,2.5 0 0 1 4.5,4.5 Z M6.5,9 L9.5,11.75 L6.5,14.5 M11.5,15 H16.5", null, 1.8),
        [Sym.Chat] = new("M14.5,8 V6 A2,2 0 0 0 12.5,4 H4 A2,2 0 0 0 2,6 V11.5 A2,2 0 0 0 4,13.5 H4.5 V16 L7.5,13.5 M10,9.5 H20 A2,2 0 0 1 22,11.5 V17 A2,2 0 0 1 20,19 H19.5 V21.5 L16.5,19 H10 A2,2 0 0 1 8,17 V11.5 A2,2 0 0 1 10,9.5 Z M11.5,13 H18.5 M11.5,15.75 H16", null, 1.7),
        [Sym.MusicNote] = new("M10.6,17.6 V3.6 C12,5.6 16.2,6.2 16.2,10.2", "M11.2,17.6 C11.2,19.3 9.6,20.7 7.6,20.7 C5.6,20.7 4.2,19.6 4.2,18.1 C4.2,16.4 5.8,15 7.8,15 C9.8,15 11.2,16.1 11.2,17.6 Z", 1.9),
        [Sym.ChevronUp] = new("M5.5,15.5 L12,9 L18.5,15.5", null, 2.4),
        [Sym.ChevronDown] = new("M5.5,9 L12,15.5 L18.5,9", null, 2.4),
        [Sym.ChevronRight] = new("M9,5.5 L15.5,12 L9,18.5", null, 2.4),
        [Sym.Plus] = new("M12,4.5 V19.5 M4.5,12 H19.5", null, 2.1),
        [Sym.ArrowUp] = new("M12,19.5 V5 M5.5,11.5 L12,5 L18.5,11.5", null, 2.3),
        [Sym.Stop] = new(null, "M7.5,6 H16.5 A1.5,1.5 0 0 1 18,7.5 V16.5 A1.5,1.5 0 0 1 16.5,18 H7.5 A1.5,1.5 0 0 1 6,16.5 V7.5 A1.5,1.5 0 0 1 7.5,6 Z"),
        [Sym.Waveform] = new("M3,10.5 V13.5 M6,8 V16 M9,4.5 V19.5 M12,7 V17 M15,3 V21 M18,8 V16 M21,10.5 V13.5", null, 1.9),
        [Sym.RadioWaves] = new("M8.6,8 A5.5,5.5 0 0 0 8.6,16 M15.4,8 A5.5,5.5 0 0 1 15.4,16 M5.4,4.8 A10,10 0 0 0 5.4,19.2 M18.6,4.8 A10,10 0 0 1 18.6,19.2",
            "M13.9,12 A1.9,1.9 0 1 1 10.1,12 A1.9,1.9 0 1 1 13.9,12 Z", 1.8),
        [Sym.BubbleLeft] = new("M5,4.5 H19 A2.5,2.5 0 0 1 21.5,7 V15 A2.5,2.5 0 0 1 19,17.5 H10.5 L6,21 V17.5 H5 A2.5,2.5 0 0 1 2.5,15 V7 A2.5,2.5 0 0 1 5,4.5 Z", null, 1.8),
        [Sym.Compose] = new("M12,4.5 H6.5 A2.5,2.5 0 0 0 4,7 V17.5 A2.5,2.5 0 0 0 6.5,20 H17 A2.5,2.5 0 0 0 19.5,17.5 V12 M18,3.2 L20.8,6 L12.5,14.3 L8.9,15.1 L9.7,11.5 Z", null, 1.8),
        [Sym.Sparkles] = new(null, "M10,3.5 C10.6,9 12,10.4 17.5,11 C12,11.6 10.6,13 10,18.5 C9.4,13 8,11.6 2.5,11 C8,10.4 9.4,9 10,3.5 Z M18.5,2.5 C18.8,4.6 19.4,5.2 21.5,5.5 C19.4,5.8 18.8,6.4 18.5,8.5 C18.2,6.4 17.6,5.8 15.5,5.5 C17.6,5.2 18.2,4.6 18.5,2.5 Z M18,15.5 C18.2,17 18.6,17.4 20,17.6 C18.6,17.8 18.2,18.2 18,19.7 C17.8,18.2 17.4,17.8 16,17.6 C17.4,17.4 17.8,17 18,15.5 Z"),
        [Sym.Play] = new(null, "M7,4.8 C7,3.9 7.9,3.4 8.7,3.9 L20,11 C20.7,11.5 20.7,12.5 20,13 L8.7,20.1 C7.9,20.6 7,20.1 7,19.2 Z"),
        [Sym.Pause] = new(null, "M6.5,4 H10 A1,1 0 0 1 11,5 V19 A1,1 0 0 1 10,20 H6.5 A1,1 0 0 1 5.5,19 V5 A1,1 0 0 1 6.5,4 Z M14,4 H17.5 A1,1 0 0 1 18.5,5 V19 A1,1 0 0 1 17.5,20 H14 A1,1 0 0 1 13,19 V5 A1,1 0 0 1 14,4 Z"),
        [Sym.Backward] = new("M11.5,6.5 V17.5 L2.5,12 Z M21.5,6.5 V17.5 L12.5,12 Z", "M11.5,6.5 V17.5 L2.5,12 Z M21.5,6.5 V17.5 L12.5,12 Z", 1.4),
        [Sym.Forward] = new("M12.5,6.5 V17.5 L21.5,12 Z M2.5,6.5 V17.5 L11.5,12 Z", "M12.5,6.5 V17.5 L21.5,12 Z M2.5,6.5 V17.5 L11.5,12 Z", 1.4),
        [Sym.SpeakerFill] = new(null, "M3.5,9 H6.5 L11,5 V19 L6.5,15 H3.5 A1,1 0 0 1 2.5,14 V10 A1,1 0 0 1 3.5,9 Z"),
        [Sym.SpeakerWave] = new("M14.5,9 A4,4 0 0 1 14.5,15 M17,6.5 A7.5,7.5 0 0 1 17,17.5 M19.5,4 A11,11 0 0 1 19.5,20", "M3.5,9 H6.5 L11,5 V19 L6.5,15 H3.5 A1,1 0 0 1 2.5,14 V10 A1,1 0 0 1 3.5,9 Z", 1.6),
        [Sym.Shuffle] = new("M3,7 H6.5 C10.5,7 12.5,17 16.5,17 H20.5 M3,17 H6.5 C10.5,17 12.5,7 16.5,7 H20.5 M18,4.5 L20.5,7 L18,9.5 M18,14.5 L20.5,17 L18,19.5", null, 1.9),
        [Sym.Repeat] = new("M4,11 V9.5 A2.5,2.5 0 0 1 6.5,7 H19 M16.5,4.5 L19,7 L16.5,9.5 M20,13 V14.5 A2.5,2.5 0 0 1 17.5,17 H5 M7.5,19.5 L5,17 L7.5,14.5", null, 1.9),
        [Sym.Lock] = new("M7.5,10.5 V8 A4.5,4.5 0 0 1 16.5,8 V10.5", "M6,10.5 H18 A1.5,1.5 0 0 1 19.5,12 V19 A1.5,1.5 0 0 1 18,20.5 H6 A1.5,1.5 0 0 1 4.5,19 V12 A1.5,1.5 0 0 1 6,10.5 Z", 2.0),
        [Sym.MicFill] = new("M5.5,11.5 A6.5,6.5 0 0 0 18.5,11.5 M12,18 V21", "M12,2.5 A3.5,3.5 0 0 1 15.5,6 V11.5 A3.5,3.5 0 0 1 8.5,11.5 V6 A3.5,3.5 0 0 1 12,2.5 Z", 1.9),
        [Sym.MicSlash] = new("M5.5,11.5 A6.5,6.5 0 0 0 18.5,11.5 M12,18 V21 M4,3 L20,21", "M12,2.5 A3.5,3.5 0 0 1 15.5,6 V11.5 A3.5,3.5 0 0 1 8.5,11.5 V6 A3.5,3.5 0 0 1 12,2.5 Z", 1.9),
        [Sym.Moon] = new("M19.5,14.5 A8,8 0 1 1 10,4.5 A6.5,6.5 0 0 0 19.5,14.5 Z", null, 1.7),
        [Sym.Doc] = new("M6.5,2.5 H13.5 L18.5,7.5 V19.5 A2,2 0 0 1 16.5,21.5 H6.5 A2,2 0 0 1 4.5,19.5 V4.5 A2,2 0 0 1 6.5,2.5 Z M13.5,2.5 V7.5 H18.5 M8,12 H15 M8,15 H15 M8,18 H12", null, 1.6),
        [Sym.Hand] = new("M9,12 V5 A1.5,1.5 0 0 1 12,5 V11 M12,10 V8.5 A1.5,1.5 0 0 1 15,8.5 V11 M15,10.5 A1.5,1.5 0 0 1 18,10.5 V15 A6.5,6.5 0 0 1 11.5,21.5 C8.5,21.5 7,19.8 5.6,17.5 L4,14.6 A1.4,1.4 0 0 1 6.4,13.2 L9,16", null, 1.7),
        [Sym.Gear] = new("M12,8.5 A3.5,3.5 0 1 1 11.99,8.5 Z M10.3,2.5 H13.7 L14.2,5 L16.4,6.3 L18.8,5.4 L20.5,8.4 L18.6,10.1 V12.6 L20.5,14.3 L18.8,17.3 L16.4,16.4 L14.2,17.7 L13.7,20.2 H10.3 L9.8,17.7 L7.6,16.4 L5.2,17.3 L3.5,14.3 L5.4,12.6 V10.1 L3.5,8.4 L5.2,5.4 L7.6,6.3 L9.8,5 Z", null, 1.6),
    };

    private static readonly Dictionary<Sym, (Geometry? Stroke, Geometry? Fill, double Weight)> Parsed = new();

    public static readonly DependencyProperty ForegroundProperty = DependencyProperty.Register(
        nameof(Foreground), typeof(Brush), typeof(IconView), new FrameworkPropertyMetadata(Brushes.White, FrameworkPropertyMetadataOptions.AffectsRender));

    public IconView(Sym icon, double size, Brush fg, double weight = 1)
    {
        Kind = icon;
        Side = size;
        Foreground = fg;
        WeightScale = weight;
        Width = size;
        Height = size;
        SnapsToDevicePixels = true;
        VerticalAlignment = VerticalAlignment.Center;
        HorizontalAlignment = HorizontalAlignment.Center;
    }

    public Sym Kind { get; private set; }
    public double Side { get; }
    /// Heavier (>1) or lighter (<1) than the icon's own stroke: SF's font weights.
    public double WeightScale { get; set; }
    public Brush Foreground { get => (Brush)GetValue(ForegroundProperty); set => SetValue(ForegroundProperty, value); }

    public void Set(Sym icon)
    {
        if (icon == Kind) return;
        Kind = icon;
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext dc)
    {
        if (!Parsed.TryGetValue(Kind, out var g))
        {
            var d = Defs[Kind];
            Geometry? Parse(string? s)
            {
                if (s == null) return null;
                var geo = Geometry.Parse(s);
                geo.Freeze();
                return geo;
            }
            g = (Parse(d.Stroke), Parse(d.Fill), d.Weight);
            Parsed[Kind] = g;
        }
        var scale = Side / 24.0;
        dc.PushTransform(new ScaleTransform(scale, scale));
        if (g.Fill != null) dc.DrawGeometry(Foreground, null, g.Fill);
        if (g.Stroke != null)
        {
            var pen = new Pen(Foreground, g.Weight * WeightScale)
            {
                StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round,
            };
            dc.DrawGeometry(null, pen, g.Stroke);
        }
        dc.Pop();
    }
}

/// How a pressable shows a press: SwiftUI's PressStyle (shrink + dim) or IslandButtonStyle (the
/// capsule's fill deepens), or nothing.
internal enum PressLook { Shrink, Fill, Dim, None }

/// A clickable surface with no system chrome: never takes focus, presses on mouse-down, clicks on
/// mouse-up inside, and shows hover/press the Mac way.
internal class Tap : Border
{
    private readonly PressLook _look;
    private readonly ScaleTransform _scale = new(1, 1);
    private bool _down;
    private Brush? _rest;

    public Tap(UIElement child, PressLook look = PressLook.Shrink, string? tip = null)
    {
        Child = child;
        _look = look;
        Background = Brushes.Transparent;
        Cursor = Cursors.Hand;
        Focusable = false;
        ToolTip = tip;
        RenderTransformOrigin = new Point(0.5, 0.5);
        RenderTransform = _scale;
        VerticalAlignment = VerticalAlignment.Center;
        MouseLeftButtonDown += (_, e) =>
        {
            if (!IsEnabled) return;
            _down = true;
            CaptureMouse();
            Press(true);
            e.Handled = true;
        };
        MouseLeftButtonUp += (_, e) =>
        {
            if (!_down) return;
            _down = false;
            ReleaseMouseCapture();
            Press(false);
            var p = e.GetPosition(this);
            if (p.X >= 0 && p.Y >= 0 && p.X <= ActualWidth && p.Y <= ActualHeight) Click?.Invoke();
            e.Handled = true;
        };
        LostMouseCapture += (_, _) => { if (_down) { _down = false; Press(false); } };
        MouseEnter += (_, _) => Hover(true);
        MouseLeave += (_, _) => Hover(false);
        IsEnabledChanged += (_, _) => Opacity = IsEnabled ? 1 : 0.4;
    }

    public event Action? Click;

    /// The capsule fill at rest and pressed (PressLook.Fill).
    public Brush? PressedFill { get; set; }
    public Brush? HoverFill { get; set; }

    private void Press(bool down)
    {
        switch (_look)
        {
            case PressLook.Shrink:
                Animate(down ? 0.88 : 1, 0.12);
                Opacity = down ? 0.7 : 1;
                break;
            case PressLook.Dim:
                Opacity = down ? 0.6 : 1;
                break;
            case PressLook.Fill:
                if (down) { _rest ??= Background; if (PressedFill != null) Background = PressedFill; }
                else if (_rest != null) { Background = IsMouseOver && HoverFill != null ? HoverFill : _rest; }
                break;
        }
    }

    private void Hover(bool over)
    {
        if (_look != PressLook.Fill || HoverFill == null || _down) return;
        _rest ??= Background;
        Background = over ? HoverFill : _rest;
    }

    /// The rest fill changed (a capsule's state flipped): forget the cached one.
    public void SetFill(Brush fill)
    {
        _rest = fill;
        Background = fill;
    }

    private void Animate(double to, double seconds)
    {
        var a = new DoubleAnimation(to, TimeSpan.FromSeconds(seconds)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } };
        _scale.BeginAnimation(ScaleTransform.ScaleXProperty, a);
        _scale.BeginAnimation(ScaleTransform.ScaleYProperty, a);
    }
}

internal static class Controls
{
    /// IslandButtonStyle: 12 pt semibold in `tint`, a capsule of tint @16% (30% pressed).
    public static Tap IslandButton(string label, string tintKey, Action onClick, double tintOpacity = 1, string? tip = null)
    {
        var fg = K.A(tintKey, tintOpacity);
        var t = new Tap(K.T(label, 12, FontWeights.SemiBold, fg), PressLook.Fill, tip)
        {
            Background = K.A(tintKey, tintOpacity * 0.16),
            PressedFill = K.A(tintKey, tintOpacity * 0.30),
            HoverFill = K.A(tintKey, tintOpacity * 0.22),
            CornerRadius = new CornerRadius(999),
            Padding = new Thickness(10, 4, 10, 5),
        };
        t.Click += onClick;
        return t;
    }

    /// A bare icon in a frame (`Image(systemName:).frame(width:height:)` in a plain button).
    public static Tap IconButton(Sym icon, double glyph, Brush fg, Action onClick, double frameW, double frameH, string? tip = null, double weight = 1)
    {
        var host = new Grid { Width = frameW, Height = frameH, Background = Brushes.Transparent };
        host.Children.Add(new IconView(icon, glyph, fg, weight));
        var t = new Tap(host, PressLook.Shrink, tip);
        t.Click += onClick;
        return t;
    }

    /// A Fluent glyph in a frame, for the few symbols without a vector here.
    public static Tap GlyphButton(string glyph, double size, Brush fg, Action onClick, double frameW, double frameH, string? tip = null)
    {
        var host = new Grid { Width = frameW, Height = frameH, Background = Brushes.Transparent };
        host.Children.Add(K.Glyph(glyph, size, fg));
        var t = new Tap(host, PressLook.Shrink, tip);
        t.Click += onClick;
        return t;
    }

    /// The phone's liquid glass on a rounded shape: white @7% with a 0.5 hairline @12%.
    public static Border Glass(UIElement? child, double radius) =>
        K.Rounded(child, K.W(0.07), radius, 0, K.W(0.12));
}
