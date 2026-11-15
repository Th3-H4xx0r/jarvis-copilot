using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Jarvis.Core.Chat;
using Jarvis.Core.Island;
using Jarvis.Ui;

namespace Jarvis.Chat;

/// The island's Chat tab: Jarvis (or a local Ollama / LM Studio model), the attached window as
/// a chip, approvals and questions inline, Send (the one white button) or Stop. Typing into the
/// composer is the only time the island takes the keyboard.
public sealed class ChatTab : Border
{
    private readonly ChatStore _chat;
    private readonly IslandPresenter _island;
    private readonly Func<NoActivateWindow?> _window;
    private readonly StackPanel _turns = new();
    private readonly ScrollViewer _scroll;
    private readonly TextBox _input = Th.Input("Ask Jarvis", multiline: true);
    private readonly StackPanel _chips = new() { Orientation = Orientation.Horizontal };
    private readonly ContentControl _ask = new();
    private readonly Button _send;
    private readonly ComboBox _source;

    public ChatTab(ChatStore chat, IslandPresenter island, Func<NoActivateWindow?> window)
    {
        _chat = chat;
        _island = island;
        _window = window;
        _scroll = new ScrollViewer { Content = _turns, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        _send = Th.Button("Send", Send, primary: true);
        _source = new ComboBox { Width = 120, Margin = new Thickness(0, 0, 8, 0) };
        foreach (var b in Enum.GetValues<ChatStore.Backend>())
            _source.Items.Add(new ComboBoxItem { Content = b switch { ChatStore.Backend.Jarvis => "Jarvis", ChatStore.Backend.Ollama => "Ollama", _ => "LM Studio" }, Tag = b, IsSelected = b == chat.Source });
        _source.SelectionChanged += (_, _) => { if (_source.SelectedItem is ComboBoxItem { Tag: ChatStore.Backend b }) _chat.Source = b; };
        _input.MaxHeight = 90;
        _input.GotKeyboardFocus += (_, _) => _window()?.BeginTyping();
        _input.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter && !Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) { e.Handled = true; Send(); }
            if (e.Key == Key.Escape) { _window()?.EndTyping(); _island.EndTyping(); }
        };
        var composer = new DockPanel { Margin = new Thickness(0, 8, 0, 0) };
        DockPanel.SetDock(_source, Dock.Left);
        DockPanel.SetDock(_send, Dock.Right);
        composer.Children.Add(_source);
        composer.Children.Add(_send);
        composer.Children.Add(_input);
        var dock = new DockPanel();
        DockPanel.SetDock(composer, Dock.Bottom);
        DockPanel.SetDock(_chips, Dock.Bottom);
        DockPanel.SetDock(_ask, Dock.Bottom);
        dock.Children.Add(composer);
        dock.Children.Add(_chips);
        dock.Children.Add(_ask);
        dock.Children.Add(_scroll);
        Child = dock;
        Margin = new Thickness(0, 8, 0, 0);
        _chat.Changed += () => Dispatcher.BeginInvoke(Render);
        _island.TypingRequested += () => Dispatcher.BeginInvoke(() =>
        {
            if (_island.Draft is { } d) _input.Text = d;
            _input.Focus();
            _input.CaretIndex = _input.Text.Length;
        });
        IsVisibleChanged += (_, _) => { if (IsVisible) { if (_island.Draft is { } d && _input.Text.Length == 0) _input.Text = d; Render(); } };
    }

    private void Send()
    {
        if (_chat.Busy) { _ = _chat.StopAsync(); return; }
        var text = _input.Text;
        _input.Text = "";
        _ = _chat.SendAsync(text);
    }

    private void Render()
    {
        _send.Content = _chat.Busy ? "Stop" : "Send";
        _turns.Children.Clear();
        foreach (var t in _chat.Turns)
        {
            var text = t.Error is { } e ? e : t.Text.Length > 0 ? t.Text : t.Streaming ? "…" : t.Stopped ? "Stopped." : "";
            var block = Th.Text(text, 13, t.Mine ? "JcText" : t.Error != null ? "JcRed" : "JcTextDim", wrap: true);
            block.Margin = new Thickness(t.Mine ? 40 : 0, 4, t.Mine ? 0 : 40, 4);
            block.HorizontalAlignment = t.Mine ? HorizontalAlignment.Right : HorizontalAlignment.Left;
            if (t.Streaming && t.Text.Length == 0)
                _turns.Children.Add(Th.Row(8, new JcLoader { Size = 14, Foreground = Th.B("JcGreen") }, Th.Text(t.Tools?.LastOrDefault() ?? "Thinking", 12, "JcTextDim")));
            else _turns.Children.Add(block);
        }
        _scroll.ScrollToEnd();

        _chips.Children.Clear();
        if (_chat.Attached is { } w)
            _chips.Children.Add(Th.Card(Th.Row(6, Th.Text(w.Url ?? w.Title, 11, "JcTextDim"), Th.Icon("", "Detach", () => { _chat.Attached = null; Render(); }, 20)), pad: 4));

        _ask.Content = null;
        if (_chat.Approval is { } a)
        {
            var buttons = Th.Row(6,
                Th.Button("Allow once", () => _ = _chat.AnswerApprovalAsync(ChatApproval.Choice.once), primary: true),
                Th.Button("This chat", () => _ = _chat.AnswerApprovalAsync(ChatApproval.Choice.session)),
                Th.Button("Deny", () => _ = _chat.AnswerApprovalAsync(ChatApproval.Choice.deny)));
            var card = Th.Card(Th.Column(6, Th.Text(a.Description.Length > 0 ? a.Description : "Jarvis wants to run", 12, wrap: true),
                Th.Text(a.Command, 12, "JcTextDim", wrap: true, mono: true), buttons));
            card.BorderBrush = Th.B("JcAmber");
            card.BorderThickness = new Thickness(1);
            _ask.Content = card;
        }
        else if (_chat.Clarify is { } c)
        {
            var col = Th.Column(6, Th.Text(c.Question, 12, wrap: true));
            var row = new WrapPanel();
            foreach (var choice in c.Choices)
            {
                var b = Th.Button(choice, () => _ = _chat.AnswerClarifyAsync(choice), size: 12);
                b.Margin = new Thickness(0, 0, 6, 6);
                row.Children.Add(b);
            }
            col.Children.Add(row);
            var card = Th.Card(col);
            card.BorderBrush = Th.B("JcAmber");
            card.BorderThickness = new Thickness(1);
            _ask.Content = card;
        }
    }
}
