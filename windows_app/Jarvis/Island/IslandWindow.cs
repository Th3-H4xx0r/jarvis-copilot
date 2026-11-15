using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using Jarvis.Core.Island;
using Jarvis.Core.Model;
using Jarvis.Core.Prefs;
using Jarvis.Core.State;
using Jarvis.Core.Ui;
using Jarvis.Orb;
using Jarvis.Platform;
using Jarvis.Ui;

namespace Jarvis.Island;

/// The island, as the Mac draws it (IslandRootView): one black shape hanging from the top centre
/// that springs from the pill — the "notch" with two ears, the orb on the left and what's waiting
/// or working on the right — into the open island and back. The open content is laid out once at
/// its open size and the growing shape only reveals it; it fades in just after the shape opens and
/// out first when it closes, and the orb flies between the ear and its place in the open island.
///
/// It never takes focus (a no-activate tool window) unless he clicks into a text box. While the
/// presentation gate is closed (game mode, a fullscreen window in front) it's hidden, so it costs
/// nothing and can't knock a game out of exclusive fullscreen. Nothing animates while it rests:
/// the frame loop runs only while the shape or the orb is moving.
public sealed class IslandWindow : NoActivateWindow
{
    /// Room around the shape for its shadow (the window is the shape plus this, never the screen).
    private const double ShadowRoom = 40;

    private readonly IslandPresenter _p;
    private readonly AppState _state;
    private readonly PrefsStore _prefs;
    private readonly Grid _root = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top };
    private readonly Border _shadow = new() { Background = Brushes.Black, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top, IsHitTestVisible = false };
    private readonly DropShadowEffect _shadowFx = new() { Color = Colors.Black, BlurRadius = 28, ShadowDepth = 6, Direction = 270, Opacity = 0 };
    private readonly Grid _shape = new() { Background = Brushes.Black, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top, ClipToBounds = true };
    private readonly Grid _compact;
    private readonly Grid _expanded;
    private readonly Grid _tabRow = new() { Height = IslandLayout.TabsHeight };
    private readonly StackPanel _tabButtons = new() { Orientation = Orientation.Horizontal };
    private readonly StackPanel _rowRight = new() { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
    private readonly ContentControl _content = new() { Focusable = false };
    private readonly Dictionary<IslandTab, FrameworkElement> _tabs = new();
    private readonly System.Windows.Threading.DispatcherTimer _timer;

    // compact ears
    private readonly JarvisOrb _earOrb;
    private readonly Tap _earTap;
    private readonly Border _waitingPill;
    private readonly TextBlock _waitingText;
    private readonly JcLoader _earLoader = new() { Size = 12, Visibility = Visibility.Collapsed };
    private readonly TextBlock _usageText;

    // the tab row's orb
    private readonly JarvisOrb _rowOrb = new(18);
    private readonly Border _rowOrbBg;

    // the shape's motion
    private readonly Spring _w = new(IslandLayout.MorphResponse, IslandLayout.MorphDamping, IslandLayout.CompactWidth);
    private readonly Spring _h = new(IslandLayout.MorphResponse, IslandLayout.MorphDamping, IslandLayout.CompactHeight);
    private readonly Spring _r = new(IslandLayout.MorphResponse, IslandLayout.MorphDamping, IslandLayout.CompactRadius);
    private readonly OrbFlight _flight;
    private bool _looping;
    private TimeSpan _lastFrame;
    private IslandStateMachine.State _shownState = IslandStateMachine.State.Hidden;
    private IslandTab _shownTab;
    private double _openHeight = IslandLayout.ChatHeight;
    private double _winW, _winH;
    private bool _musicPlaying;
    private bool _holoAvailable;

    /// Slow motion for desktop verification (`--diag slowmo 10`): the springs run this many times slower.
    public static double TimeScale { get; set; } = 1;

    /// The ear's orb was clicked: talk to Jarvis.
    public event Action? TalkRequested;
    /// The tab row's hand: Holo Drop what's in front.
    public event Action? HoloRequested;

    public IslandWindow(IslandPresenter presenter, AppState state, PrefsStore prefs)
    {
        _p = presenter;
        _state = state;
        _prefs = prefs;
        Title = "Jarvis island";
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Ideal);
        TextOptions.SetTextRenderingMode(this, TextRenderingMode.Grayscale);
        UseLayoutRounding = true;

        // ── compact: the orb's ear, the notch, the status ear ──
        _earOrb = new JarvisOrb(Math.Max(12, IslandLayout.NotchHeight - 14));
        var earHost = new Grid { Width = IslandLayout.EarWidth, Height = IslandLayout.NotchHeight, Background = Brushes.Transparent };
        earHost.Children.Add(_earOrb);
        _earTap = new Tap(earHost, PressLook.Shrink, "Talk to Jarvis");
        _earTap.Click += () => TalkRequested?.Invoke();
        _waitingText = K.T("0", 12, FontWeights.Bold, Brushes.Black);
        _waitingPill = K.Capsule(_waitingText, K.A("JcAmber"), 6, 1);
        _waitingPill.HorizontalAlignment = HorizontalAlignment.Center;
        _earLoader.Foreground = K.A("JcGreen");
        _earLoader.HorizontalAlignment = HorizontalAlignment.Center;
        _earLoader.VerticalAlignment = VerticalAlignment.Center;
        _usageText = K.T("", 11, FontWeights.SemiBold, K.W(0.6));
        _usageText.HorizontalAlignment = HorizontalAlignment.Center;
        var rightEar = new Grid { Width = IslandLayout.EarWidth, Height = IslandLayout.NotchHeight };
        rightEar.Children.Add(_waitingPill);
        rightEar.Children.Add(_earLoader);
        rightEar.Children.Add(_usageText);
        _compact = new Grid
        {
            Width = IslandLayout.CompactWidth, Height = IslandLayout.NotchHeight,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top,
            Background = Brushes.Transparent, Cursor = Cursors.Hand,
        };
        _compact.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(IslandLayout.EarWidth) });
        _compact.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(IslandLayout.NotchWidth) });
        _compact.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(IslandLayout.EarWidth) });
        _compact.Children.Add(_earTap);
        Grid.SetColumn(rightEar, 2);
        _compact.Children.Add(rightEar);
        _compact.MouseLeftButtonUp += (_, e) => { if (!e.Handled) _p.Click(); };

        // ── open: the tab row, then the tab ──
        _rowOrbBg = new Border { Width = 26, Height = 26, CornerRadius = new CornerRadius(13), Child = _rowOrb };
        _tabRow.Children.Add(_tabButtons);
        _tabRow.Children.Add(_rowRight);
        var dock = new DockPanel { Margin = new Thickness(IslandLayout.PadX, IslandLayout.TopInset, IslandLayout.PadX, IslandLayout.PadBottom) };
        DockPanel.SetDock(_tabRow, Dock.Top);
        _content.Margin = new Thickness(0, IslandLayout.Gap, 0, 0);
        dock.Children.Add(_tabRow);
        dock.Children.Add(_content);
        _expanded = new Grid
        {
            Width = IslandLayout.Width, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top,
            Visibility = Visibility.Collapsed, Opacity = 0,
        };
        _expanded.Children.Add(dock);

        _shape.Children.Add(_expanded);
        _shape.Children.Add(_compact);
        _shadow.Effect = _shadowFx;
        _root.Children.Add(_shadow);
        _root.Children.Add(_shape);
        _flight = new OrbFlight(_root);
        _root.Children.Add(_flight.Layer);
        Content = _root;
        ApplyShape();

        _shape.MouseEnter += (_, _) => _p.HoverChanged(true);
        _shape.MouseLeave += (_, _) => _p.HoverChanged(false);
        Deactivated += (_, _) =>
        {
            if (!_p.Typing) return;
            EndTyping();
            _p.EndTyping();
            _p.ClickedOutside();
        };

        _timer = new System.Windows.Threading.DispatcherTimer(System.Windows.Threading.DispatcherPriority.Background) { Interval = TimeSpan.FromSeconds(1) };
        _timer.Tick += (_, _) => _p.Tick();

        _p.Changed += Render;
        _p.TypingRequested += () => Dispatcher.BeginInvoke(BeginTyping);
        _state.Changed += () => { if (_p.Visible) { RenderEars(); RenderRow(); } };
        _prefs.Changed += k => { if (k == PrefKeys.IslandDisplay.Name) Render(); };
        SourceInitialized += (_, _) => Render();
    }

    /// The panes: Agents, Chat, Music and the Voice stage.
    public void Register(IslandTab tab, FrameworkElement view)
    {
        _tabs[tab] = view;
        if (view is AgentsTab agents) agents.ContentResized += () => { if (_shownState == IslandStateMachine.State.Expanded && _p.Tab == IslandTab.Agents) Retarget(); };
        if (_p.Tab == tab) Render();
    }

    /// Music is playing: the ear's orb moves with it.
    public bool MusicPlaying
    {
        get => _musicPlaying;
        set { if (_musicPlaying == value) return; _musicPlaying = value; RenderEars(); }
    }

    /// Holo Drop is switched on: the tab row shows its hand.
    public bool HoloAvailable
    {
        get => _holoAvailable;
        set { if (_holoAvailable == value) return; _holoAvailable = value; RenderRow(); }
    }

    /// The first draw (AppHost.Start): the presenter may already say "compact" before any change.
    public void Refresh() => Render();

    // ── state → shape ────────────────────────────────────────────────

    private void Render()
    {
        if (!_p.Visible)
        {
            _timer.Stop();
            StopLoop();
            _flight.Cancel();
            _shownState = IslandStateMachine.State.Hidden;
            if (IsVisible) Hide();
            return;
        }
        if (_p.TimerNeeded) _timer.Start(); else _timer.Stop();

        var state = _p.State;
        var from = _shownState;
        var wasHidden = !IsVisible || from == IslandStateMachine.State.Hidden;
        var tabChanged = _shownTab != _p.Tab;
        _shownState = state;
        _shownTab = _p.Tab;

        RenderEars();
        if (state == IslandStateMachine.State.Expanded)
        {
            RenderRow();
            var view = _tabs.TryGetValue(_p.Tab, out var v) ? v : null;
            if (_content.Content != view) _content.Content = view;
            _openHeight = OpenHeight();
            _expanded.Height = _openHeight;
            if (from != IslandStateMachine.State.Expanded)
            {
                _expanded.Visibility = Visibility.Visible;
                Fade(_expanded, 1, 0.18, 0.07);
                Fade(_compact, 0, 0.14);
            }
        }
        else
        {
            if (from == IslandStateMachine.State.Expanded)
            {
                Fade(_expanded, 0, 0.08, 0, () =>
                {
                    if (_shownState == IslandStateMachine.State.Expanded) return;
                    _expanded.Visibility = Visibility.Collapsed;
                    _content.Content = null;   // a folded tab stops its loaders and timers
                });
            }
            Fade(_compact, 1, 0.14);
        }

        if (wasHidden)
        {
            // Out of nothing: the pill grows from a short bar, fading up as it does.
            _w.Snap(IslandLayout.NotchWidth * 0.7);
            _h.Snap(IslandLayout.CompactHeight);
            _r.Snap(IslandLayout.CompactRadius);
            _shape.Opacity = 0;
            _shadow.Opacity = 0;
            Fade(_shape, 1, 0.16);
            Fade(_shadow, 1, 0.16);
        }
        Retarget();
        if (!IsVisible) Show();
        Place();

        if (!wasHidden && from != state && !tabChanged || !wasHidden && from != state)
        {
            if (from == IslandStateMachine.State.Compact && state == IslandStateMachine.State.Expanded) FlyOut();
            else if (from == IslandStateMachine.State.Expanded && state == IslandStateMachine.State.Compact) FlyBack();
        }
    }

    private double OpenHeight()
    {
        if (_p.Tab == IslandTab.Agents && _tabs.TryGetValue(IslandTab.Agents, out var a) && a is AgentsTab agents)
        {
            var (top, list) = agents.Measure(IslandLayout.Width - 2 * IslandLayout.PadX);
            return IslandLayout.AgentsHeight(top, list);
        }
        return _p.Tab switch
        {
            IslandTab.Chat => IslandLayout.ChatHeight,
            IslandTab.Music => IslandLayout.MusicHeight,
            IslandTab.Voice => IslandLayout.VoiceHeight,
            _ => _p.Height,
        };
    }

    /// The shape's target changed (state, tab, or the Agents list grew): spring to it.
    private void Retarget()
    {
        var expanded = _shownState == IslandStateMachine.State.Expanded;
        if (expanded)
        {
            _openHeight = OpenHeight();
            _expanded.Height = _openHeight;
        }
        _w.Target = expanded ? IslandLayout.Width : IslandLayout.CompactWidth;
        _h.Target = expanded ? _openHeight : IslandLayout.CompactHeight;
        _r.Target = expanded ? IslandLayout.ExpandedRadius : IslandLayout.CompactRadius;
        if (!SystemParameters.ClientAreaAnimation)
        {
            _w.Snap(_w.Target);
            _h.Snap(_h.Target);
            _r.Snap(_r.Target);
        }
        FitWindow(growOnly: true);
        ApplyShape();
        StartLoop();
    }

    private void StartLoop()
    {
        if (_looping) return;
        _looping = true;
        _lastFrame = TimeSpan.Zero;
        CompositionTarget.Rendering += OnFrame;
    }

    private void StopLoop()
    {
        if (!_looping) return;
        _looping = false;
        CompositionTarget.Rendering -= OnFrame;
    }

    private void OnFrame(object? sender, EventArgs e)
    {
        var now = ((RenderingEventArgs)e).RenderingTime;
        if (now == _lastFrame) return;
        var dt = _lastFrame == TimeSpan.Zero ? 1.0 / 60 : Math.Min((now - _lastFrame).TotalSeconds, 0.05);
        dt /= TimeScale;
        _lastFrame = now;
        _w.Step(dt);
        _h.Step(dt);
        _r.Step(dt);
        var flying = _flight.Step(dt);
        ApplyShape();
        if (_w.IsSettled() && _h.IsSettled() && _r.IsSettled(0.05) && !flying)
        {
            _w.Snap(_w.Target);
            _h.Snap(_h.Target);
            _r.Snap(_r.Target);
            ApplyShape();
            StopLoop();
            FitWindow(growOnly: false);
        }
    }

    private void ApplyShape()
    {
        var w = Math.Max(1, _w.Value);
        var h = Math.Max(1, _h.Value);
        var r = Math.Clamp(_r.Value, 0, Math.Min(w, h) / 2);
        _shape.Width = w;
        _shape.Height = h;
        _shadow.Width = w;
        _shadow.Height = h;
        _shadow.CornerRadius = new CornerRadius(0, 0, r, r);
        _shape.Clip = BottomRounded(w, h, r);
        // The shadow is the open island's: none on the pill.
        var open = Math.Clamp((h - IslandLayout.CompactHeight) / Math.Max(1, _openHeight - IslandLayout.CompactHeight), 0, 1);
        _shadowFx.Opacity = 0.45 * open;
    }

    private static Geometry BottomRounded(double w, double h, double r)
    {
        var g = new StreamGeometry();
        using (var c = g.Open())
        {
            c.BeginFigure(new Point(0, 0), true, true);
            c.LineTo(new Point(w, 0), false, false);
            c.LineTo(new Point(w, h - r), false, false);
            c.ArcTo(new Point(w - r, h), new Size(r, r), 0, false, SweepDirection.Clockwise, false, false);
            c.LineTo(new Point(r, h), false, false);
            c.ArcTo(new Point(0, h - r), new Size(r, r), 0, false, SweepDirection.Clockwise, false, false);
        }
        g.Freeze();
        return g;
    }

    /// The window is the shape's box plus the shadow's margin: grown before a spring opens it,
    /// shrunk back once it rests (a small window is a cheap one to composite).
    private void FitWindow(bool growOnly)
    {
        var w = Math.Max(_w.Target, _w.Value);
        var h = Math.Max(_h.Target, _h.Value);
        if (_flight.Active) { w = IslandLayout.Width; h = Math.Max(h, _openHeight); }
        var ww = Math.Ceiling(w + 2 * ShadowRoom);
        var wh = Math.Ceiling(h + ShadowRoom);
        if (growOnly) { ww = Math.Max(ww, _winW); wh = Math.Max(wh, _winH); }
        if (Math.Abs(ww - _winW) < 0.5 && Math.Abs(wh - _winH) < 0.5) return;
        _winW = ww;
        _winH = wh;
        Width = ww;
        Height = wh;
        _root.Width = ww;
        _root.Height = wh;
        Place();
    }

    private static void Fade(UIElement e, double to, double seconds, double delay = 0, Action? done = null)
    {
        var a = new DoubleAnimation(to, TimeSpan.FromSeconds(seconds))
        {
            BeginTime = TimeSpan.FromSeconds(delay),
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
        };
        if (done != null) a.Completed += (_, _) => done();
        e.BeginAnimation(OpacityProperty, a);
    }

    // ── the orb's flight ────────────────────────────────────────────

    private FrameworkElement? Home() => _p.Tab switch
    {
        IslandTab.Agents when _tabs.GetValueOrDefault(IslandTab.Agents) is AgentsTab a => a.HeaderOrb,
        IslandTab.Voice when _tabs.GetValueOrDefault(IslandTab.Voice) is Voice.VoiceTab v => v.StageOrb,
        _ => _rowOrb,
    };

    private void FlyOut()
    {
        if (!SystemParameters.ClientAreaAnimation) return;
        _expanded.UpdateLayout();
        if (Home() is not { } home || !home.IsVisible) return;
        _flight.Start(true, _earOrb, home, _state.Connected ? _state.Mood : OrbMood.Idle);
        FitWindow(growOnly: true);
        StartLoop();
    }

    private void FlyBack()
    {
        if (!SystemParameters.ClientAreaAnimation) return;
        if (Home() is not { } home || !home.IsVisible) return;
        _flight.Start(false, _earOrb, home, OrbMood.Idle);
        StartLoop();
    }

    // ── content ─────────────────────────────────────────────────────

    private void RenderEars()
    {
        var waiting = _state.WaitingCount;
        var working = _state.WorkingCount;
        _waitingPill.Visibility = waiting > 0 ? Visibility.Visible : Visibility.Collapsed;
        _waitingText.Text = waiting.ToString(System.Globalization.CultureInfo.InvariantCulture);
        _earLoader.Visibility = waiting == 0 && working > 0 ? Visibility.Visible : Visibility.Collapsed;
        var five = _state.Usage?.Five?.UsedNow(DateTimeOffset.UtcNow);
        _usageText.Text = waiting == 0 && working == 0 && five is { } f ? $"{f}%" : "";
        var dancing = _musicPlaying && _state.Mood == OrbMood.Idle;
        _earOrb.Dancing = dancing;
        _earOrb.Mood = _state.Connected && !dancing ? _state.Mood : OrbMood.Idle;
    }

    private void RenderRow()
    {
        _tabButtons.Children.Clear();
        foreach (var t in IslandTabs.TabBar.Where(_tabs.ContainsKey))
        {
            var tab = t;
            var on = _p.Tab == t;
            var fg = on ? K.W(1) : K.W(0.55);
            var row = K.H(5, new IconView(TabIcon(t), t == IslandTab.Chat ? 16 : t == IslandTab.Music ? 15 : 14, fg, 1.2));
            if (on) K.Add(row, K.T(t.Title(), 11, FontWeights.SemiBold, fg), 5);
            var b = new Tap(row, PressLook.Dim, t.Title())
            {
                Padding = new Thickness(9, 5, 9, 5),
                CornerRadius = new CornerRadius(999),
                Background = on ? K.W(0.10) : Brushes.Transparent,
                Margin = new Thickness(_tabButtons.Children.Count == 0 ? 0 : 4, 0, 0, 0),
            };
            b.Click += () => _p.SelectTab(tab);
            _tabButtons.Children.Add(b);
        }

        _rowRight.Children.Clear();
        if (_p.Tab != IslandTab.Agents && _state.WaitingCount > 0)
        {
            var w = new Tap(K.Capsule(K.T($"{_state.WaitingCount} waiting", 11, FontWeights.Bold, Brushes.Black), K.A("JcAmber"), 8, 3), PressLook.Dim);
            w.Click += () => _p.SelectTab(IslandTab.Agents);
            w.Margin = new Thickness(0, 0, 4, 0);
            _rowRight.Children.Add(w);
        }
        if (_holoAvailable)
        {
            var hand = new Grid { Width = 26, Height = 26 };
            hand.Children.Add(new Ellipse { Fill = K.W(0.06) });
            hand.Children.Add(new IconView(Sym.Hand, 14, K.W(0.75)));
            var h = new Tap(hand, PressLook.Shrink, "Holo Drop what's in front (Ctrl+Alt+H)") { Margin = new Thickness(0, 0, 4, 0) };
            h.Click += () => { _p.Close(); HoloRequested?.Invoke(); };
            _rowRight.Children.Add(h);
        }
        if (_tabs.ContainsKey(IslandTab.Voice))
        {
            var voice = _p.Tab == IslandTab.Voice;
            _rowOrb.Listening = voice;
            _rowOrbBg.Background = voice ? K.A("JcAccent", 0.22) : K.W(0.06);
            if (_rowOrbBg.Parent is Tap old) old.Child = null;
            var orb = new Tap(_rowOrbBg, PressLook.Shrink, "Talk to Jarvis") { Margin = new Thickness(0, 0, 4, 0) };
            orb.Click += () => _p.SelectTab(_p.Tab == IslandTab.Voice ? IslandTab.Agents : IslandTab.Voice);
            _rowRight.Children.Add(orb);
        }
        var fold = Controls.IconButton(Sym.ChevronUp, 13, K.W(0.6), _p.Close, 22, 26, "Fold", 1.1);
        _rowRight.Children.Add(fold);
    }

    private static Sym TabIcon(IslandTab t) => t switch
    {
        IslandTab.Agents => Sym.Terminal,
        IslandTab.Chat => Sym.Chat,
        IslandTab.Music => Sym.MusicNote,
        _ => Sym.Waveform,
    };

    private void Place()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero || _winW <= 0) return;
        var monitors = Monitors.All();
        if (monitors.Count == 0) return;
        var bounds = IslandPlacement.ChooseMonitor(_prefs.Get(PrefKeys.IslandDisplay), Monitors.ForPlacement(), Monitors.Cursor());
        var mon = monitors.FirstOrDefault(m => m.Bounds == bounds) ?? monitors[0];
        var scale = Monitors.Scale(mon.Handle);
        Monitors.Place(hwnd, IslandPlacement.Frame(bounds, _winW * scale, _winH * scale));
    }
}

/// The orb in flight between the compact island's ear and its place in the open island (the Mac's
/// FlyingOrb): it drops out of the ear, glides into place growing to home's size with a soft
/// accent light mid-flight, swells a touch as it lands, and the orb in its place takes over.
internal sealed class OrbFlight
{
    private const double Big = 80;
    private readonly FrameworkElement _root;
    private readonly JarvisOrb _orb = new(Big);
    private readonly Ellipse _glow = new() { IsHitTestVisible = false };
    private readonly Spring _progress = new(IslandLayout.OrbOutResponse, IslandLayout.OrbOutDamping);
    private (double X, double Y, double Side) _ear, _home;
    private FrameworkElement? _hiddenEar, _hiddenHome;
    private double _elapsed, _landing;

    public OrbFlight(FrameworkElement root)
    {
        _root = root;
        _glow.Fill = K.A("JcAccent", 0.3);
        _glow.Effect = new BlurEffect { Radius = 12 };
        Layer.Children.Add(_glow);
        Layer.Children.Add(_orb);
        Layer.Visibility = Visibility.Collapsed;
    }

    public Canvas Layer { get; } = new() { IsHitTestVisible = false, ClipToBounds = false };
    public bool Active { get; private set; }

    public void Start(bool outward, FrameworkElement ear, FrameworkElement home, OrbMood mood)
    {
        Cancel();
        _ear = Box(ear);
        _home = Box(home);
        if (_ear.Side <= 0 || _home.Side <= 0) return;
        _hiddenEar = ear;
        _hiddenHome = home;
        ear.Opacity = 0;
        home.Opacity = 0;
        _orb.Mood = mood;
        if (outward)
        {
            _progress.Response = IslandLayout.OrbOutResponse;
            _progress.DampingFraction = IslandLayout.OrbOutDamping;
            _progress.Snap(0);
            _progress.Target = 1;
            _landing = 0.62;
        }
        else
        {
            _progress.Response = IslandLayout.OrbBackResponse;
            _progress.DampingFraction = IslandLayout.OrbBackDamping;
            _progress.Snap(1);
            _progress.Target = 0;
            _landing = 0.38;
        }
        _elapsed = 0;
        Active = true;
        Layer.Visibility = Visibility.Visible;
        Apply();
    }

    /// Advance the flight; false once it has landed.
    public bool Step(double dt)
    {
        if (!Active) return false;
        _elapsed += dt;
        _progress.Step(dt);
        Apply();
        if (_elapsed >= _landing) Cancel();
        return Active;
    }

    public void Cancel()
    {
        if (_hiddenEar != null) _hiddenEar.Opacity = 1;
        if (_hiddenHome != null) _hiddenHome.Opacity = 1;
        _hiddenEar = _hiddenHome = null;
        Active = false;
        Layer.Visibility = Visibility.Collapsed;
    }

    private void Apply()
    {
        var t = _progress.Value;
        var p = OrbPath.At(t, _ear, _home);
        var scale = p.Side / Big;
        _orb.RenderTransform = new ScaleTransform(scale, scale);
        _orb.RenderTransformOrigin = new Point(0.5, 0.5);
        Canvas.SetLeft(_orb, p.X - Big / 2);
        Canvas.SetTop(_orb, p.Y - Big / 2);
        var g = p.Side * 1.8;
        _glow.Width = g;
        _glow.Height = g;
        _glow.Opacity = OrbPath.Glow(t);
        Canvas.SetLeft(_glow, p.X - g / 2);
        Canvas.SetTop(_glow, p.Y - g / 2);
    }

    private (double X, double Y, double Side) Box(FrameworkElement e)
    {
        try
        {
            var r = e.TransformToAncestor(_root).TransformBounds(new Rect(0, 0, e.ActualWidth, e.ActualHeight));
            return (r.X + r.Width / 2, r.Y + r.Height / 2, r.Width);
        }
        catch (InvalidOperationException) { return (0, 0, 0); }
    }
}
