using Jarvis.Core.Gaming;
using Jarvis.Core.Model;
using Jarvis.Core.Prefs;
using Jarvis.Core.State;

namespace Jarvis.Core.Island;

/// The island's behaviour without WPF (the plan's IslandViewModel logic, kept in Core so it is
/// tested on any OS). The window only renders what this says: visible or not, which tab, compact
/// or expanded, and how big. Every attention-open goes through the PresentationGate, so nothing
/// opens over a game; while the gate is closed the island is not visible at all.
public sealed class IslandPresenter
{
    private readonly AppState _state;
    private readonly PresentationGate _gate;
    private readonly PrefsStore _prefs;
    private readonly TimeProvider _time;
    private readonly DateTimeOffset _epoch;
    private bool _lastVisible;
    private IslandStateMachine.State _lastState;

    public IslandPresenter(AppState state, PresentationGate gate, PrefsStore prefs, TimeProvider? time = null)
    {
        _state = state;
        _gate = gate;
        _prefs = prefs;
        _time = time ?? TimeProvider.System;
        _epoch = _time.GetUtcNow();
        state.MomentRaised += OnMoment;
        state.Changed += Refresh;
        state.GameModeChanged += _ => Publish(force: true);
        // Jarvis asking for a tab never takes the keyboard (a stray key could approve something).
        state.IslandRequested += (tab, draft) =>
        {
            if (IslandTabs.Parse(tab) is { } t) Open(t, draft, typing: false);
        };
        Refresh();
    }

    public IslandStateMachine Machine { get; } = new();
    public IslandStateMachine.State State => Machine.Current;
    public IslandTab Tab { get; private set; } = IslandTab.Agents;
    public IslandTab LastTab { get; private set; } = IslandTab.Agents;
    public bool Typing { get; private set; }
    public bool Hovering { get; private set; }
    public string? Draft { get; private set; }
    /// A line shown at the top of the Agents tab the next time it shows (a refusal, say).
    public string? Notice { get; private set; }

    /// Shown at all: not hidden, and nothing fullscreen or game mode in front.
    public bool Visible => State != IslandStateMachine.State.Hidden && !_state.GameMode.On && _gate.CanPresent;

    /// The 1 s hold timer runs only while the island isn't hidden: no idle polling.
    public bool TimerNeeded => State != IslandStateMachine.State.Hidden;

    public PendingKind? Pending => _state.Pending.Count == 0 ? null
        : _state.Pending.Any(p => p.IsQuestion) ? PendingKind.Question : PendingKind.Approval;

    public double Width => State == IslandStateMachine.State.Expanded ? IslandLayout.Width : IslandLayout.CompactWidth;

    public double Height => State == IslandStateMachine.State.Expanded
        ? IslandLayout.Height(Tab, _state.Sessions.Count + _state.Jobs.Count, Pending, _state.Flash != null)
        : IslandLayout.CompactHeight;

    public event Action? Changed;
    /// The window should take the keyboard (the chat composer): the only time it activates.
    public event Action? TypingRequested;

    private double Now => (_time.GetUtcNow() - _epoch).TotalSeconds;

    private bool KeepsTab() => IslandVisibility.KeepsTab(
        needsYou: _state.WaitingCount > 0,
        working: _state.WorkingCount > 0,
        showWhileWorking: _prefs.Get(PrefKeys.IslandShowWhileWorking),
        hideWhenIdle: _prefs.Get(PrefKeys.IslandHideWhenIdle));

    private void Refresh()
    {
        if (KeepsTab()) Machine.Activity(Now);
        Publish(force: true);
    }

    public void OnMoment(Moment m, AgentSession? s)
    {
        if (m == Moment.Started)
        {
            Machine.Activity(Now);
            Publish();
            return;
        }
        _gate.Present("island", () =>
        {
            SetTab(IslandTab.Agents);
            Machine.Attention(Now);
            Publish(force: true);
        });
    }

    /// Jarvis or a shortcut asked for a tab. Typing opens are his own key press, so they take focus.
    public void Open(IslandTab tab, string? draft = null, bool typing = false)
    {
        _gate.Present("island", () =>
        {
            SetTab(tab);
            Draft = draft;
            Machine.Attention(Now);
            Publish(force: true);
            if (typing)
            {
                Typing = true;
                TypingRequested?.Invoke();
            }
        });
    }

    public void ShowNotice(string text)
    {
        Notice = text;
        Publish(force: true);
    }

    public void ClearNotice() => Notice = null;

    /// A click on the tab: open on the last non-Voice tab, or fold.
    public void Click()
    {
        if (State != IslandStateMachine.State.Expanded) SetTab(IslandTabs.ForIslandClick(Tab, LastTab));
        Machine.Toggle(Now);
        Publish(force: true);
    }

    public void SelectTab(IslandTab tab)
    {
        SetTab(tab);
        Publish(force: true);
    }

    public void HoverChanged(bool hovering)
    {
        Hovering = hovering;
        if (hovering && _prefs.Get(PrefKeys.IslandOpenOnHover) && State != IslandStateMachine.State.Expanded)
        {
            SetTab(IslandTabs.ForIslandClick(Tab, LastTab));
            Machine.Attention(Now);
            Publish(force: true);
        }
    }

    public void ClickedOutside()
    {
        if (Typing) return;
        Machine.ClickedOutside(Now);
        Publish();
    }

    public void EndTyping()
    {
        Typing = false;
        Draft = null;
    }

    public void Close()
    {
        Typing = false;
        Machine.Close(Now);
        Publish(force: true);
    }

    /// The foreground window changed: re-read whether the island may draw (a fullscreen game just
    /// came forward, or left).
    public void Recheck() => Publish();

    public void Tick()
    {
        Machine.Tick(Now, Hovering, IslandPin.Holds(Typing, Tab, _state.Pending.Count > 0), KeepsTab());
        Publish();
    }

    private void SetTab(IslandTab tab)
    {
        if (Tab != IslandTab.Voice) LastTab = Tab;
        Tab = tab;
    }

    private void Publish(bool force = false)
    {
        var visible = Visible;
        if (!force && visible == _lastVisible && State == _lastState) return;
        _lastVisible = visible;
        _lastState = State;
        Changed?.Invoke();
    }
}
