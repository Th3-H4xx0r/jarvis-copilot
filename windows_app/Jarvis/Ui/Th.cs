using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace Jarvis.Ui;

/// Small builders over Theme.xaml so code-built views never carry a colour literal
/// (ThemeInvariantTests): brushes by key, text, grey and primary buttons, rows.
internal static class Th
{
    public static Brush B(string key) => (Brush)Application.Current.FindResource(key);

    public static Style S(string key) => (Style)Application.Current.FindResource(key);

    public static readonly FontFamily Mono = new("Cascadia Mono, Consolas");

    public static TextBlock Text(string s, double size = 13, string brush = "JcText", bool bold = false, bool wrap = false, bool mono = false)
    {
        var t = new TextBlock
        {
            Text = s,
            FontSize = size,
            Foreground = B(brush),
            FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal,
            TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
            TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
        if (mono) t.FontFamily = Mono;
        return t;
    }

    /// A grey button (white@9%); `primary` = the one white-filled main action on a surface.
    public static Button Button(string label, Action onClick, bool primary = false, double size = 13)
    {
        var b = new Button
        {
            Content = label,
            Style = S(primary ? "JcPrimaryButtonStyle" : "JcButtonStyle"),
            FontSize = size,
            Focusable = false,
        };
        b.Click += (_, _) => onClick();
        return b;
    }

    /// A small round icon button (Segoe Fluent Icons glyph), 28 px by default.
    public static Button Icon(string glyph, string tip, Action onClick, double side = 28)
    {
        var b = new Button
        {
            Content = new TextBlock { Text = glyph, FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontSize = side * 0.45, Foreground = B("JcText") },
            ToolTip = tip,
            Width = side,
            Height = side,
            Style = S("JcButtonStyle"),
            Padding = new Thickness(0),
            Focusable = false,
        };
        b.Click += (_, _) => onClick();
        return b;
    }

    public static Border Dot(string brush, double side = 8) => new()
    {
        Width = side,
        Height = side,
        CornerRadius = new CornerRadius(side / 2),
        Background = B(brush),
        VerticalAlignment = VerticalAlignment.Center,
    };

    public static StackPanel Row(double gap, params UIElement[] children)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal };
        for (var i = 0; i < children.Length; i++)
        {
            if (i > 0 && children[i] is FrameworkElement fe) fe.Margin = new Thickness(gap, fe.Margin.Top, fe.Margin.Right, fe.Margin.Bottom);
            p.Children.Add(children[i]);
        }
        return p;
    }

    public static StackPanel Column(double gap, params UIElement[] children)
    {
        var p = new StackPanel { Orientation = Orientation.Vertical };
        for (var i = 0; i < children.Length; i++)
        {
            if (i > 0 && children[i] is FrameworkElement fe) fe.Margin = new Thickness(fe.Margin.Left, gap, fe.Margin.Right, fe.Margin.Bottom);
            p.Children.Add(children[i]);
        }
        return p;
    }

    /// A rounded surface block (cards inside the island and panes).
    public static Border Card(UIElement child, string brush = "JcButton", double pad = 12) => new()
    {
        Background = B(brush),
        CornerRadius = new CornerRadius(12),
        Padding = new Thickness(pad),
        Child = child,
    };

    public static TextBox Input(string placeholder = "", bool multiline = false)
    {
        var t = new TextBox
        {
            Background = B("JcButton"),
            Foreground = B("JcText"),
            CaretBrush = B("JcText"),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(8, 6, 8, 6),
            FontSize = 13,
            AcceptsReturn = multiline,
            TextWrapping = multiline ? TextWrapping.Wrap : TextWrapping.NoWrap,
            ToolTip = placeholder.Length > 0 ? placeholder : null,
        };
        return t;
    }

    public static CheckBox Switch(string label, bool on, Action<bool> changed)
    {
        var c = new CheckBox { Content = Text(label), IsChecked = on, Foreground = B("JcText"), Margin = new Thickness(0, 4, 0, 4) };
        c.Checked += (_, _) => changed(true);
        c.Unchecked += (_, _) => changed(false);
        return c;
    }
}
