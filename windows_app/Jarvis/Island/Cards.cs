using System.Windows;
using System.Windows.Controls;
using Jarvis.Core.Island;
using Jarvis.Core.Model;
using Jarvis.Core.State;
using Jarvis.Ui;

namespace Jarvis.Island;

/// An approval waiting on him: Allow (the one white button), Deny with an optional note (typing
/// into the note is the only thing that takes focus), Always when offered, and Terminal (answer
/// it there). Clicks are ignored for 0.5 s after it appears (ArmGate).
public sealed class ApprovalCard : Border
{
    private readonly ArmGate _arm = new(DateTimeOffset.UtcNow);

    public ApprovalCard(AppState state, PendingRequest p, Func<NoActivateWindow?> window)
    {
        Background = Th.B("JcButton");
        CornerRadius = new CornerRadius(12);
        Padding = new Thickness(12);
        BorderBrush = Th.B("JcAmber");
        BorderThickness = new Thickness(1);

        var who = AgentSession.DisplayName(p.Agent);
        var title = Th.Text($"{who} wants to {(p.Tool.Length > 0 ? $"use {p.Tool}" : "do something")}", 13, bold: true, wrap: true);
        var project = Th.Text(p.Project, 11, "JcTextDim");
        var body = Th.Text(p.Command.Length > 0 ? p.Command : p.Summary, 12, "JcTextDim", wrap: true, mono: p.Command.Length > 0);
        body.MaxHeight = 64;

        var note = Th.Input("Tell it why (optional)");
        note.GotKeyboardFocus += (_, _) => window()?.BeginTyping();
        note.LostKeyboardFocus += (_, _) => window()?.EndTyping();

        void Decide(string decision, string? message = null)
        {
            if (!_arm.IsArmed(DateTimeOffset.UtcNow)) return;
            window()?.EndTyping();
            _ = state.DecideAsync(p, decision, message);
            DecisionMade?.Invoke();
        }

        note.KeyDown += (_, e) =>
        {
            if (e.Key == System.Windows.Input.Key.Enter) Decide("deny", NoteText(note));
        };

        var buttons = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
        void Add(Button b) { b.Margin = new Thickness(0, 0, 6, 0); buttons.Children.Add(b); }
        Add(Th.Button("Allow", () => Decide("allow"), primary: true));
        if (p.CanAlways) Add(Th.Button("Always", () => Decide("always")));
        Add(Th.Button("Deny", () => Decide("deny", NoteText(note))));
        Add(Th.Button("Terminal", () => Decide("ask")));

        note.Margin = new Thickness(0, 8, 0, 0);
        Child = Th.Column(4, title, project, body, note, buttons);
    }

    /// Fired after any answer (the sound plays here: Task 6).
    public static event Action? DecisionMade;

    private static string? NoteText(TextBox t) => t.Text.Trim() is { Length: > 0 } s ? s : null;
}

/// A question from an agent: each question's options (radio or multi), an "Other" box, then Send
/// → QuestionAnswers.Build → decide "answer". Terminal answers it in the terminal instead.
public sealed class QuestionCard : Border
{
    private readonly ArmGate _arm = new(DateTimeOffset.UtcNow);
    private readonly Dictionary<string, List<string>> _picks = new();
    private readonly Dictionary<string, string> _typed = new();

    public QuestionCard(AppState state, PendingRequest p, Func<NoActivateWindow?> window)
    {
        Background = Th.B("JcButton");
        CornerRadius = new CornerRadius(12);
        Padding = new Thickness(12);
        BorderBrush = Th.B("JcAmber");
        BorderThickness = new Thickness(1);

        var col = new StackPanel();
        col.Children.Add(Th.Text($"{AgentSession.DisplayName(p.Agent)} has a question", 13, bold: true));
        col.Children.Add(Th.Text(p.Project, 11, "JcTextDim"));
        var group = 0;
        foreach (var q in p.Questions)
        {
            var qText = q.Text;
            var header = Th.Text(q.Text, 12, wrap: true);
            header.Margin = new Thickness(0, 8, 0, 4);
            col.Children.Add(header);
            var name = $"q{group++}";
            for (var i = 0; i < q.Options.Count; i++)
            {
                var label = q.Options[i];
                var detail = i < q.Details.Count ? q.Details[i] : "";
                ToggleButtonLike option = q.MultiSelect
                    ? new CheckOption(label, detail)
                    : new RadioOption(label, detail, name);
                option.Changed += on =>
                {
                    var list = _picks.TryGetValue(qText, out var l) ? l : _picks[qText] = new List<string>();
                    if (!q.MultiSelect) list.Clear();
                    if (on && !list.Contains(label)) list.Add(label);
                    if (!on) list.Remove(label);
                };
                col.Children.Add(option.Element);
            }
            var other = Th.Input("Other");
            other.Margin = new Thickness(0, 4, 0, 0);
            other.GotKeyboardFocus += (_, _) => window()?.BeginTyping();
            other.LostKeyboardFocus += (_, _) => window()?.EndTyping();
            other.TextChanged += (_, _) => _typed[qText] = other.Text;
            col.Children.Add(other);
        }

        void Send()
        {
            if (!_arm.IsArmed(DateTimeOffset.UtcNow)) return;
            window()?.EndTyping();
            var picks = _picks.ToDictionary(kv => kv.Key, kv => (IReadOnlyList<string>)kv.Value);
            var answers = QuestionAnswers.Build(p.Questions, picks, _typed);
            _ = state.DecideAsync(p, "answer", answers: answers);
        }

        var buttons = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
        var send = Th.Button("Send", Send, primary: true);
        send.Margin = new Thickness(0, 0, 6, 0);
        buttons.Children.Add(send);
        buttons.Children.Add(Th.Button("Terminal", () =>
        {
            if (_arm.IsArmed(DateTimeOffset.UtcNow)) _ = state.DecideAsync(p, "ask");
        }));
        col.Children.Add(buttons);
        Child = new ScrollViewer { Content = col, MaxHeight = 220, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Focusable = false };
    }

    private abstract class ToggleButtonLike
    {
        public abstract FrameworkElement Element { get; }
        public event Action<bool>? Changed;
        protected void Raise(bool on) => Changed?.Invoke(on);
    }

    private sealed class CheckOption : ToggleButtonLike
    {
        private readonly CheckBox _box;
        public CheckOption(string label, string detail)
        {
            _box = new CheckBox { Content = Th.Text(label, 12), ToolTip = detail.Length > 0 ? detail : null, Margin = new Thickness(0, 2, 0, 2), Focusable = false };
            _box.Checked += (_, _) => Raise(true);
            _box.Unchecked += (_, _) => Raise(false);
        }
        public override FrameworkElement Element => _box;
    }

    private sealed class RadioOption : ToggleButtonLike
    {
        private readonly RadioButton _radio;
        public RadioOption(string label, string detail, string group)
        {
            _radio = new RadioButton { Content = Th.Text(label, 12), GroupName = group, ToolTip = detail.Length > 0 ? detail : null, Margin = new Thickness(0, 2, 0, 2), Focusable = false };
            _radio.Checked += (_, _) => Raise(true);
            _radio.Unchecked += (_, _) => Raise(false);
        }
        public override FrameworkElement Element => _radio;
    }
}
