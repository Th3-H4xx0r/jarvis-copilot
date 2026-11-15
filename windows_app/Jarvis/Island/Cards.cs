using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Jarvis.Core.Island;
using Jarvis.Core.Model;
using Jarvis.Core.State;
using Jarvis.Ui;

namespace Jarvis.Island;

/// A one-line text field with no system chrome: a soft rounded fill, a placeholder, and the window
/// takes the keyboard only while it's focused (typing is the only time the island activates).
internal sealed class Field : Grid
{
    private readonly TextBlock _hint;

    public Field(string placeholder, Func<NoActivateWindow?> window, double size = 12)
    {
        Box = new TextBox
        {
            Background = Brushes.Transparent,
            Foreground = K.W(0.92),
            CaretBrush = K.W(1),
            SelectionBrush = K.W(0.35),
            BorderThickness = new Thickness(0),
            FontFamily = K.Font,
            FontSize = size,
            Padding = new Thickness(0),
            VerticalContentAlignment = VerticalAlignment.Center,
            FocusVisualStyle = null,
        };
        _hint = K.T(placeholder, size, null, K.W(0.35));
        _hint.IsHitTestVisible = false;
        _hint.Margin = new Thickness(2, 0, 0, 0);
        var inner = new Grid { Margin = new Thickness(9, 5, 9, 5) };
        inner.Children.Add(_hint);
        inner.Children.Add(Box);
        Children.Add(new Border { Background = K.W(0.08), CornerRadius = new CornerRadius(7), BorderBrush = K.W(0.10), BorderThickness = new Thickness(0.5) });
        Children.Add(inner);
        Box.TextChanged += (_, _) => _hint.Visibility = Box.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        Box.GotKeyboardFocus += (_, _) => window()?.BeginTyping();
        Box.LostKeyboardFocus += (_, _) => window()?.EndTyping();
        Box.PreviewMouseLeftButtonDown += (_, _) => { if (!Box.IsKeyboardFocusWithin) { window()?.BeginTyping(); Box.Focus(); } };
    }

    public TextBox Box { get; }
    public string Text => Box.Text.Trim();
}

/// A request card on the island: amber @8%, radius 12, padding 10; clicks are ignored for
/// ArmGate.Delay after it appears so a click meant for something else can't answer it.
internal static class PendingCard
{
    public static void Dress(Border card)
    {
        card.Background = K.A("JcAmber", 0.08);
        card.CornerRadius = new CornerRadius(12);
        card.Padding = new Thickness(10);
    }

    public static FrameworkElement Title(Sym icon, string text, UIElement? trailing = null)
    {
        var left = K.H(8, new IconView(icon, 13, K.A("JcAmber")), K.T(text, 12, FontWeights.SemiBold, K.A("JcAmber")));
        return K.Spread(left, trailing);
    }
}

/// An approval: the exact command, Allow (Y) / Always / Deny (N) — a note when denying — and
/// Terminal (let the terminal ask instead), as on the Mac.
public sealed class ApprovalCard : Border
{
    private readonly ArmGate _arm = new(DateTimeOffset.UtcNow);
    private readonly AppState _state;
    private readonly PendingRequest _p;
    private readonly Func<NoActivateWindow?> _window;
    private readonly ContentControl _actions = new() { Focusable = false };

    public ApprovalCard(AppState state, PendingRequest p, Func<NoActivateWindow?> window, int extra = 0)
    {
        _state = state;
        _p = p;
        _window = window;
        PendingCard.Dress(this);
        var who = p.Agent == "claude" ? "Claude" : AgentSession.DisplayName(p.Agent);
        var title = PendingCard.Title(Sym.Lock, $"{p.Project} — {who} needs approval",
            extra > 0 ? K.T($"+{extra}", 11, null, K.W(0.5)) : null);
        var command = K.T(p.Command.Length > 0 ? p.Command : p.Summary, 11, null, K.W(1), mono: true, wrap: true);
        command.MaxHeight = 5 * 15;
        var box = K.Rounded(command, K.W(0.07), 8, 8);
        _actions.Content = Buttons();
        Child = K.V(8, title, box, _actions);
    }

    /// Fired after any answer (the sound plays here).
    public static event Action? DecisionMade;

    private FrameworkElement Buttons()
    {
        var left = new StackPanel { Orientation = Orientation.Horizontal };
        K.Add(left, Controls.IslandButton("Allow", "JcSysGreen", () => Decide("allow"), tip: "Allow (Y)"), 8);
        if (_p.CanAlways) K.Add(left, Controls.IslandButton("Always", "JcAccent", () => Decide("always")), 8);
        K.Add(left, Controls.IslandButton("Deny", "JcSysRed", ShowDeny, tip: "Deny (N)"), 8);
        var terminal = Controls.IslandButton("Terminal", "JcText", () => Decide("ask"), 0.7, "Let the terminal ask instead");
        return K.Spread(left, terminal);
    }

    private void ShowDeny()
    {
        if (!_arm.IsArmed(DateTimeOffset.UtcNow)) return;
        var note = new Field("Tell it what to do instead (optional)", _window);
        note.Box.KeyDown += (_, e) => { if (e.Key == Key.Enter) Decide("deny", note.Text); };
        var deny = Controls.IslandButton("Deny", "JcSysRed", () => Decide("deny", note.Text));
        var row = new DockPanel();
        DockPanel.SetDock(deny, Dock.Right);
        deny.Margin = new Thickness(8, 0, 0, 0);
        row.Children.Add(deny);
        row.Children.Add(note);
        _actions.Content = row;
        Dispatcher.BeginInvoke(() => { _window()?.BeginTyping(); note.Box.Focus(); });
    }

    private void Decide(string decision, string? message = null)
    {
        if (!_arm.IsArmed(DateTimeOffset.UtcNow)) return;
        _window()?.EndTyping();
        _ = _state.DecideAsync(_p, decision, message is { Length: > 0 } ? message : null);
        DecisionMade?.Invoke();
    }
}

/// A question (AskUserQuestion): pick, multi-select, or type "Other…"; Send answer once every
/// question has one. Terminal answers it there instead.
public sealed class QuestionCard : Border
{
    private readonly ArmGate _arm = new(DateTimeOffset.UtcNow);
    private readonly Dictionary<string, List<string>> _picks = new();
    private readonly Dictionary<string, string> _typed = new();
    private readonly PendingRequest _p;
    private readonly Tap _send;

    public QuestionCard(AppState state, PendingRequest p, Func<NoActivateWindow?> window)
    {
        _p = p;
        PendingCard.Dress(this);
        var title = PendingCard.Title(Sym.BubbleLeft, $"{p.Project} has a question");
        var questions = new StackPanel { Margin = new Thickness(0, 0, 8, 0) };
        foreach (var q in p.Questions)
        {
            var question = q;
            var block = K.V(4, K.T(q.Text, 12, FontWeights.Medium, K.W(1), wrap: true));
            var options = new WrapPanel();
            var chips = new List<(string Label, Tap Chip)>();
            for (var i = 0; i < q.Options.Count; i++)
            {
                var label = q.Options[i];
                var chip = new Tap(K.T(label, 11, FontWeights.Medium), PressLook.Dim, i < q.Details.Count && q.Details[i].Length > 0 ? q.Details[i] : null)
                {
                    Background = K.W(0.08),
                    CornerRadius = new CornerRadius(999),
                    Padding = new Thickness(8, 4, 8, 4),
                    Margin = new Thickness(0, 0, 6, 6),
                };
                chips.Add((label, chip));
                chip.Click += () =>
                {
                    var list = _picks.TryGetValue(question.Text, out var l) ? l : _picks[question.Text] = new List<string>();
                    var on = list.Contains(label);
                    if (question.MultiSelect) { if (on) list.Remove(label); else list.Add(label); }
                    else { list.Clear(); if (!on) list.Add(label); }
                    foreach (var (lbl, c) in chips) c.Background = list.Contains(lbl) ? K.A("JcAccent", 0.35) : K.W(0.08);
                    Refresh();
                };
                options.Children.Add(chip);
            }
            K.Add(block, options, 4);
            var other = new Field("Other…", window, 11);
            other.Box.TextChanged += (_, _) => { _typed[question.Text] = other.Box.Text; Refresh(); };
            K.Add(block, other, 0);
            K.Add(questions, block, 8);
        }
        var scroll = new ScrollViewer { Content = questions, MaxHeight = 240, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden, Focusable = false };
        _send = Controls.IslandButton("Send answer", "JcAccent", () =>
        {
            if (!_arm.IsArmed(DateTimeOffset.UtcNow) || !Complete()) return;
            window()?.EndTyping();
            var picks = _picks.ToDictionary(kv => kv.Key, kv => (IReadOnlyList<string>)kv.Value);
            _ = state.DecideAsync(p, "answer", answers: QuestionAnswers.Build(p.Questions, picks, _typed));
            ApprovalCardSound();
        });
        var terminal = Controls.IslandButton("Terminal", "JcText", () =>
        {
            if (_arm.IsArmed(DateTimeOffset.UtcNow)) _ = state.DecideAsync(p, "ask");
        }, 0.7);
        Child = K.V(8, title, scroll, K.Spread(terminal, _send));
        Refresh();
    }

    private static void ApprovalCardSound() { }

    /// Every question has a pick or a typed answer.
    private bool Complete() => _p.Questions.All(q =>
        (_picks.TryGetValue(q.Text, out var l) && l.Count > 0) || (_typed.TryGetValue(q.Text, out var t) && t.Trim().Length > 0));

    private void Refresh() => _send.IsEnabled = Complete();
}
