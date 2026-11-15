using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using Jarvis.Core.Island;
using Jarvis.Core.Model;
using Jarvis.Core.State;
using Jarvis.Orb;
using Jarvis.Ui;

namespace Jarvis.Island;

/// The Agents tab, as on the Mac (IslandViews' agents): the header (orb, "Agents", the summary,
/// the usage pills that open the limits card, the terminal jump), what waits on him first (an
/// approval or question card answered right here), then every session with its current step; a
/// session opens on its recent steps and changed files. Past the island's height the list scrolls
/// with a slim bar. Rebuilt only while it's on screen.
public sealed class AgentsTab : Border
{
    private readonly AppState _state;
    private readonly IslandPresenter _p;
    private readonly Func<NoActivateWindow?> _window;
    private readonly StackPanel _top = new();
    private readonly StackPanel _list = new();
    private readonly ScrollViewer _scroll;
    private readonly Border _thumb = new() { Width = 4, CornerRadius = new CornerRadius(2), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, IsHitTestVisible = false };
    private string _cardFingerprint = "";
    private FrameworkElement? _card;
    private string? _selectedKey;
    private string? _openFile;
    private bool _showLimits;

    /// The limits card under the header (the usage pills toggle it).
    public bool ShowLimits
    {
        get => _showLimits;
        set { _showLimits = value; if (IsVisible) Rebuild(); }
    }

    /// The header's orb: where the island's orb lands when it opens on Agents.
    public JarvisOrb HeaderOrb { get; } = new(22);

    /// Jump to a session's terminal.
    public event Action<AgentSession>? JumpRequested;
    /// A harness job's Read aloud.
    public event Action<HarnessJob>? ReadAloudRequested;
    /// The header orb: open Voice.
    public event Action? TalkRequested;
    /// What it holds changed size: the island springs to the new height.
    public event Action? ContentResized;

    public AgentsTab(AppState state, IslandPresenter presenter, Func<NoActivateWindow?> window)
    {
        _state = state;
        _p = presenter;
        _window = window;
        _scroll = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = _list,
            Focusable = false,
        };
        _scroll.ScrollChanged += (_, _) => UpdateThumb();
        var listHost = new Grid { Margin = new Thickness(0, IslandLayout.Gap, 0, 0) };
        listHost.Children.Add(_scroll);
        _thumb.Background = K.W(0.35);
        _thumb.Margin = new Thickness(0, 0, -10, 0);
        listHost.Children.Add(_thumb);
        var dock = new DockPanel();
        DockPanel.SetDock(_top, Dock.Top);
        dock.Children.Add(_top);
        dock.Children.Add(listHost);
        Child = dock;

        state.Changed += () => { if (IsVisible) Rebuild(); };
        IsVisibleChanged += (_, _) => { if (IsVisible) Rebuild(); };
    }

    /// What the island measures: the part above the list and the list's whole content.
    public (double Top, double List) Measure(double width)
    {
        if (_top.Children.Count == 0) Rebuild(announce: false);
        _top.Measure(new Size(width, double.PositiveInfinity));
        _list.Measure(new Size(width, double.PositiveInfinity));
        return (_top.DesiredSize.Height, _list.DesiredSize.Height);
    }

    public void Rebuild() => Rebuild(announce: true);

    private void Rebuild(bool announce)
    {
        _top.Children.Clear();
        _list.Children.Clear();
        K.Add(_top, Header(), 0);
        var usage = _state.Usage;
        var codex = _state.CodexUsage;
        if (_showLimits && (usage != null || codex != null)) K.Add(_top, LimitsCard(usage, codex), 10);
        if (!_state.Connected)
            K.Add(_top, K.T("Jarvis isn't running on this PC — restart it from the tray menu.", 12, null, K.W(0.6), wrap: true), 10);
        if (_p.Notice is { } notice)
        {
            K.Add(_top, K.T(notice, 12, null, K.A("JcAmber"), wrap: true), 10);
            _p.ClearNotice();
        }
        if (_state.Flash is { } flash) K.Add(_top, FlashRow(flash), 10);
        if (_state.Pending.FirstOrDefault() is { } pending)
        {
            // Keyed by the request: a card that replaces another starts fresh and ignores clicks briefly.
            if (pending.Fingerprint != _cardFingerprint || _card == null)
            {
                _cardFingerprint = pending.Fingerprint;
                _card = pending.IsQuestion
                    ? new QuestionCard(_state, pending, _window)
                    : new ApprovalCard(_state, pending, _window, _state.Pending.Count - 1);
            }
            if (_card.Parent is Panel old) old.Children.Remove(_card);
            _card.Margin = new Thickness(0);
            K.Add(_top, _card, 10);
        }
        else
        {
            _cardFingerprint = "";
            _card = null;
        }

        if (_state.Sessions.Count == 0 && _state.Jobs.Count == 0 && _state.Connected)
            K.Add(_list, K.T("No agent sessions. Start Claude Code (or Codex, Gemini…) and it shows up here.", 12, null, K.W(0.55), wrap: true), 6);
        // What Jarvis handed to a bigger model, first: it's what he just asked for.
        foreach (var j in _state.Jobs)
        {
            K.Add(_list, JobRow(j), 6);
            if (_selectedKey == j.Key) K.Add(_list, JobDetail(j), 6);
        }
        foreach (var s in _state.Sessions)
        {
            K.Add(_list, SessionRow(s), 6);
            if (_selectedKey == s.Key) K.Add(_list, SessionDetail(s), 6);
        }
        foreach (var m in _state.OnServer) K.Add(_list, OnServerRow(m), 6);
        Dispatcher.BeginInvoke(UpdateThumb);
        if (announce) ContentResized?.Invoke();
    }

    private void UpdateThumb()
    {
        var t = IslandLayout.ScrollThumb(_scroll.ExtentHeight, _scroll.ViewportHeight, _scroll.VerticalOffset);
        _thumb.Visibility = t == null ? Visibility.Collapsed : Visibility.Visible;
        if (t is { } th)
        {
            _thumb.Height = th.Length;
            _thumb.Margin = new Thickness(0, th.Start, -10, 0);
        }
    }

    private void Toggle(string key)
    {
        _selectedKey = _selectedKey == key ? null : key;
        _openFile = null;
        Rebuild();
    }

    // ── header ──────────────────────────────────────────────────────

    private FrameworkElement Header()
    {
        HeaderOrb.Mood = _state.Mood;
        if (HeaderOrb.Parent is Tap oldTap) oldTap.Child = null;
        var orb = new Tap(HeaderOrb, PressLook.Shrink, "Talk to Jarvis");
        orb.Click += () => TalkRequested?.Invoke();
        var titles = K.V(1, K.T("Agents", 14, FontWeights.Bold), K.T(Summary(), 11, null, K.W(0.55)));
        var left = K.H(10, orb, titles);

        var right = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        if (_state.Usage != null || _state.CodexUsage != null)
        {
            var pills = new StackPanel { Orientation = Orientation.Horizontal };
            var now = DateTimeOffset.UtcNow;
            if (_state.Usage is { } u)
            {
                K.Add(pills, UsagePill("5h", u.Five?.UsedNow(now)), 6);
                K.Add(pills, UsagePill("wk", u.Week?.UsedNow(now)), 6);
            }
            if (_state.CodexUsage is { } c) K.Add(pills, UsagePill("Codex", (c.Five ?? c.Week)?.UsedNow(now)), 6);
            var tap = new Tap(pills, PressLook.Dim, _showLimits ? "Hide the limits" : "Show the limits");
            tap.Click += () => { _showLimits = !_showLimits; Rebuild(); };
            K.Add(right, tap, 0);
        }
        var term = Controls.IconButton(Sym.Terminal, 15, K.W(0.8), () =>
        {
            var target = _state.Sessions.FirstOrDefault(s => s.Key == _selectedKey) ?? _state.Lead ?? _state.Sessions.FirstOrDefault();
            if (target != null) JumpRequested?.Invoke(target);
        }, 22, 22, "Jump to the session's terminal (Ctrl+Alt+T)");
        K.Add(right, term, 10);
        return K.Spread(left, right, 10);
    }

    private string Summary()
    {
        if (_state.WaitingCount > 0) return $"{_state.WaitingCount} waiting on you";
        if (_state.WorkingCount > 0) return $"{_state.WorkingCount} working";
        var n = _state.Sessions.Count;
        return $"{n} session{(n == 1 ? "" : "s")}";
    }

    private static FrameworkElement UsagePill(string label, int? pct)
    {
        var key = IslandLayout.UsageColorKey(pct);
        var text = pct is { } p ? $"{label} {p}%" : $"{label} –";
        return K.Capsule(K.T(text, 10, FontWeights.SemiBold, K.A(key)), K.A(key, 0.15), 6, 2);
    }

    // ── limits ──────────────────────────────────────────────────────

    private static FrameworkElement LimitsCard(PlanUsage? claude, PlanUsage? codex)
    {
        var g = new Grid();
        var cards = new List<FrameworkElement>();
        if (claude != null) cards.Add(AgentLimits("Claude", claude));
        if (codex != null) cards.Add(AgentLimits("Codex", codex));
        for (var i = 0; i < cards.Count; i++)
        {
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            Grid.SetColumn(cards[i], i);
            cards[i].Margin = new Thickness(i == 0 ? 0 : 5, 0, i == cards.Count - 1 ? 0 : 5, 0);
            cards[i].VerticalAlignment = VerticalAlignment.Top;
            g.Children.Add(cards[i]);
        }
        return g;
    }

    private static FrameworkElement AgentLimits(string name, PlanUsage usage)
    {
        var now = DateTimeOffset.UtcNow;
        var col = K.V(9, K.T($"{name} usage", 13, FontWeights.SemiBold));
        if (usage.Five is { } f) K.Add(col, LimitRow("Current session", f, UsagePace.FiveHours, now), 9);
        if (usage.Week is { } w) K.Add(col, LimitRow("Weekly · all models", w, UsagePace.Week, now), 9);
        return K.Rounded(col, K.W(0.05), 12, 11);
    }

    private static FrameworkElement LimitRow(string title, UsageWindow window, TimeSpan length, DateTimeOffset now)
    {
        var resetsAt = window.ResetsAt;
        var reset = resetsAt is { } ra && ra <= now;
        var used = reset ? 0 : window.Used;
        var pace = reset || resetsAt == null ? 0 : UsagePace.Pace(used, resetsAt.Value, length, now);
        var when = resetsAt == null ? "Not started" : reset ? "Reset" : $"Resets in {UsagePace.ResetsIn(resetsAt.Value, now)}";
        var head = K.Spread(K.T(title, 11.5, FontWeights.Medium, K.W(0.9)), K.T(when, 10.5, null, K.W(0.45)), 6);
        var bar = new Grid { Height = 5 };
        bar.Children.Add(new Border { Background = K.W(0.10), CornerRadius = new CornerRadius(2.5) });
        var fill = new Border { Background = K.A(IslandLayout.LimitColorKey(used)), CornerRadius = new CornerRadius(2.5), HorizontalAlignment = HorizontalAlignment.Left };
        bar.Children.Add(fill);
        bar.SizeChanged += (_, e) => fill.Width = e.NewSize.Width * used / 100.0;
        var line = new TextBlock { FontFamily = K.Font, FontSize = 10.5, TextTrimming = TextTrimming.CharacterEllipsis };
        line.Inlines.Add(new System.Windows.Documents.Run($"{used}% used · {100 - used}% left") { Foreground = K.W(0.75) });
        if (Math.Abs(pace) >= 0.5)
        {
            var one = Math.Abs(pace).ToString("0.0", CultureInfo.InvariantCulture);
            line.Inlines.Add(new System.Windows.Documents.Run(pace > 0 ? $" · {one}% deficit" : $" · {one}% reserved")
            { Foreground = pace > 0 ? K.A("JcAmber") : K.W(0.45) });
        }
        return K.V(5, head, bar, line);
    }

    // ── rows ────────────────────────────────────────────────────────

    private static string StateKey(SessionState s) => s switch
    {
        SessionState.Working or SessionState.Thinking => "JcGreen",
        SessionState.Approval or SessionState.Question => "JcAmber",
        SessionState.Finished => "JcAccent",
        SessionState.Error => "JcOrbRed",
        SessionState.RateLimit => "JcSysOrange",
        _ => "JcMuted",
    };

    /// The row's state at its leading edge: the loader in the working green while it runs,
    /// otherwise the state's dot; one 14 pt slot either way.
    private static FrameworkElement StateMark(SessionState s, bool running)
    {
        var slot = new Grid { Width = 14, Height = 14, Margin = new Thickness(0, 2, 0, 0), VerticalAlignment = VerticalAlignment.Top };
        if (running) slot.Children.Add(new JcLoader { Size = 14, Foreground = K.A(StateKey(s)) });
        else slot.Children.Add(new Ellipse { Width = 8, Height = 8, Fill = K.A(StateKey(s)) });
        return slot;
    }

    private Tap RowCard(UIElement content, bool selected, Action onClick)
    {
        var t = new Tap(content, PressLook.None)
        {
            Padding = new Thickness(8),
            CornerRadius = new CornerRadius(10),
            Background = K.W(selected ? 0.10 : 0.05),
            HoverFill = K.W(selected ? 0.12 : 0.08),
            VerticalAlignment = VerticalAlignment.Top,
        };
        t.Click += onClick;
        t.MouseEnter += (_, _) => t.Background = K.W(selected ? 0.12 : 0.08);
        t.MouseLeave += (_, _) => t.Background = K.W(selected ? 0.10 : 0.05);
        return t;
    }

    private FrameworkElement SessionRow(AgentSession s)
    {
        var running = s.State is SessionState.Working or SessionState.Thinking;
        var title = K.H(8, K.T(s.Project, 13, FontWeights.SemiBold), K.T($"{s.AgentName} · {s.State.Label()}", 11, null, K.W(0.5)));
        var text = K.V(2, title);
        if (s.Step.Length > 0) K.Add(text, K.T(s.Step, 11, null, K.W(0.75), mono: true), 2);
        var row = K.H(10, StateMark(s.State, running), text);
        var card = RowCard(row, _selectedKey == s.Key, () => Toggle(s.Key));
        card.ToolTip = s.Cwd.Length > 0 ? s.Cwd : null;
        return card;
    }

    private FrameworkElement SessionDetail(AgentSession s)
    {
        var col = new StackPanel { Margin = new Thickness(12, 0, 12, 6) };
        if (s.Prompt.Length > 0)
        {
            var p = K.T(s.Prompt, 11, null, K.W(0.8), wrap: true);
            p.MaxHeight = 45;
            K.Add(col, p, 6);
        }
        foreach (var step in s.Steps.TakeLast(5)) K.Add(col, K.T($"› {step}", 10, null, K.W(0.55), mono: true), 6);
        foreach (var f in s.Files)
        {
            var file = f;
            var name = K.H(4, new IconView(Sym.Doc, 11, K.W(0.85)), K.T(f.Name, 11, null, K.W(0.85)));
            var counts = K.H(4, K.T($"+{f.Added}", 10, null, K.A("JcSysGreen"), mono: true), K.T($"−{f.Removed}", 10, null, K.A("JcSysRed"), mono: true));
            var t = new Tap(K.Spread(name, counts), PressLook.Dim);
            t.Click += () => { _openFile = _openFile == file.Path ? null : file.Path; Rebuild(); };
            K.Add(col, t, 6);
            if (_openFile == f.Path) K.Add(col, DiffBox(f), 6);
        }
        K.Add(col, K.H(8, Controls.IslandButton("Terminal", "JcText", () => JumpRequested?.Invoke(s), 0.8)), 6);
        return col;
    }

    private static FrameworkElement DiffBox(ChangedFile f)
    {
        var lines = new StackPanel();
        foreach (var l in f.Lines.Take(200))
        {
            var fg = l.Kind == '+' ? K.A("JcSysGreen") : l.Kind == '-' ? K.A("JcSysRed") : K.W(0.6);
            lines.Children.Add(K.T($"{l.Kind} {l.Text}", 10, null, fg, mono: true));
        }
        var scroll = new ScrollViewer { Content = lines, MaxHeight = 140, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden, Focusable = false };
        return K.Rounded(scroll, K.W(0.06), 8, 6);
    }

    private FrameworkElement JobRow(HarnessJob j)
    {
        var head = K.H(6, K.T(j.AgentName, 13, FontWeights.SemiBold), K.T($"Hand-off · {j.StateLabel}", 11, null, K.W(0.5)));
        var top = j.Running ? K.Spread(head, K.T(j.Elapsed(DateTimeOffset.UtcNow), 10, null, K.W(0.45), mono: true)) : (FrameworkElement)head;
        var text = K.V(2, top);
        if (j.Task.Length > 0) K.Add(text, K.T(j.Task, 11, null, K.W(0.7)), 2);
        K.Add(text, K.T(j.Line, 11, null, j.State == SessionState.Error ? K.A("JcSysRed", 0.85) : K.W(0.75), mono: true), 2);
        var row = new DockPanel();
        var mark = StateMark(j.State, j.Running);
        DockPanel.SetDock(mark, Dock.Left);
        row.Children.Add(mark);
        text.Margin = new Thickness(10, 0, 0, 0);
        row.Children.Add(text);
        return RowCard(row, _selectedKey == j.Key, () => Toggle(j.Key));
    }

    private FrameworkElement JobDetail(HarnessJob j)
    {
        var col = new StackPanel { Margin = new Thickness(12, 0, 12, 6) };
        var meta = new[] { j.Origin, j.ModelName, $"{j.Steps} step{(j.Steps == 1 ? "" : "s")}", j.Running ? "" : j.Elapsed(DateTimeOffset.UtcNow) }
            .Where(s => s.Length > 0);
        K.Add(col, K.T(string.Join(" · ", meta), 10, null, K.W(0.5)), 6);
        if (j.Task.Length > 0) K.Add(col, K.T(j.Task, 11, null, K.W(0.8), wrap: true), 6);
        foreach (var step in j.Trail.TakeLast(5))
            K.Add(col, K.T($"› {step.Text}{(step.Detail.Length == 0 ? "" : $" — {step.Detail}")}", 10, null, K.W(0.55), mono: true), 6);
        if (j.Result.Length > 0)
        {
            var result = K.T(j.Result, 11.5, null, K.W(0.9), wrap: true);
            var scroll = new ScrollViewer { Content = result, MaxHeight = 170, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden, Focusable = false };
            K.Add(col, K.Rounded(scroll, K.W(0.06), 8, 8), 6);
            K.Add(col, K.H(8,
                Controls.IslandButton("Read aloud", "JcText", () => ReadAloudRequested?.Invoke(j), 0.8),
                Controls.IslandButton("Copy", "JcText", () => { try { Clipboard.SetText(j.Result); } catch (System.Runtime.InteropServices.COMException) { } }, 0.8)), 6);
        }
        return col;
    }

    private FrameworkElement OnServerRow(MovedSession m)
    {
        var ckey = m.Ckey;
        var text = K.V(2, K.T(m.Title.Length > 0 ? m.Title : m.Project, 13, FontWeights.SemiBold), K.T($"On server · {m.Project}", 11, null, K.W(0.5)));
        var left = K.H(10, new IconView(Sym.Moon, 13, K.W(0.6)), text);
        var back = new Tap(K.T("Bring back", 11, FontWeights.SemiBold, K.A("JcAccent")), PressLook.Dim);
        back.Click += () => _state.BringBack(ckey);
        return K.Rounded(K.Spread(left, back, 10), K.W(0.05), 10, 8);
    }

    private static FrameworkElement FlashRow(AgentSession s)
    {
        var ok = s.State != SessionState.Error;
        var mark = K.Glyph(ok ? "" : "", 14, K.A(ok ? "JcSysGreen" : "JcSysRed"));
        var row = K.H(8, mark, K.T($"{s.Project}: {(ok ? "done" : "failed")}", 12, FontWeights.SemiBold));
        if (s.Final.Length > 0) K.Add(row, K.T(s.Final.Split('\n')[0], 11, null, K.W(0.6)), 8);
        return row;
    }
}
