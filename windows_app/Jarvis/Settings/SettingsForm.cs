using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using Jarvis.Ui;

namespace Jarvis.Settings;

/// The Mac's grouped Form (`.formStyle(.grouped)`) for the native panes: each section is a header
/// above a rounded card of rows, an inset hairline between rows, a footer below. Panes still add
/// their parts to one StackPanel (Pane.Section, rows, notes); Group() lays that list out as cards,
/// keeping the panel itself (panes hold on to it for key handling and re-renders).
internal static class SettingsForm
{
    public const string SectionTag = "section", FooterTag = "footer", RowTag = "row", CardsTag = "cards", GroupTag = "group";

    /// Pads `content` as a Form row with a hairline along its top (the first row's is clipped away
    /// by its card), so rows built later (a re-rendered list) still separate themselves.
    public static FrameworkElement Row(UIElement content)
    {
        var g = new Grid { Tag = RowTag };
        g.Children.Add(new Rectangle { Height = 1, Fill = Th.B("JcSetSeparator"), VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(12, 0, 0, 0) });
        g.Children.Add(new Border { Padding = new Thickness(12, 9, 12, 9), Child = content });
        return g;
    }

    /// A rounded card holding rows (already Row()s, or lists of them).
    public static Border Card(IEnumerable<UIElement> rows)
    {
        var stack = new StackPanel { Margin = new Thickness(0, -1, 0, 0) };
        foreach (var r in rows) stack.Children.Add(r);
        var card = new Border
        {
            Background = Th.B("JcSetCard"),
            BorderBrush = Th.B("JcSetHairline"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            Child = stack,
        };
        // Clip to the rounded shape so the first row's hairline and any row fill stay inside.
        stack.SizeChanged += (_, e) => stack.Clip = new RectangleGeometry(
            new Rect(0, 1, e.NewSize.Width, Math.Max(0, e.NewSize.Height - 1)), 9, 9);
        return card;
    }

    /// Lays out a pane's StackPanel as the Mac's grouped Form, in place.
    public static void Group(StackPanel page)
    {
        var parts = Flatten(page.Children.Cast<UIElement>().ToList());
        page.Children.Clear();
        page.MaxWidth = double.PositiveInfinity;
        page.HorizontalAlignment = HorizontalAlignment.Stretch;

        string? header = null;
        var rows = new List<UIElement>();
        var first = true;

        void Flush(UIElement? footer = null)
        {
            if (header == null && rows.Count == 0 && footer == null) return;
            var section = new StackPanel { Margin = new Thickness(0, first ? 0 : 20, 0, 0) };
            first = false;
            if (header != null)
            {
                var h = Th.Text(header, 13, "JcSetLabel", bold: true);
                h.Margin = new Thickness(2, 0, 0, 7);
                section.Children.Add(h);
            }
            if (rows.Count > 0) section.Children.Add(Card(rows.ToList()));
            if (footer != null) section.Children.Add(footer);
            page.Children.Add(section);
            header = null;
            rows.Clear();
        }

        foreach (var part in parts)
        {
            switch ((part as FrameworkElement)?.Tag)
            {
                case SectionTag:
                    Flush();
                    header = ((TextBlock)part).Text;
                    break;
                case FooterTag:
                    if (part is FrameworkElement f) f.Margin = new Thickness(2, 6, 2, 0);
                    Flush(part);
                    break;
                case CardsTag:
                    Flush();
                    if (part is FrameworkElement c) c.Margin = new Thickness(0, first ? 0 : 20, 0, 0);
                    first = false;
                    page.Children.Add(part);
                    break;
                case RowTag:
                    rows.Add(part);
                    break;
                default:
                    rows.Add(part is StackPanel { Orientation: Orientation.Vertical } list ? list : AutoRow(part));
                    break;
            }
        }
        Flush();
    }

    /// Pane.Group(...) parts are spliced into the page's own list.
    private static List<UIElement> Flatten(List<UIElement> parts)
    {
        var flat = new List<UIElement>();
        foreach (var p in parts)
        {
            if (p is Panel { Tag: GroupTag } group)
            {
                var inner = group.Children.Cast<UIElement>().ToList();
                group.Children.Clear();
                flat.AddRange(Flatten(inner));
            }
            else flat.Add(p);
        }
        return flat;
    }

    /// A row around anything else; a status line that is empty right now is hidden until it says
    /// something (panes fill them in later).
    private static FrameworkElement AutoRow(UIElement part)
    {
        if (part is FrameworkElement fe) fe.Margin = new Thickness(0);
        var row = Row(part);
        if (part is TextBlock t)
        {
            void Sync() => row.Visibility = string.IsNullOrEmpty(t.Text) ? Visibility.Collapsed : Visibility.Visible;
            DependencyPropertyDescriptor.FromProperty(TextBlock.TextProperty, typeof(TextBlock)).AddValueChanged(t, (_, _) => Sync());
            Sync();
        }
        return row;
    }
}
