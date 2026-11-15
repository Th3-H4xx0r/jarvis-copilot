using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using Jarvis.Core.Chat;
using Jarvis.Core.Island;
using Jarvis.Core.Model;
using Jarvis.Island;
using Jarvis.Orb;
using Jarvis.Ui;

namespace Jarvis.Chat;

/// The island's Chat, as on the Mac (ChatPane): "Chat", who answers in a glass capsule (its menu
/// drawn in the island, never a system dropdown) and a new chat; the conversation laid out like
/// the phone's — his turns in a soft bubble, Jarvis's opening with its tools in one box; approvals
/// and questions answered in place; and one glass composer (attach, the message, send — stop while
/// Jarvis works) whose edge lights while a reply comes. Typing into it is the only time the island
/// takes the keyboard.
public sealed class ChatTab : Border
{
    private readonly ChatStore _chat;
    private readonly IslandPresenter _island;
    private readonly Func<NoActivateWindow?> _window;
    private readonly StackPanel _turns = new();
    private readonly ScrollViewer _scroll;
    private readonly TextBox _input;
    private readonly TextBlock _hint;
    private readonly StackPanel _chips = new() { Orientation = Orientation.Horizontal, Margin = new Thickness(8, 4, 8, 0) };
    private readonly Border _composer;
    private readonly Tap _send;
    private readonly IconView _sendIcon = new(Sym.ArrowUp, 15, K.W(0.35), 1.05);
    private readonly TextBlock _modelLabel;
    private readonly TextBlock _localStatus;
    private readonly Grid _menuLayer = new() { Visibility = Visibility.Collapsed };
    private IReadOnlyList<string> _localModels = Array.Empty<string>();

    /// "Chat settings…" in the model menu.
    public event Action? SettingsRequested;

    public ChatTab(ChatStore chat, IslandPresenter island, Func<NoActivateWindow?> window)
    {
        _chat = chat;
        _island = island;
        _window = window;

        // ── header ──
        _modelLabel = K.T("Jarvis", 12, FontWeights.SemiBold, K.W(0.9));
        _modelLabel.MaxWidth = 190;
        var capsuleRow = K.H(5, _modelLabel, new IconView(Sym.ChevronDown, 10, K.W(0.9), 1.15));
        var capsule = new Tap(capsuleRow, PressLook.Dim, "Who answers")
        {
            Background = K.W(0.07), BorderBrush = K.W(0.12), BorderThickness = new Thickness(0.5),
            CornerRadius = new CornerRadius(999), Padding = new Thickness(10, 5, 10, 5),
        };
        capsule.Click += ToggleMenu;
        var newChat = Controls.IconButton(Sym.Compose, 15, K.A("JcAccent"), () => { _chat.Clear(); Render(); }, 26, 24, "New chat");
        _localStatus = K.T("", 11, null, K.W(0.55));
        var right = K.H(8, _localStatus, capsule, newChat);
        var header = K.Spread(K.T("Chat", 14, FontWeights.SemiBold), right);

        // ── conversation ──
        _turns.Margin = new Thickness(0, 4, 0, 4);
        _scroll = new ScrollViewer { Content = _turns, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden, Focusable = false };

        // ── composer ──
        _input = new TextBox
        {
            Background = Brushes.Transparent, Foreground = K.W(0.92), CaretBrush = K.W(1), SelectionBrush = K.W(0.35),
            BorderThickness = new Thickness(0), FontFamily = K.Font, FontSize = 13.5, Padding = new Thickness(0),
            AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 6 * 19, VerticalAlignment = VerticalAlignment.Center,
            VerticalScrollBarVisibility = ScrollBarVisibility.Hidden, FocusVisualStyle = null,
        };
        _hint = K.T("Message Jarvis", 13.5, null, K.W(0.35));
        _hint.IsHitTestVisible = false;
        _hint.Margin = new Thickness(2, 0, 0, 0);
        var field = new Grid { Margin = new Thickness(0, 8, 0, 8), VerticalAlignment = VerticalAlignment.Center };
        field.Children.Add(_hint);
        field.Children.Add(_input);
        var attach = GlassCircle(new IconView(Sym.Plus, 15, K.W(0.8), 1.05), "Attach files");
        attach.Click += Attach;
        _send = GlassCircle(_sendIcon, "Send");
        _send.Click += () => { if (CanStop) _ = _chat.StopAsync(); else Send(); };
        var line = new DockPanel { LastChildFill = true };
        DockPanel.SetDock(attach, Dock.Left);
        DockPanel.SetDock(_send, Dock.Right);
        attach.VerticalAlignment = VerticalAlignment.Bottom;
        _send.VerticalAlignment = VerticalAlignment.Bottom;
        field.Margin = new Thickness(6, 8, 6, 8);
        line.Children.Add(attach);
        line.Children.Add(_send);
        line.Children.Add(field);
        var composerBody = new StackPanel();
        composerBody.Children.Add(_chips);
        composerBody.Children.Add(line);
        _composer = new Border
        {
            Background = K.W(0.07), BorderBrush = K.W(0.12), BorderThickness = new Thickness(0.5),
            CornerRadius = new CornerRadius(23), Padding = new Thickness(6), Child = composerBody,
        };

        var dock = new DockPanel();
        DockPanel.SetDock(header, Dock.Top);
        DockPanel.SetDock(_composer, Dock.Bottom);
        _composer.Margin = new Thickness(0, 8, 0, 0);
        _scroll.Margin = new Thickness(0, 8, 0, 0);
        dock.Children.Add(header);
        dock.Children.Add(_composer);
        dock.Children.Add(_scroll);
        var root = new Grid();
        root.Children.Add(dock);
        root.Children.Add(_menuLayer);
        Child = root;

        _input.TextChanged += (_, _) => { _hint.Visibility = _input.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed; RenderComposer(); };
        _input.GotKeyboardFocus += (_, _) => _window()?.BeginTyping();
        _input.PreviewMouseLeftButtonDown += (_, _) => { if (!_input.IsKeyboardFocusWithin) { _window()?.BeginTyping(); _input.Focus(); } };
        _input.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter && !Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) { e.Handled = true; Send(); }
            if (e.Key == Key.Escape) { _window()?.EndTyping(); _island.EndTyping(); }
        };
        _chat.Changed += () => Dispatcher.BeginInvoke(Render);
        _island.TypingRequested += () => Dispatcher.BeginInvoke(() =>
        {
            if (_island.Draft is { } d) _input.Text = d;
            _input.Focus();
            _input.CaretIndex = _input.Text.Length;
        });
        IsVisibleChanged += (_, _) =>
        {
            if (!IsVisible) { _menuLayer.Visibility = Visibility.Collapsed; return; }
            if (_island.Draft is { } d && _input.Text.Length == 0) _input.Text = d;
            Render();
            _ = LoadLocalModelsAsync();
        };
    }

    private static Tap GlassCircle(UIElement icon, string tip)
    {
        var g = new Grid { Width = 34, Height = 34 };
        g.Children.Add(new Ellipse { Fill = K.W(0.07), Stroke = K.W(0.12), StrokeThickness = 0.5 });
        g.Children.Add(icon);
        return new Tap(g, PressLook.Shrink, tip);
    }

    private bool Answering => _chat.Clarify != null;
    private bool CanStop => _chat.Busy && !Answering;
    private bool CanSend => _input.Text.Trim().Length > 0 && (!_chat.Busy || Answering);

    private void Send()
    {
        var text = _input.Text;
        if (text.Trim().Length == 0) return;
        if (Answering) { _input.Text = ""; _ = _chat.AnswerClarifyAsync(text.Trim()); return; }
        if (_chat.Busy) return;
        _input.Text = "";
        _ = _chat.SendAsync(text);
    }

    private void Attach()
    {
        var dlg = new Microsoft.Win32.OpenFileDialog { Multiselect = true, Title = "Attach to the chat" };
        if (dlg.ShowDialog() != true) return;
        AttachFiles(dlg.FileNames);
    }

    private async Task LoadLocalModelsAsync()
    {
        if (_chat.Source == ChatStore.Backend.Jarvis) { _localModels = Array.Empty<string>(); RenderHeader(); return; }
        _localStatus.Text = "Looking for models…";
        _localModels = await _chat.LocalModelsAsync();
        _localStatus.Text = _localModels.Count == 0 ? $"{SourceName(_chat.Source)} isn't running" : "";
        RenderHeader();
    }

    private static string SourceName(ChatStore.Backend b) => b switch
    {
        ChatStore.Backend.Jarvis => "Jarvis",
        ChatStore.Backend.Ollama => "Ollama",
        _ => "LM Studio",
    };

    private void RenderHeader()
    {
        _modelLabel.Text = _chat.Source == ChatStore.Backend.Jarvis ? _chat.Choice.Title
            : _chat.LocalModelName.Length == 0 ? SourceName(_chat.Source) : $"{SourceName(_chat.Source)} · {_chat.LocalModelName}";
        if (_chat.Source == ChatStore.Backend.Jarvis) _localStatus.Text = "";
    }

    // ── the model menu ──────────────────────────────────────────────

    /// Files dropped on the island, or picked with +.
    public void AttachFiles(IEnumerable<string> paths)
    {
        foreach (var path in paths)
        {
            var a = ChatContext.ForFile(path, p => { try { return new System.IO.FileInfo(p).Length; } catch (System.IO.IOException) { return null; } },
                p => { try { return System.IO.File.ReadAllBytes(p); } catch (System.IO.IOException) { return null; } });
            if (a != null) _chat.Files.Add(a);
        }
        Render();
    }

    /// `--diag chat-menu`: the model menu, for a screenshot.
    public void ShowMenu()
    {
        if (_menuLayer.Visibility != Visibility.Visible) ToggleMenu();
    }

    private void ToggleMenu()
    {
        if (_menuLayer.Visibility == Visibility.Visible) { _menuLayer.Visibility = Visibility.Collapsed; return; }
        _menuLayer.Children.Clear();
        var scrim = new Border { Background = Brushes.Transparent };
        scrim.MouseLeftButtonDown += (_, e) => { _menuLayer.Visibility = Visibility.Collapsed; e.Handled = true; };
        _menuLayer.Children.Add(scrim);
        var items = new StackPanel();
        items.Children.Add(MenuHeader("Chat with"));
        foreach (var b in Enum.GetValues<ChatStore.Backend>())
        {
            var backend = b;
            items.Children.Add(MenuItem(SourceName(b), _chat.Source == b, () =>
            {
                _chat.Source = backend;
                _chat.LocalModelName = "";
                RenderHeader();
                _ = LoadLocalModelsAsync();
            }));
        }
        if (_chat.Source != ChatStore.Backend.Jarvis && _localModels.Count > 0)
        {
            items.Children.Add(MenuDivider());
            items.Children.Add(MenuHeader("Model"));
            foreach (var m in _localModels)
            {
                var model = m;
                items.Children.Add(MenuItem(m, _chat.LocalModelName == m, () => { _chat.LocalModelName = model; RenderHeader(); }));
            }
        }
        items.Children.Add(MenuDivider());
        items.Children.Add(MenuItem("Chat settings…", false, () => SettingsRequested?.Invoke()));
        var panel = new Border
        {
            Background = K.A("JcCode"), BorderBrush = K.W(0.14), BorderThickness = new Thickness(0.5),
            CornerRadius = new CornerRadius(10), Padding = new Thickness(5), Child = items, MinWidth = 210,
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 30, 30, 0),
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 24, ShadowDepth = 6, Direction = 270, Opacity = 0.5 },
        };
        _menuLayer.Children.Add(panel);
        _menuLayer.Visibility = Visibility.Visible;
    }

    private static FrameworkElement MenuHeader(string text)
    {
        var t = K.T(text, 11, FontWeights.SemiBold, K.W(0.45));
        t.Margin = new Thickness(10, 4, 10, 2);
        return t;
    }

    private static FrameworkElement MenuDivider() => new Border { Height = 0.5, Background = K.W(0.12), Margin = new Thickness(8, 4, 8, 4) };

    private FrameworkElement MenuItem(string text, bool on, Action pick)
    {
        var check = new Grid { Width = 16 };
        if (on) check.Children.Add(K.Glyph("", 11, K.W(0.9)));
        var row = K.H(4, check, K.T(text, 13, null, K.W(0.92)));
        var t = new Tap(row, PressLook.None) { Padding = new Thickness(6, 4, 10, 4), CornerRadius = new CornerRadius(5) };
        t.MouseEnter += (_, _) => t.Background = K.W(0.10);
        t.MouseLeave += (_, _) => t.Background = Brushes.Transparent;
        t.Click += () => { _menuLayer.Visibility = Visibility.Collapsed; pick(); };
        return t;
    }

    // ── render ──────────────────────────────────────────────────────

    private void RenderComposer()
    {
        _hint.Text = Answering ? "Type your answer" : "Message Jarvis";
        var stop = CanStop;
        _sendIcon.Set(stop ? Sym.Stop : Sym.ArrowUp);
        _sendIcon.Foreground = stop ? K.W(1) : CanSend ? K.A("JcAccent") : K.W(0.35);
        _send.ToolTip = stop ? "Stop" : "Send";
        _send.IsEnabled = stop || CanSend;
        _send.Opacity = 1;
        _composer.BorderBrush = _chat.Busy ? K.A("JcAccent", 0.6) : K.W(0.12);
        _composer.BorderThickness = new Thickness(_chat.Busy ? 1 : 0.5);
    }

    private void Render()
    {
        RenderHeader();
        RenderComposer();
        _turns.Children.Clear();
        var turns = _chat.Turns;
        if (turns.Count == 0) _turns.Children.Add(Empty());
        for (var i = 0; i < turns.Count; i++)
        {
            var t = turns[i];
            var gap = i == 0 ? 0 : turns[i - 1].Mine == t.Mine ? 6 : 18;
            var row = t.Mine ? UserBubble(t) : JarvisTurn(t);
            row.Margin = new Thickness(0, gap, 0, 0);
            _turns.Children.Add(row);
        }
        if (_chat.Approval is { } a) { var c = ApprovalCard(a); c.Margin = new Thickness(0, 12, 0, 0); _turns.Children.Add(c); }
        else if (_chat.Clarify is { } q) { var c = ClarifyCard(q); c.Margin = new Thickness(0, 12, 0, 0); _turns.Children.Add(c); }
        _scroll.ScrollToEnd();

        _chips.Children.Clear();
        if (_chat.Attached is { } w)
            K.Add(_chips, Chip(w.Url ?? (w.Title.Length > 0 ? $"{w.App} — {w.Title}" : w.App), null, () => { _chat.Attached = null; Render(); }), 6);
        foreach (var f in _chat.Files.ToList())
        {
            var file = f;
            K.Add(_chips, Chip(f.Name, f.Size is { } s ? Size(s) : null, () => { _chat.Files.Remove(file); Render(); }), 6);
        }
        _chips.Visibility = _chips.Children.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private static string Size(long bytes) => bytes switch
    {
        < 1024 => $"{bytes} B",
        < 1024 * 1024 => $"{bytes / 1024.0:0.#} KB",
        _ => $"{bytes / 1024.0 / 1024.0:0.#} MB",
    };

    private static FrameworkElement Chip(string text, string? detail, Action remove)
    {
        var label = K.T(text, 11, null, K.W(0.88));
        label.MaxWidth = 180;
        var col = K.V(0, label);
        if (detail != null) K.Add(col, K.T(detail, 8.5, null, K.W(0.55)), 0);
        var x = Controls.IconButton(Sym.Plus, 10, K.W(0.55), remove, 18, 18, "Remove");
        x.RenderTransform = new RotateTransform(45, 9, 9);
        var row = K.H(6, new IconView(Sym.Doc, 11, K.W(0.55)), col, x);
        return new Border
        {
            Background = K.W(0.08), BorderBrush = K.W(0.10), BorderThickness = new Thickness(0.5), CornerRadius = new CornerRadius(999),
            Padding = new Thickness(9, 3, 3, 3), Child = row,
        };
    }

    /// A new chat: the orb and the question, like the phone's.
    private static FrameworkElement Empty()
    {
        var orb = new JarvisOrb(52) { Margin = new Thickness(0, 0, 0, 12), HorizontalAlignment = HorizontalAlignment.Center };
        var q = K.T("What’s on your mind?", 18, FontWeights.Medium);
        var a = K.T("A question, a plan, or the next thing to get done.", 12.5, null, K.W(0.55));
        var b = K.T("Drop files here, or press Ctrl+Alt+W to add the window you’re in.", 11, null, K.W(0.35));
        foreach (var t in new[] { q, a, b }) t.HorizontalAlignment = HorizontalAlignment.Center;
        var col = K.V(10, orb, q, a, b);
        col.Margin = new Thickness(0, 36, 0, 0);
        return col;
    }

    private static FrameworkElement UserBubble(ChatTurn t)
    {
        var text = K.T(t.Text, 13.5, null, K.W(0.92), wrap: true);
        text.LineHeight = 19;
        var bubble = new Border
        {
            Background = K.A("JcSoft", 0.13), BorderBrush = K.A("JcSoft", 0.10), BorderThickness = new Thickness(0.5),
            CornerRadius = new CornerRadius(20), Padding = new Thickness(15, 10, 15, 10), Child = text,
            HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(60, 0, 0, 0),
        };
        return bubble;
    }

    private static FrameworkElement JarvisTurn(ChatTurn t)
    {
        var col = K.V(9, K.H(6, new IconView(Sym.Sparkles, 12, K.A("JcAccent")), K.T("Jarvis", 12, FontWeights.Medium, K.W(0.8))));
        if (t.Reasoning.Length > 0)
        {
            var thinking = t.Streaming && t.Text.Length == 0;
            var r = K.H(6, new IconView(Sym.Sparkles, 11, thinking ? K.A("JcAccent") : K.W(0.55)), K.T(thinking ? "Thinking…" : "Thought process", 11, FontWeights.Medium, thinking ? K.A("JcAccent") : K.W(0.55)));
            K.Add(col, K.Rounded(r, K.A("JcAccent", 0.04), 9, 0, K.A("JcAccent", 0.10)).Also(b => b.Padding = new Thickness(10, 6, 10, 6)), 9);
        }
        if (t.Tools is { Count: > 0 } tools)
        {
            var box = new StackPanel();
            for (var i = 0; i < tools.Count; i++)
            {
                var done = !t.Streaming || i < tools.Count - 1 || t.Text.Length > 0;
                var mark = new Grid { Width = 13, Height = 13, Margin = new Thickness(0, 1, 0, 0), VerticalAlignment = VerticalAlignment.Top };
                if (done) mark.Children.Add(K.Glyph("", 11, K.A("JcAccent")));
                else mark.Children.Add(new JcLoader { Size = 10, Foreground = K.W(0.9) });
                K.Add(box, K.H(7, mark, K.T(tools[i], 11.5, FontWeights.Medium, K.W(0.92), mono: true)), 8);
            }
            K.Add(col, K.Rounded(box, K.W(0.035), 12, 10, K.W(0.06)), 9);
        }
        if (t.Text.Length > 0)
        {
            var text = K.T(t.Text, 13.5, null, K.W(0.92), wrap: true);
            text.LineHeight = 19;
            K.Add(col, text, 9);
        }
        else if (t.Streaming) K.Add(col, Dots(), 9);
        if (t.Error is { } e)
        {
            var err = new DockPanel { Background = K.A("JcDanger", 0.08) };
            var bar = new Border { Width = 2, Background = K.A("JcDanger") };
            DockPanel.SetDock(bar, Dock.Left);
            err.Children.Add(bar);
            var msg = K.T(e, 12, null, K.A("JcDanger"), wrap: true);
            msg.Margin = new Thickness(9);
            err.Children.Add(msg);
            K.Add(col, new Border { CornerRadius = new CornerRadius(6), ClipToBounds = true, Child = err }, 9);
        }
        if (t.Stopped) K.Add(col, K.T("Stopped", 11.5, null, K.W(0.55)), 9);
        return col;
    }

    private static FrameworkElement Dots()
    {
        var row = K.H(5);
        for (var i = 0; i < 3; i++)
        {
            var dot = new Ellipse { Width = 6, Height = 6, Fill = K.W(0.55) };
            var a = new System.Windows.Media.Animation.DoubleAnimation(0.25, 1, TimeSpan.FromSeconds(0.45))
            {
                AutoReverse = true, RepeatBehavior = System.Windows.Media.Animation.RepeatBehavior.Forever, BeginTime = TimeSpan.FromSeconds(i * 0.15),
            };
            dot.BeginAnimation(OpacityProperty, a);
            K.Add(row, dot, 5);
        }
        row.Margin = new Thickness(0, 3, 0, 3);
        return row;
    }

    private FrameworkElement ApprovalCard(ChatApproval a)
    {
        var title = PendingCard.Title(Sym.Lock, a.Description.Length > 0 ? a.Description : "Jarvis wants to run this");
        var cmd = K.Rounded(K.T(a.Command, 11, null, K.W(1), mono: true, wrap: true), K.W(0.07), 8, 8);
        var buttons = K.H(8,
            Controls.IslandButton("Allow once", "JcSysGreen", () => _ = _chat.AnswerApprovalAsync(ChatApproval.Choice.once)),
            Controls.IslandButton("This chat", "JcAccent", () => _ = _chat.AnswerApprovalAsync(ChatApproval.Choice.session)),
            Controls.IslandButton("Deny", "JcSysRed", () => _ = _chat.AnswerApprovalAsync(ChatApproval.Choice.deny)));
        var card = new Border { Child = K.V(8, title, cmd, buttons) };
        PendingCard.Dress(card);
        return card;
    }

    private FrameworkElement ClarifyCard(ChatClarify c)
    {
        var col = K.V(8, PendingCard.Title(Sym.BubbleLeft, "Jarvis has a question"), K.T(c.Question, 12, FontWeights.Medium, K.W(1), wrap: true));
        var row = new WrapPanel();
        foreach (var choice in c.Choices)
        {
            var answer = choice;
            var chip = new Tap(K.T(choice, 11, FontWeights.Medium), PressLook.Dim)
            {
                Background = K.W(0.08), CornerRadius = new CornerRadius(999), Padding = new Thickness(8, 4, 8, 4), Margin = new Thickness(0, 0, 6, 6),
            };
            chip.Click += () => _ = _chat.AnswerClarifyAsync(answer);
            row.Children.Add(chip);
        }
        K.Add(col, row, 8);
        var card = new Border { Child = col };
        PendingCard.Dress(card);
        return card;
    }
}

internal static class ElementExtensions
{
    public static T Also<T>(this T e, Action<T> f)
    {
        f(e);
        return e;
    }
}
