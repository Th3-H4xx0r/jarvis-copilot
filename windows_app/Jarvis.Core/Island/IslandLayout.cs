namespace Jarvis.Core.Island;

/// The island's sizes in DIPs. The Agents tab is as tall as what it holds, up to MaxHeight.
public static class IslandLayout
{
    public const double RowHeight = 58, TabsHeight = 26, Header = 44, MaxHeight = 500, Width = 460;
    public const double CompactWidth = 200, CompactHeight = 32;
    public const double ChatHeight = 480, MusicHeight = 190, VoiceHeight = 260;
    public const int MaxRows = 6;

    public static double AgentsHeight(int sessions, PendingKind? pending, bool flash)
    {
        var h = TabsHeight + Header + Math.Min(sessions, MaxRows) * RowHeight
            + pending switch { PendingKind.Question => 240, PendingKind.Approval => 160, _ => 0 }
            + (flash ? 58 : 0) + 16;
        return Math.Min(h, MaxHeight);
    }

    public static double Height(IslandTab tab, int sessions, PendingKind? pending, bool flash) => tab switch
    {
        IslandTab.Agents => AgentsHeight(sessions, pending, flash),
        IslandTab.Chat => ChatHeight,
        IslandTab.Music => MusicHeight,
        _ => VoiceHeight,
    };
}

/// When the compact tab stays up: while something needs you, while agents work only if he asked
/// for that, or always unless he turned on hiding when idle (the Mac's IslandVisibility).
public static class IslandVisibility
{
    public static bool KeepsTab(bool needsYou, bool working, bool showWhileWorking, bool hideWhenIdle) =>
        needsYou || (showWhileWorking && working) || !hideWhenIdle;
}

/// What keeps the open island from folding on its own: typing, a request waiting on him, or Voice.
public static class IslandPin
{
    public static bool Holds(bool typing, IslandTab tab, bool pending) => typing || pending || tab == IslandTab.Voice;
}
