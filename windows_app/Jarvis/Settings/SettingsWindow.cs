using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;
using System.Windows.Media;
using Jarvis.Core.Settings;
using Jarvis.Core.State;
using Jarvis.Ui;

namespace Jarvis.Settings;

/// Jarvis Settings, drawn as the Mac's (MacSettingsWindow.swift): a dark window, a sidebar with
/// "On this PC" and "Server" sections whose rows carry a tinted icon tile, and the selected pane
/// beside it under its title. Native panes are the Mac's grouped Form (SettingsForm); the
/// server's own sections show in one WebView2 that exists only while this window is open. A
/// normal window (it may take focus: he opened it).
public sealed partial class SettingsWindow : Window
{
    private static readonly Dictionary<string, Func<FrameworkElement>> Natives = new();
    private static SettingsWindow? _open;

    /// The Mac's "On this Mac" voice rows (native there, the server's pages here).
    private static readonly HashSet<string> OnThisPc = new() { "voice", "live", "speech", "voices" };

    private readonly AppState _state;
    private readonly StackPanel _sidebar = new() { Margin = new Thickness(10, 8, 10, 12) };
    private readonly TextBlock _title = Th.Text("", 15, "JcSetLabel", bold: true);
    private readonly TextBlock _subtitle = Th.Text("", 12, "JcSetSecondary", wrap: true);
    private readonly ContentControl _detail = new();
    private ServerPane? _server;
    private string _current = "general";

    /// Tasks 8/11/13 register the Power integrations, Talk and Flow views here.
    public static void RegisterNative(string id, Func<FrameworkElement> view) => Natives[id] = view;

    public static void Show(AppState state, string? paneId = null)
    {
        _open ??= new SettingsWindow(state);
        _open.Select(paneId ?? _open._current);
        if (!_open.IsVisible) ((Window)_open).Show();
        _open.Activate();
    }

    private SettingsWindow(AppState state)
    {
        _state = state;
        Title = "Jarvis Settings";
        Width = 920;
        Height = 640;
        MinWidth = 760;
        MinHeight = 520;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = Th.B("JcSetWindow");
        Foreground = Th.B("JcSetLabel");
        FontFamily = (FontFamily)FindResource("JcFont");
        FontSize = 13;
        UseLayoutRounding = true;
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Ideal);

        // The Mac's controls for everything inside this window (the island keeps its own look).
        Resources[typeof(CheckBox)] = Th.S("JcSetToggleStyle");
        Resources[typeof(ComboBox)] = Th.S("JcSetComboStyle");
        Resources[typeof(TextBox)] = Th.S("JcSetTextBoxStyle");
        Resources[typeof(PasswordBox)] = Th.S("JcSetPasswordBoxStyle");
        Resources[typeof(Slider)] = Th.S("JcSetSliderStyle");
        Resources[typeof(ScrollBar)] = Th.S("JcSetScrollBarStyle");
        Resources["JcButtonStyle"] = Th.S("JcSetButtonStyle");
        Resources["JcPrimaryButtonStyle"] = Th.S("JcSetPrimaryButtonStyle");
        Resources["JcInputStyle"] = Th.S("JcSetTextBoxStyle");

        var side = new ScrollViewer
        {
            Content = _sidebar,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Width = 220,
            Background = Th.B("JcSetSidebar"),
        };
        var divider = new Border { Width = 1, Background = Th.B("JcSetHairline") };

        _title.Margin = new Thickness(0, 0, 0, 0);
        _subtitle.Margin = new Thickness(0, 3, 0, 0);
        var head = new StackPanel { Margin = new Thickness(24, 16, 24, 14) };
        head.Children.Add(_title);
        head.Children.Add(_subtitle);
        var right = new DockPanel { LastChildFill = true };
        DockPanel.SetDock(head, Dock.Top);
        right.Children.Add(head);
        right.Children.Add(_detail);

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        Grid.SetColumn(divider, 1);
        Grid.SetColumn(right, 2);
        grid.Children.Add(side);
        grid.Children.Add(divider);
        grid.Children.Add(right);
        Content = grid;
        BuildSidebar();

        SourceInitialized += (_, _) => DarkTitleBar();
        Closed += (_, _) =>
        {
            _server?.Dispose();
            _server = null;
            _open = null;
        };
    }

    /// A dark caption the colour of the window, like the Mac's transparent title bar.
    private void DarkTitleBar()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        var on = 1;
        DwmSetWindowAttribute(hwnd, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, ref on, sizeof(int));
        if (Th.B("JcSetSidebar") is SolidColorBrush b)
        {
            var colorref = b.Color.R | (b.Color.G << 8) | (b.Color.B << 16);
            DwmSetWindowAttribute(hwnd, 35 /* DWMWA_CAPTION_COLOR */, ref colorref, sizeof(int));
        }
    }

    [LibraryImport("dwmapi.dll")]
    private static partial int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    private void BuildSidebar()
    {
        _sidebar.Children.Clear();
        AddHeader("On this PC", first: true);
        foreach (var pane in SettingsPanes.All.Where(p => p.Native || OnThisPc.Contains(p.Id))) AddRow(pane);
        AddHeader("Server", first: false);
        foreach (var pane in SettingsPanes.All.Where(p => !p.Native && !OnThisPc.Contains(p.Id))) AddRow(pane);
    }

    private void AddHeader(string text, bool first)
    {
        var h = Th.Text(text, 11, "JcSetTertiary", bold: true);
        h.Margin = new Thickness(10, first ? 6 : 16, 0, 5);
        _sidebar.Children.Add(h);
    }

    private void AddRow(SettingsPane p)
    {
        var selected = p.Id == _current;
        var tint = TryFindResource("JcTint." + p.Id) is Color c ? c : ((SolidColorBrush)Th.B("JcSetControl")).Color;
        var tile = new Border
        {
            Width = 22,
            Height = 22,
            CornerRadius = new CornerRadius(6),
            // SwiftUI's `tint.gradient`: a touch lighter at the top.
            Background = new LinearGradientBrush(Lighter(tint), tint, 90),
            Child = new TextBlock
            {
                Text = p.Glyph,
                FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"),
                FontSize = 12,
                Foreground = Th.B("JcText"),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            },
        };
        var label = Th.Text(p.Title, 13, "JcSetLabel");
        label.Margin = new Thickness(8, 0, 0, 0);
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(tile);
        row.Children.Add(label);
        var item = new Tap(row, PressLook.Fill)
        {
            Height = 30,
            Padding = new Thickness(6, 0, 6, 0),
            Margin = new Thickness(0, 1, 0, 1),
            CornerRadius = new CornerRadius(6),
            Background = selected ? Th.B("JcSetSelection") : Brushes.Transparent,
            HoverFill = selected ? Th.B("JcSetSelection") : Th.B("JcSetRowHover"),
            PressedFill = selected ? Th.B("JcSetSelection") : Th.B("JcSetRowHover"),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Center,
        };
        row.VerticalAlignment = VerticalAlignment.Center;
        item.Click += () => Select(p.Id);
        _sidebar.Children.Add(item);
    }

    private static Color Lighter(Color c) => Color.FromArgb(c.A,
        (byte)(c.R + (255 - c.R) * 0.22), (byte)(c.G + (255 - c.G) * 0.22), (byte)(c.B + (255 - c.B) * 0.22));

    /// `--diag settings-shot <pane>`: the window drawn to a PNG (desktop verification without
    /// bringing it in front of what he's doing).
    public static void Snapshot(AppState state, string paneId, string path)
    {
        var w = _open ?? new SettingsWindow(state);
        w.Select(paneId);
        var root = (FrameworkElement)w.Content;
        w.Dispatcher.BeginInvoke(() => Ui.Snap.Save(root, 920, 640, path), System.Windows.Threading.DispatcherPriority.ApplicationIdle);
    }

    public void Select(string id)
    {
        if (SettingsPanes.Find(id) is not { } pane) pane = SettingsPanes.All[0];
        _current = pane.Id;
        BuildSidebar();
        _title.Text = pane.Title;
        _subtitle.Text = "";
        _subtitle.Visibility = Visibility.Collapsed;
        if (pane.Native)
        {
            FrameworkElement view;
            if (Natives.TryGetValue(pane.Id, out var make))
            {
                view = make();
                if (view is StackPanel { Tag: Pane.Header h } page)
                {
                    _title.Text = h.Title;
                    if (h.Subtitle is { } sub) { _subtitle.Text = sub; _subtitle.Visibility = Visibility.Visible; }
                    SettingsForm.Group(page);
                }
            }
            else view = Th.Text($"{pane.Title} isn't available in this build yet.", 13, "JcSetSecondary");
            view.Margin = new Thickness(24, 0, 24, 24);
            _detail.Content = new ScrollViewer { Content = view, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
            return;
        }
        if (_state.ApiOrigin is not { } origin)
        {
            var t = Th.Text("Jarvis isn't connected to the server yet, so its Settings can't load.", 13, "JcSetSecondary", wrap: true);
            t.Margin = new Thickness(24, 0, 24, 24);
            _detail.Content = t;
            return;
        }
        _server ??= new ServerPane();
        _server.Navigate(ServerSettingsUrl.For(origin, pane.ServerSection!, pane.Panel, pane.Embed));
        _detail.Content = _server.View;
    }
}
