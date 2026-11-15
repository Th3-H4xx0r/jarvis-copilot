using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Jarvis.Core.Island;
using Jarvis.Core.Model;
using Jarvis.Core.State;
using Jarvis.Ui;

namespace Jarvis.Island;

/// The Agents tab: header with the usage pills, a notice line, the first waiting card (approval
/// or question), the just-finished flash, session rows (green loader while working, amber dot
/// while waiting), harness jobs and the "On server" list with Bring back. Rebuilt only while
/// it is on screen.
public sealed class AgentsTab : Border
{
    private readonly AppState _state;
    private readonly IslandPresenter _p;
    private readonly Func<NoActivateWindow?> _window;
    private readonly StackPanel _top = new();
    private readonly StackPanel _list = new();
    private string _cardFingerprint = "";
    private FrameworkElement? _card;

    /// A session row was clicked: jump to its terminal (Task 6).
    public event Action<AgentSession>? JumpRequested;
    /// A harness job's Read aloud.
    public event Action<HarnessJob>? ReadAloudRequested;

    public AgentsTab(AppState state, IslandPresenter presenter, Func<NoActivateWindow?> window)
    {
        _state = state;
        _p = presenter;
        _window = window;
        var scroll = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = _list,
            Focusable = false,
        };
        var dock = new DockPanel();
        DockPanel.SetDock(_top, Dock.Top);
        dock.Children.Add(_top);
        dock.Children.Add(scroll);
        Child = dock;
        Margin = new Thickness(0, 8, 0, 0);

        state.Changed += () => { if (IsVisible) Rebuild(); };
        IsVisibleChanged += (_, _) => { if (IsVisible) Rebuild(); };
    }

    public void Rebuild()
    {
        _top.Children.Clear();
        _list.Children.Clear();
        _top.Children.Add(Header());
        if (_p.Notice is { } notice)
        {
            var n = Th.Text(notice, 12, "JcAmber", wrap: true);
            n.Margin = new Thickness(0, 6, 0, 0);
            _top.Children.Add(n);
            _p.ClearNotice();
        }
        if (_state.Pending.FirstOrDefault() is { } pending)
        {
            // Keep the same card (and its arm time / typed note) while it is the same request.
            if (pending.Fingerprint != _cardFingerprint || _card == null)
            {
                _cardFingerprint = pending.Fingerprint;
                _card = pending.IsQuestion
                    ? new QuestionCard(_state, pending, _window)
                    : new ApprovalCard(_state, pending, _window);
            }
            _card.Margin = new Thickness(0, 8, 0, 0);
            _top.Children.Add(_card);
        }
        else
        {
            _cardFingerprint = "";
            _card = null;
        }
        if (_state.Flash is { } flash) _top.Children.Add(FlashRow(flash));

        foreach (var s in _state.Sessions) _list.Children.Add(SessionRow(s));
        foreach (var j in _state.Jobs) _list.Children.Add(JobRow(j));
        if (_state.Sessions.Count == 0 && _state.Jobs.Count == 0)
        {
            var empty = Th.Text(_state.Connected ? "No agents running." : "Jarvis isn't running on this PC.", 12, "JcTextDim");
            empty.Margin = new Thickness(0, 14, 0, 0);
            _list.Children.Add(empty);
        }
        if (_state.OnServer.Count > 0) _list.Children.Add(OnServerSection());
    }

    private FrameworkElement Header()
    {
        var waiting = _state.WaitingCount;
        var working = _state.WorkingCount;
        var line = waiting > 0 ? (waiting == 1 ? "1 waiting on you" : $"{waiting} waiting on you")
            : working > 0 ? $"{working} working" : "All quiet";
        var left = Th.Column(2, Th.Text("Agents", 15, bold: true), Th.Text(line, 12, waiting > 0 ? "JcAmber" : "JcTextDim"));
        var pills = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
        if (_state.Usage is { } u) pills.Children.Add(UsagePill("Claude", u));
        if (_state.CodexUsage is { } c) pills.Children.Add(UsagePill("Codex", c));
        var g = new Grid { Height = IslandLayout.Header - 4 };
        g.Children.Add(left);
        g.Children.Add(pills);
        return g;
    }

    private static FrameworkElement UsagePill(string name, PlanUsage u)
    {
        var now = DateTimeOffset.UtcNow;
        var parts = new List<string>();
        var tip = new List<string>();
        if (u.Five is { } f)
        {
            parts.Add($"5h {f.UsedNow(now)}%");
            if (f.ResetsAt is { } r)
            {
                var pace = UsagePace.Pace(f.UsedNow(now), r, UsagePace.FiveHours, now);
                tip.Add($"5-hour: {f.UsedNow(now)}% used, {(pace > 0 ? $"{pace:0}% ahead of the clock" : $"{-pace:0}% in reserve")}, resets in {UsagePace.ResetsIn(r, now)}");
            }
        }
        if (u.Week is { } w)
        {
            parts.Add($"7d {w.UsedNow(now)}%");
            if (w.ResetsAt is { } r) tip.Add($"Week: {w.UsedNow(now)}% used, resets in {UsagePace.ResetsIn(r, now)}");
        }
        var hot = (u.Five?.UsedNow(now) ?? 0) >= 90 || (u.Week?.UsedNow(now) ?? 0) >= 90;
        var b = Th.Card(Th.Text($"{name} · {string.Join(" · ", parts)}", 11, hot ? "JcAmber" : "JcTextDim"), pad: 0);
        b.Padding = new Thickness(8, 3, 8, 3);
        b.Margin = new Thickness(6, 0, 0, 0);
        b.ToolTip = tip.Count > 0 ? string.Join("\n", tip) : null;
        return b;
    }

    private static FrameworkElement Indicator(SessionState s) => s switch
    {
        SessionState.Working or SessionState.Thinking => new JcLoader { Size = 14, Foreground = Th.B("JcGreen") },
        SessionState.Approval or SessionState.Question => Th.Dot("JcAmber"),
        SessionState.Error => Th.Dot("JcRed"),
        SessionState.Finished => Th.Dot("JcText"),
        _ => Th.Dot("JcTextFaint"),
    };

    private FrameworkElement SessionRow(AgentSession s)
    {
        var ind = Indicator(s.State);
        ind.Width = 14;
        var title = Th.Text(s.Project, 13, bold: true);
        var sub = Th.Text($"{s.AgentName} · {(s.Step.Length > 0 ? s.Step : s.State.Label())}", 12, "JcTextDim");
        var text = Th.Column(2, title, sub);
        text.Margin = new Thickness(10, 0, 0, 0);
        var row = new DockPanel { Height = IslandLayout.RowHeight - 6, Background = Th.B("JcBackground"), Cursor = Cursors.Hand };
        DockPanel.SetDock(ind, Dock.Left);
        row.Children.Add(ind);
        row.Children.Add(text);
        row.ToolTip = s.Cwd.Length > 0 ? $"{s.Cwd}\nClick to jump to its terminal" : null;
        row.MouseLeftButtonUp += (_, _) => JumpRequested?.Invoke(s);
        var border = new Border { Child = row, BorderBrush = Th.B("JcHairline"), BorderThickness = new Thickness(0, 0, 0, 1), Padding = new Thickness(0, 3, 0, 3) };
        return border;
    }

    private FrameworkElement JobRow(HarnessJob j)
    {
        var ind = Indicator(j.State);
        ind.Width = 14;
        var text = Th.Column(2,
            Th.Text($"{j.AgentName} · {j.ModelName}", 13, bold: true),
            Th.Text($"{j.Line} · {j.Elapsed(DateTimeOffset.UtcNow)}", 12, "JcTextDim"));
        text.Margin = new Thickness(10, 0, 0, 0);
        var row = new DockPanel { Height = IslandLayout.RowHeight - 6 };
        DockPanel.SetDock(ind, Dock.Left);
        row.Children.Add(ind);
        if (j.Result.Length > 0)
        {
            var read = Th.Icon("", "Read aloud", () => ReadAloudRequested?.Invoke(j), 24);
            DockPanel.SetDock(read, Dock.Right);
            row.Children.Add(read);
        }
        row.Children.Add(text);
        row.ToolTip = j.Origin.Length > 0 ? j.Origin : null;
        return new Border { Child = row, BorderBrush = Th.B("JcHairline"), BorderThickness = new Thickness(0, 0, 0, 1), Padding = new Thickness(0, 3, 0, 3) };
    }

    private static FrameworkElement FlashRow(AgentSession s)
    {
        var ok = s.State == SessionState.Finished;
        var line = ok ? $"{s.Project} finished" : $"{s.Project} failed";
        var detail = s.Final.Length > 0 ? s.Final.Split('\n')[0] : s.AgentName;
        var card = Th.Card(Th.Column(2, Th.Text(line, 13, ok ? "JcText" : "JcRed", bold: true), Th.Text(detail, 12, "JcTextDim")), pad: 10);
        card.Margin = new Thickness(0, 8, 0, 0);
        return card;
    }

    private FrameworkElement OnServerSection()
    {
        var col = new StackPanel { Margin = new Thickness(0, 12, 0, 0) };
        col.Children.Add(Th.Text("On server", 12, "JcTextDim", bold: true));
        foreach (var m in _state.OnServer)
        {
            var ckey = m.Ckey;
            var back = Th.Button("Bring back", () => _state.BringBack(ckey), size: 12);
            back.Padding = new Thickness(10, 3, 10, 3);
            var text = Th.Column(1, Th.Text(m.Title.Length > 0 ? m.Title : m.Project, 13), Th.Text($"{AgentSession.DisplayName(m.Agent)} · {m.Project}", 11, "JcTextDim"));
            var row = new DockPanel { Margin = new Thickness(0, 6, 0, 0) };
            DockPanel.SetDock(back, Dock.Right);
            row.Children.Add(back);
            row.Children.Add(text);
            col.Children.Add(row);
        }
        return col;
    }
}
