using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Jarvis.Core.Island;
using Jarvis.Core.Model;
using Jarvis.Core.Prefs;
using Jarvis.Core.State;
using Jarvis.Platform;
using Jarvis.Ui;

namespace Jarvis.Island;

/// The black tab hanging from the top-centre of the screen. It never takes focus (a no-activate
/// tool window) unless he clicks into a text box. It renders what IslandPresenter says; while
/// the presentation gate is closed (game mode, or a fullscreen window in front) it is hidden, so
/// it costs nothing and can't knock a game out of exclusive fullscreen.
public sealed class IslandWindow : NoActivateWindow
{
    private readonly IslandPresenter _p;
    private readonly AppState _state;
    private readonly PrefsStore _prefs;
    private readonly Border _shape;
    private readonly Grid _compact;
    private readonly DockPanel _expanded;
    private readonly StackPanel _tabBar;
    private readonly ContentControl _content;
    private readonly Dictionary<IslandTab, FrameworkElement> _tabs = new();
    private readonly DispatcherTimer _timer;
    private readonly JcLoader _compactLoader;
    private readonly Border _compactDot;
    private readonly TextBlock _compactText;

    public IslandWindow(IslandPresenter presenter, AppState state, PrefsStore prefs)
    {
        _p = presenter;
        _state = state;
        _prefs = prefs;
        Title = "Jarvis island";
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;

        _compactLoader = new JcLoader { Size = 14, Foreground = Th.B("JcGreen"), Visibility = Visibility.Collapsed };
        _compactDot = Th.Dot("JcTextFaint");
        _compactText = Th.Text("Jarvis", 12, "JcTextDim");
        var compactRow = Th.Row(8, _compactLoader, _compactDot, _compactText);
        compactRow.HorizontalAlignment = HorizontalAlignment.Center;
        _compact = new Grid { Background = Brushes.Transparent, Children = { compactRow } };

        _tabBar = new StackPanel { Orientation = Orientation.Horizontal, Height = IslandLayout.TabsHeight };
        _content = new ContentControl();
        _expanded = new DockPanel { Margin = new Thickness(12, 6, 12, 10), Visibility = Visibility.Collapsed };
        DockPanel.SetDock(_tabBar, Dock.Top);
        _expanded.Children.Add(_tabBar);
        _expanded.Children.Add(_content);

        _shape = new Border
        {
            Background = Th.B("JcBackground"),
            CornerRadius = new CornerRadius(0, 0, 14, 14),
            Child = new Grid { Children = { _compact, _expanded } },
            Cursor = Cursors.Hand,
        };
        Content = _shape;

        _shape.MouseEnter += (_, _) => _p.HoverChanged(true);
        _shape.MouseLeave += (_, _) => _p.HoverChanged(false);
        _compact.MouseLeftButtonUp += (_, _) => _p.Click();
        Deactivated += (_, _) =>
        {
            if (!_p.Typing) return;
            EndTyping();
            _p.EndTyping();
            _p.ClickedOutside();
        };

        _timer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromSeconds(1) };
        _timer.Tick += (_, _) => _p.Tick();

        _p.Changed += Render;
        _p.TypingRequested += () => Dispatcher.BeginInvoke(BeginTyping);
        _state.Changed += () => { if (_p.Visible) RenderCompact(); };
        _prefs.Changed += k => { if (k == PrefKeys.IslandDisplay.Name) Render(); };
        SourceInitialized += (_, _) => Render();
    }

    /// Tasks 10/15 plug the Voice, Chat and Music views in here.
    public void Register(IslandTab tab, FrameworkElement view)
    {
        _tabs[tab] = view;
        RebuildTabBar();
        if (_p.Tab == tab) Render();
    }

    private void RebuildTabBar()
    {
        _tabBar.Children.Clear();
        foreach (var t in IslandTabs.TabBar.Where(_tabs.ContainsKey))
        {
            var tab = t;
            var b = Th.Button(t.Title(), () => _p.SelectTab(tab), size: 12);
            b.Padding = new Thickness(10, 2, 10, 2);
            b.Margin = new Thickness(0, 0, 6, 0);
            b.Background = Th.B(_p.Tab == t ? "JcButtonSelected" : "JcButton");
            _tabBar.Children.Add(b);
        }
        if (_tabs.ContainsKey(IslandTab.Voice))
        {
            var orb = Th.Icon("", "Talk to Jarvis", () => _p.SelectTab(IslandTab.Voice), 24);
            orb.Margin = new Thickness(6, 0, 0, 0);
            _tabBar.Children.Add(orb);
        }
        var fold = Th.Icon("", "Fold", _p.Close, 24);
        fold.Margin = new Thickness(6, 0, 0, 0);
        _tabBar.Children.Add(fold);
    }

    /// The first draw (AppHost.Start): the presenter may already say "compact" before any change.
    public void Refresh() => Render();

    private void Render()
    {
        if (!_p.Visible)
        {
            _timer.Stop();
            if (IsVisible) Hide();
            return;
        }
        if (_p.TimerNeeded) _timer.Start(); else _timer.Stop();

        var expanded = _p.State == IslandStateMachine.State.Expanded;
        _compact.Visibility = expanded ? Visibility.Collapsed : Visibility.Visible;
        _expanded.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
        if (expanded)
        {
            RebuildTabBar();
            _content.Content = _tabs.TryGetValue(_p.Tab, out var v) ? v : null;
        }
        else
        {
            _content.Content = null;   // a hidden tab view stops its loaders and timers
            RenderCompact();
        }

        Width = _p.Width;
        Height = _p.Height;
        if (!IsVisible) Show();
        Place();
    }

    private void RenderCompact()
    {
        var waiting = _state.WaitingCount;
        var working = _state.WorkingCount;
        _compactLoader.Visibility = waiting == 0 && working > 0 ? Visibility.Visible : Visibility.Collapsed;
        _compactDot.Visibility = _compactLoader.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
        _compactDot.Background = Th.B(waiting > 0 ? "JcAmber" : _state.Connected ? "JcTextFaint" : "JcRed");
        _compactText.Text = waiting > 0 ? (waiting == 1 ? "Needs you" : $"{waiting} need you")
            : working > 0 ? $"{working} working"
            : _state.Connected ? "Jarvis" : "Jarvis is offline";
    }

    private void Place()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero) return;
        var monitors = Monitors.All();
        if (monitors.Count == 0) return;
        var bounds = IslandPlacement.ChooseMonitor(_prefs.Get(PrefKeys.IslandDisplay), Monitors.ForPlacement(), Monitors.Cursor());
        var mon = monitors.FirstOrDefault(m => m.Bounds == bounds) ?? monitors[0];
        var scale = Monitors.Scale(mon.Handle);
        Monitors.Place(hwnd, IslandPlacement.Frame(bounds, _p.Width * scale, _p.Height * scale));
    }
}
