namespace Jarvis.Core.Island;

/// When the island is hidden, compact (the black tab) or expanded (port of the Mac's
/// IslandStateMachine). Pure: the presenter calls Tick with the time and what the pointer does.
public sealed class IslandStateMachine
{
    public enum State { Hidden, Compact, Expanded }

    public static readonly TimeSpan ExpandedHold = TimeSpan.FromSeconds(8);
    public static readonly TimeSpan CompactHold = TimeSpan.FromSeconds(6);

    private double _since;

    public State Current { get; private set; } = State.Hidden;

    /// Something needs you (approval, question, finished, error): open.
    public void Attention(double now)
    {
        Current = State.Expanded;
        _since = now;
    }

    /// A session started or is running: at least the compact tab.
    public void Activity(double now)
    {
        if (Current != State.Hidden) return;
        Current = State.Compact;
        _since = now;
    }

    /// A click on the tab, or the toggle shortcut.
    public void Toggle(double now)
    {
        Current = Current == State.Expanded ? State.Compact : State.Expanded;
        _since = now;
    }

    public void Close(double now)
    {
        Current = State.Compact;
        _since = now;
    }

    /// He clicked somewhere else: fold to the tab, whatever kept it open.
    public void ClickedOutside(double now)
    {
        if (Current != State.Expanded) return;
        Current = State.Compact;
        _since = now;
    }

    public void Tick(double now, bool hovering, bool pinned, bool hasSessions)
    {
        switch (Current)
        {
            case State.Expanded:
                if (hovering || pinned) _since = now;
                else if (now - _since > ExpandedHold.TotalSeconds) { Current = State.Compact; _since = now; }
                break;
            case State.Compact:
                if (hovering || hasSessions) _since = now;
                else if (now - _since > CompactHold.TotalSeconds) { Current = State.Hidden; _since = now; }
                break;
            case State.Hidden:
                if (hasSessions) { Current = State.Compact; _since = now; }
                break;
        }
    }
}
