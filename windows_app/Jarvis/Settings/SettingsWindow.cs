using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Jarvis.Core.Settings;
using Jarvis.Core.State;
using Jarvis.Ui;

namespace Jarvis.Settings;

/// Settings: a sidebar of the Mac's native panes, then the server's own Settings sections shown
/// in one WebView2 that exists only while this window is open. A normal window (it may take
/// focus: he opened it).
public sealed class SettingsWindow : Window
{
    private static readonly Dictionary<string, Func<FrameworkElement>> Natives = new();
    private static SettingsWindow? _open;

    private readonly AppState _state;
    private readonly StackPanel _sidebar = new() { Margin = new Thickness(10) };
    private readonly ContentControl _content = new() { Margin = new Thickness(20, 16, 20, 16) };
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
        Width = 980;
        Height = 680;
        MinWidth = 760;
        MinHeight = 480;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = Th.B("JcBackground");
        Foreground = Th.B("JcText");

        var side = new ScrollViewer { Content = _sidebar, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Width = 230, Background = Th.B("JcSurface") };
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        Grid.SetColumn(side, 0);
        var scroll = new ScrollViewer { Content = _content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Grid.SetColumn(scroll, 1);
        grid.Children.Add(side);
        grid.Children.Add(scroll);
        Content = grid;
        BuildSidebar();

        Closed += (_, _) =>
        {
            _server?.Dispose();
            _server = null;
            _open = null;
        };
    }

    private void BuildSidebar()
    {
        _sidebar.Children.Clear();
        var serverHeader = false;
        foreach (var pane in SettingsPanes.All)
        {
            if (!pane.Native && !serverHeader)
            {
                serverHeader = true;
                var h = Th.Text("Jarvis server", 11, "JcTextFaint", bold: true);
                h.Margin = new Thickness(8, 14, 0, 4);
                _sidebar.Children.Add(h);
            }
            var p = pane;
            var row = Th.Row(10,
                new TextBlock { Text = p.Glyph, FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontSize = 14, Foreground = Th.B("JcTextDim"), VerticalAlignment = VerticalAlignment.Center },
                Th.Text(p.Title, 13));
            var b = new Button
            {
                Content = row,
                Style = Th.S("JcButtonStyle"),
                HorizontalContentAlignment = HorizontalAlignment.Left,
                Background = p.Id == _current ? Th.B("JcButtonSelected") : Brushes.Transparent,
                Margin = new Thickness(0, 1, 0, 1),
                Padding = new Thickness(10, 7, 10, 7),
                Tag = p.Id,
            };
            b.Click += (_, _) => Select(p.Id);
            _sidebar.Children.Add(b);
        }
    }

    public void Select(string id)
    {
        if (SettingsPanes.Find(id) is not { } pane) pane = SettingsPanes.All[0];
        _current = pane.Id;
        BuildSidebar();
        if (pane.Native)
        {
            _content.Content = Natives.TryGetValue(pane.Id, out var make)
                ? make()
                : Th.Text($"{pane.Title} isn't available in this build yet.", 13, "JcTextDim");
            return;
        }
        if (_state.ApiOrigin is not { } origin)
        {
            _content.Content = Th.Text("Jarvis isn't connected to the server yet, so its Settings can't load.", 13, "JcTextDim", wrap: true);
            return;
        }
        _server ??= new ServerPane();
        _server.Navigate(ServerSettingsUrl.For(origin, pane.ServerSection!, pane.Panel, pane.Embed));
        _content.Content = _server.View;
    }
}
