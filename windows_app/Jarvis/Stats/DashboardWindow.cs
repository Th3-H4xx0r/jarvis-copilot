using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using Jarvis.Core.Http;
using Jarvis.Core.Link;
using Jarvis.Core.Prefs;
using Jarvis.Core.State;
using Jarvis.Core.Stats;
using Jarvis.Orb;
using Jarvis.Platform;
using Jarvis.Ui;

namespace Jarvis.Stats;

/// PC Stats on the side monitor (look B): a normal borderless window — he can move, minimise or
/// cover it; it never takes focus on its own — filling the monitor chosen in PC Stats settings.
/// The orb header has the dashboard switcher and Edit; the body is the dashboard's 12-column grid.
/// Each device remembers its own dashboard; this one switches to the "game" dashboard while a game
/// runs. Edit mode: drag to move, the corner grip to resize, + to add, click to restyle; Done
/// saves with the dashboard's revision (409 → reload).
public sealed class DashboardWindow : Window
{
    private readonly ApiClient _api;
    private readonly StatsService _stats;
    private readonly AppState _state;
    private readonly PrefsStore _prefs;
    private readonly SeriesBuffer _series = new();
    private readonly Grid _grid = new();
    private readonly Canvas _overlay = new() { IsHitTestVisible = false };
    private readonly TextBlock _name = new(), _status = new();
    private readonly ComboBox _switcher = new() { MinWidth = 170 };
    private readonly StackPanel _editBar = new() { Orientation = Orientation.Horizontal, Visibility = Visibility.Collapsed };
    private readonly Border _panelHost = new() { Width = 320, Visibility = Visibility.Collapsed };
    private readonly Button _editButton;
    private readonly List<WidgetView> _views = new();
    private readonly Dictionary<string, string> _labels = new(), _units = new();
    private List<Dashboard> _boards = new();
    private Dashboard? _board;
    private string? _autoFrom;
    private bool _editing;
    private WidgetFrame? _lastFrame;
    private int _rows = 8;

    public static readonly PrefKey<string> ActivePref = new("pcStats.active", "overview");

    public DashboardWindow(ApiClient api, StatsService stats, AppState state, PrefsStore prefs)
    {
        _api = api;
        _stats = stats;
        _state = state;
        _prefs = prefs;
        Title = "PC Stats";
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.CanResize;
        // No frame line along the top: the client area is the whole window, edges still resize.
        System.Windows.Shell.WindowChrome.SetWindowChrome(this, new System.Windows.Shell.WindowChrome
        {
            CaptionHeight = 0, GlassFrameThickness = new Thickness(0), ResizeBorderThickness = new Thickness(6),
            CornerRadius = new CornerRadius(0), UseAeroCaptionButtons = false,
        });
        ShowActivated = false;
        ShowInTaskbar = true;
        Background = Th.B("JcStatsBg");
        Foreground = Th.B("JcText");
        FontFamily = (FontFamily)FindResource("JcFont");
        UseLayoutRounding = true;
        Resources[typeof(ComboBox)] = Th.S("JcSetComboStyle");
        Resources[typeof(TextBox)] = Th.S("JcSetTextBoxStyle");
        Resources[typeof(CheckBox)] = Th.S("JcSetToggleStyle");
        Resources[typeof(ScrollBar)] = Th.S("JcSetScrollBarStyle");
        Resources["JcButtonStyle"] = Th.S("JcSetButtonStyle");
        Resources["JcPrimaryButtonStyle"] = Th.S("JcSetPrimaryButtonStyle");

        _name.FontSize = 16; _name.FontWeight = FontWeights.SemiBold;
        _status.FontSize = 13; _status.Foreground = Th.B("JcStatsLabel");
        _editButton = Pill("Edit", () => SetEditing(!_editing));
        _switcher.SelectionChanged += (_, _) =>
        {
            if (_switcher.SelectedItem is ComboBoxItem { Tag: string id } && id != _board?.Id) { _autoFrom = null; Select(id, remember: true); }
        };
        _editBar.Children.Add(Pill("+ Widget", AddWidget));
        _editBar.Children.Add(Pill("New dashboard", NewBoard));
        _editBar.Children.Add(Pill("Delete dashboard", DeleteBoard));

        var header = new DockPanel { Margin = new Thickness(26, 22, 26, 10) };
        var orb = new JarvisOrb(30) { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 14, 0) };
        var titles = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        titles.Children.Add(_name);
        titles.Children.Add(_status);
        var right = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        right.Children.Add(_editBar);
        right.Children.Add(_switcher);
        right.Children.Add(_editButton);
        right.Children.Add(Pill("—", () => WindowState = WindowState.Minimized));
        DockPanel.SetDock(orb, Dock.Left);
        DockPanel.SetDock(right, Dock.Right);
        header.Children.Add(orb);
        header.Children.Add(right);
        header.Children.Add(titles);
        header.MouseLeftButtonDown += (_, e) => { if (e.ClickCount == 1 && !_editing) try { DragMove(); } catch (InvalidOperationException) { } };

        var body = new Grid { Margin = new Thickness(19, 0, 19, 19) };
        body.Children.Add(_grid);
        body.Children.Add(_overlay);
        var main = new DockPanel();
        DockPanel.SetDock(_panelHost, Dock.Right);
        main.Children.Add(_panelHost);
        main.Children.Add(body);
        var root = new DockPanel();
        DockPanel.SetDock(header, Dock.Top);
        root.Children.Add(header);
        root.Children.Add(main);
        Content = root;

        _stats.Sample += OnSample;
        _state.GameModeChanged += _ => Dispatcher.BeginInvoke(AutoSwitch);
        Closed += (_, _) => _stats.Sample -= OnSample;
        Loaded += async (_, _) => await LoadAsync();
    }

    private static Button Pill(string label, Action click)
    {
        var b = Th.Button(label, click, size: 12.5);
        b.Margin = new Thickness(8, 0, 0, 0);
        return b;
    }

    // ── placement ───────────────────────────────────────────────────────

    /// Fills the work area of `monitor` ("" → the first monitor that isn't the main one).
    public void Place(string monitor)
    {
        var all = Monitors.All();
        var m = monitor.Length > 0 ? all.FirstOrDefault(x => x.Name.EndsWith(monitor, StringComparison.OrdinalIgnoreCase))
            : all.Where(x => !x.Primary).OrderBy(x => x.Bounds.Left).LastOrDefault();
        m ??= Monitors.Primary();
        if (m == null) return;
        if (!IsVisible) Show();
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd != IntPtr.Zero) Monitors.Place(hwnd, m.Work);
    }

    // ── data ────────────────────────────────────────────────────────────

    private async Task LoadAsync()
    {
        try
        {
            var cat = await _api.GetAsync("/api/pc-stats/catalog", TimeSpan.FromSeconds(10));
            foreach (var (k, v) in J.Obj(cat["readings"]))
            {
                _labels[k] = J.S(J.Obj(v)["label"], k);
                _units[k] = J.S(J.Obj(v)["unit"]);
            }
            var list = await _api.GetAsync("/api/pc-stats/dashboards", TimeSpan.FromSeconds(10));
            _boards = J.Arr(list["dashboards"]).Select(Dashboard.Parse).ToList();
        }
        catch (ApiException e)
        {
            _status.Text = e.Status == 409 ? "PC Stats is switched off" : $"Couldn't load dashboards: {e.Error}";
            return;
        }
        Select(_state.GameMode.On ? (_boards.FirstOrDefault(b => b.Auto == "game")?.Id ?? _prefs.Get(ActivePref)) : _prefs.Get(ActivePref), remember: false);
        await SeedHistoryAsync();
    }

    private async Task SeedHistoryAsync()
    {
        if (_board == null || _state.DeviceId is not { } device) return;
        var keys = _board.Widgets.Where(w => w.Kind is "hero" or "chart" or "sparkline").SelectMany(w => w.Readings).Distinct();
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        foreach (var k in keys)
        {
            try
            {
                var r = await _api.GetAsync($"/api/pc-stats/history?device_id={device}&key={Uri.EscapeDataString(k)}&from={now - 3600}&to={now}&points=360", TimeSpan.FromSeconds(10));
                _series.Seed(k, (r["points"] as JsonArray ?? new JsonArray()).OfType<JsonArray>().Select(p => (J.D(p[0]) ?? 0, J.D(p[1]) ?? 0)));
            }
            catch (ApiException) { }
        }
    }

    private void OnSample(StatsSample s, IReadOnlySet<string> estimated, bool driverOff)
    {
        Dispatcher.BeginInvoke(() =>
        {
            _series.Add(s);
            _lastFrame = new WidgetFrame(s, estimated, driverOff && !_stats.DriverOn, _series, _labels, _units);
            _name.Text = Environment.MachineName.ToLowerInvariant();
            _status.Text = (s.Game is { } g ? $"Gaming · {System.IO.Path.GetFileNameWithoutExtension(g)}" : "Live") +
                           (_stats.HelperConnected ? "" : " · sensor helper not running (Settings → PC power)");
            if (WindowState == WindowState.Minimized || !IsVisible) return;   // nothing drawn while out of sight
            foreach (var v in _views) v.Update(_lastFrame);
        });
    }

    private void AutoSwitch()
    {
        var game = _boards.FirstOrDefault(b => b.Auto == "game");
        if (game == null || _editing) return;
        if (_state.GameMode.On && _board?.Id != game.Id) { _autoFrom = _board?.Id; Select(game.Id, remember: false); }
        else if (!_state.GameMode.On && _autoFrom != null) { var back = _autoFrom; _autoFrom = null; Select(back, remember: false); }
    }

    private void Select(string id, bool remember)
    {
        _board = _boards.FirstOrDefault(b => b.Id == id) ?? _boards.FirstOrDefault();
        if (_board == null) return;
        if (remember) _prefs.Set(ActivePref, _board.Id);
        _switcher.Items.Clear();
        foreach (var b in _boards) _switcher.Items.Add(new ComboBoxItem { Content = b.Name, Tag = b.Id, IsSelected = b.Id == _board.Id });
        Build();
    }

    // ── layout ──────────────────────────────────────────────────────────

    private void Build()
    {
        _grid.Children.Clear();
        _grid.ColumnDefinitions.Clear();
        _grid.RowDefinitions.Clear();
        _views.Clear();
        if (_board == null) return;
        // The dashboard fills the monitor: its rows share the height (two spare rows while editing).
        _rows = Math.Max(4, DashboardLayout.Rows(_board) + (_editing ? 2 : 0));
        for (var c = 0; c < Dashboard.Columns; c++) _grid.ColumnDefinitions.Add(new ColumnDefinition());
        for (var r = 0; r < _rows; r++) _grid.RowDefinitions.Add(new RowDefinition());
        foreach (var w in _board.Widgets)
        {
            var v = WidgetView.For(w);
            Grid.SetColumn(v, w.X);
            Grid.SetRow(v, Math.Min(w.Y, _rows - 1));
            Grid.SetColumnSpan(v, w.W);
            Grid.SetRowSpan(v, Math.Max(1, Math.Min(w.H, _rows - w.Y)));
            if (_editing) MakeEditable(v);
            _grid.Children.Add(v);
            _views.Add(v);
            if (_lastFrame != null) v.Update(_lastFrame);
        }
        DrawGridLines();
    }

    private void DrawGridLines()
    {
        _overlay.Children.Clear();
        if (!_editing) return;
        _overlay.UpdateLayout();
        double cw = _grid.ActualWidth / Dashboard.Columns, rh = _grid.ActualHeight / _rows;
        for (var c = 1; c < Dashboard.Columns; c++)
            _overlay.Children.Add(new Line { X1 = c * cw, X2 = c * cw, Y1 = 0, Y2 = _grid.ActualHeight, Stroke = Th.B("JcStatsGrid"), StrokeDashArray = new DoubleCollection { 2, 4 } });
        for (var r = 1; r < _rows; r++)
            _overlay.Children.Add(new Line { X1 = 0, X2 = _grid.ActualWidth, Y1 = r * rh, Y2 = r * rh, Stroke = Th.B("JcStatsGrid"), StrokeDashArray = new DoubleCollection { 2, 4 } });
    }

    // ── editing ─────────────────────────────────────────────────────────

    private void SetEditing(bool on)
    {
        if (!on && _editing) _ = SaveAsync();
        _editing = on;
        _editButton.Content = on ? "Done" : "Edit";
        _editBar.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        if (!on) _panelHost.Visibility = Visibility.Collapsed;
        Build();
    }

    private void MakeEditable(WidgetView v)
    {
        v.Cursor = Cursors.SizeAll;
        v.BorderBrush = Th.B("JcSetAccent");
        var grip = new Border { Width = 16, Height = 16, Background = Th.B("JcSetAccent"), CornerRadius = new CornerRadius(4), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, Cursor = Cursors.SizeNWSE, Margin = new Thickness(0, 0, -8, -8) };
        if (v.Child is UIElement inner)
        {
            v.Child = null;
            var host = new Grid();
            host.Children.Add(inner);
            host.Children.Add(grip);
            v.Child = host;
        }
        Point start = default;
        Widget original = v.Widget;
        var resizing = false;
        void Down(object s, MouseButtonEventArgs e)
        {
            start = e.GetPosition(_grid);
            original = Current(v.Widget.Id) ?? v.Widget;
            resizing = ReferenceEquals(s, grip);
            ((UIElement)s).CaptureMouse();
            e.Handled = true;
        }
        void Move(object s, MouseEventArgs e)
        {
            if (!((UIElement)s).IsMouseCaptured) return;
            double cw = _grid.ActualWidth / Dashboard.Columns, rh = _grid.ActualHeight / _rows;
            var p = e.GetPosition(_grid);
            int dx = (int)Math.Round((p.X - start.X) / cw), dy = (int)Math.Round((p.Y - start.Y) / rh);
            var moved = resizing
                ? original with { W = Math.Max(1, original.W + dx), H = Math.Max(1, original.H + dy) }
                : original with { X = Math.Max(0, original.X + dx), Y = Math.Max(0, original.Y + dy) };
            if (_board != null && DashboardLayout.CanPlace(_board, moved) && moved != Current(moved.Id))
            {
                Replace(moved);
                Build();
            }
        }
        void Up(object s, MouseButtonEventArgs e)
        {
            var el = (UIElement)s;
            if (!el.IsMouseCaptured) return;
            el.ReleaseMouseCapture();
            if (!resizing && (e.GetPosition(_grid) - start).Length < 4) ShowSettings(Current(v.Widget.Id) ?? v.Widget);
        }
        v.MouseLeftButtonDown += Down; v.MouseMove += Move; v.MouseLeftButtonUp += Up;
        grip.MouseLeftButtonDown += Down; grip.MouseMove += Move; grip.MouseLeftButtonUp += Up;
    }

    private Widget? Current(string id) => _board?.Widgets.FirstOrDefault(w => w.Id == id);

    private void Replace(Widget w)
    {
        if (_board == null) return;
        _board = _board with { Widgets = _board.Widgets.Select(x => x.Id == w.Id ? w : x).ToList() };
        _boards = _boards.Select(b => b.Id == _board.Id ? _board : b).ToList();
    }

    private void AddWidget()
    {
        if (_board == null) return;
        var (x, y) = DashboardLayout.AutoPlace(_board, 3, 2);
        var w = new Widget($"w{DateTime.UtcNow.Ticks % 100_000_000}", "number", x, y, 3, 2, new[] { "gpu.temp" }, new WidgetStyle());
        _board = _board with { Widgets = _board.Widgets.Append(w).ToList() };
        _boards = _boards.Select(b => b.Id == _board.Id ? _board : b).ToList();
        Build();
        ShowSettings(w);
    }

    private void NewBoard()
    {
        var id = $"board{DateTime.UtcNow.Ticks % 100_000_000}";
        var b = new Dashboard(id, "New dashboard", null, Array.Empty<Widget>(), null);
        _boards.Add(b);
        Select(id, remember: true);
        ShowBoardSettings();
    }

    private async void DeleteBoard()
    {
        if (_board == null || _boards.Count <= 1) return;
        var id = _board.Id;
        try { await _api.DeleteAsync($"/api/pc-stats/dashboards/{id}", TimeSpan.FromSeconds(10)); } catch (ApiException) { }
        _boards.RemoveAll(b => b.Id == id);
        Select(_boards[0].Id, remember: true);
    }

    private async Task SaveAsync()
    {
        if (_board == null) return;
        var body = new JsonObject { ["dashboard"] = _board.ToJson(), ["rev"] = _board.Rev };
        try
        {
            var reply = await _api.PutAsync($"/api/pc-stats/dashboards/{_board.Id}", body, TimeSpan.FromSeconds(10));
            var saved = Dashboard.Parse(J.Obj(reply["dashboard"]));
            _boards = _boards.Select(b => b.Id == saved.Id ? saved : b).ToList();
            _board = saved;
            _status.Text = "Saved";
        }
        catch (ApiException e) when (e.Status == 409)
        {
            _status.Text = "Changed elsewhere — reloaded";
            await LoadAsync();
        }
        catch (ApiException e)
        {
            _status.Text = $"Couldn't save: {e.Error}";
        }
    }

    // ── the settings panel ──────────────────────────────────────────────

    private void ShowBoardSettings()
    {
        if (_board == null) return;
        var name = new TextBox { Text = _board.Name };
        var auto = new CheckBox { Content = Label("Show while a game runs"), IsChecked = _board.Auto == "game" };
        var panel = Panel("Dashboard",
            Field("Name", name), auto,
            Th.Button("Apply", () =>
            {
                _board = _board with { Name = name.Text.Trim().Length > 0 ? name.Text.Trim() : _board.Name, Auto = auto.IsChecked == true ? "game" : null };
                _boards = _boards.Select(b => b.Id == _board.Id ? _board : b).ToList();
                Select(_board.Id, remember: true);
            }, primary: true));
        _panelHost.Child = panel;
        _panelHost.Visibility = Visibility.Visible;
    }

    private void ShowSettings(Widget w)
    {
        var kind = new ComboBox();
        foreach (var k in Dashboard.Kinds) kind.Items.Add(new ComboBoxItem { Content = k, Tag = k, IsSelected = k == w.Kind });
        var readings = new TextBox { Text = string.Join(", ", w.Readings), ToolTip = string.Join(", ", _labels.Keys) };
        var label = new TextBox { Text = w.Style.Label ?? "" };
        var chart = new ComboBox();
        foreach (var c in new[] { "area", "line", "none" }) chart.Items.Add(new ComboBoxItem { Content = c, Tag = c, IsSelected = c == (w.Style.Chart ?? "area") });
        var color = new TextBox { Text = w.Style.Color ?? "" };
        var warn = new TextBox { Text = w.Style.Warn?.ToString() ?? "" };
        var crit = new TextBox { Text = w.Style.Crit?.ToString() ?? "" };
        var window = new TextBox { Text = (w.Style.Window ?? 600).ToString() };
        var meta = new TextBox { Text = string.Join(", ", w.Style.Meta ?? Array.Empty<string>()) };
        var error = Label("");
        error.Foreground = Th.B("JcAmber");
        var panel = Panel("Widget",
            Field("Kind", kind), Field("Readings (comma separated)", readings), Field("Label", label), Field("Chart", chart),
            Field("Colour (#RRGGBB)", color), Field("Amber at", warn), Field("Red at", crit), Field("Time window (s)", window),
            Field("Extra readings under it", meta), error,
            Th.Button("Apply", () =>
            {
                static List<string> Split(string s) => s.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList();
                static double? Num(string s) => double.TryParse(s, out var d) ? d : null;
                var keys = Split(readings.Text);
                var unknown = keys.Concat(Split(meta.Text)).Where(k => !_labels.ContainsKey(k) && !k.StartsWith("fan.") && !k.StartsWith("temp.")).ToList();
                if (unknown.Count > 0) { error.Text = "Unknown: " + string.Join(", ", unknown); return; }
                var updated = w with
                {
                    Kind = (kind.SelectedItem as ComboBoxItem)?.Tag as string ?? w.Kind,
                    Readings = keys,
                    Style = new WidgetStyle((chart.SelectedItem as ComboBoxItem)?.Tag as string, color.Text.Trim().Length == 7 ? color.Text.Trim() : null,
                        Num(warn.Text), Num(crit.Text), int.TryParse(window.Text, out var win) ? Math.Clamp(win, 60, 86400) : null,
                        w.Style.Decimals, Split(meta.Text) is { Count: > 0 } m ? m : null, label.Text.Trim().Length > 0 ? label.Text.Trim() : null, w.Style.Unit),
                };
                Replace(updated);
                Build();
            }, primary: true),
            Th.Button("Delete widget", () =>
            {
                if (_board == null) return;
                _board = _board with { Widgets = _board.Widgets.Where(x => x.Id != w.Id).ToList() };
                _boards = _boards.Select(b => b.Id == _board.Id ? _board : b).ToList();
                _panelHost.Visibility = Visibility.Collapsed;
                Build();
            }),
            Th.Button("Dashboard settings…", ShowBoardSettings));
        _panelHost.Child = panel;
        _panelHost.Visibility = Visibility.Visible;
    }

    private static TextBlock Label(string s) => new() { Text = s, Foreground = Th.B("JcStatsMeta"), FontSize = 12.5, TextWrapping = TextWrapping.Wrap };

    private static FrameworkElement Field(string label, UIElement control)
    {
        var p = new StackPanel { Margin = new Thickness(0, 0, 0, 12) };
        var l = Label(label);
        l.Margin = new Thickness(0, 0, 0, 4);
        p.Children.Add(l);
        p.Children.Add(control);
        return p;
    }

    private static Border Panel(string title, params UIElement[] children)
    {
        var col = new StackPanel { Margin = new Thickness(18) };
        col.Children.Add(new TextBlock { Text = title, FontSize = 15, FontWeight = FontWeights.SemiBold, Foreground = Th.B("JcText"), Margin = new Thickness(0, 0, 0, 14) });
        foreach (var c in children)
        {
            if (c is Button b) b.Margin = new Thickness(0, 4, 0, 4);
            col.Children.Add(c);
        }
        return new Border
        {
            Background = Th.B("JcStatsGlass"), BorderBrush = Th.B("JcStatsHairline"), BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(18), Margin = new Thickness(0, 0, 19, 19),
            Child = new ScrollViewer { Content = col, VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
        };
    }
}
