namespace Jarvis.Core.Island;

public enum IslandTab { Agents, Chat, Music, Voice }

public enum PendingKind { Approval, Question }

/// C# enums can't hold members, so the plan's `IslandTab.TabBar` / `IslandTab.ForIslandClick` live here.
public static class IslandTabs
{
    /// The tab row's buttons (Voice opens from the orb, not a tab button).
    public static readonly IReadOnlyList<IslandTab> TabBar = new[] { IslandTab.Agents, IslandTab.Chat, IslandTab.Music };

    /// What a click on the island shows: only the orb opens Voice, so from Voice it's the last other tab.
    public static IslandTab ForIslandClick(IslandTab current, IslandTab last) =>
        current == IslandTab.Voice ? (last == IslandTab.Voice ? IslandTab.Agents : last) : current;

    public static string Title(this IslandTab t) => t switch
    {
        IslandTab.Agents => "Agents",
        IslandTab.Chat => "Chat",
        IslandTab.Music => "Music",
        _ => "Voice",
    };

    /// The `island` message's tab name (the `jarvis_island` skill) → a tab; null for non-tab asks like "recap".
    public static IslandTab? Parse(string raw) => raw switch
    {
        "agents" => IslandTab.Agents,
        "chat" => IslandTab.Chat,
        "music" => IslandTab.Music,
        "voice" => IslandTab.Voice,
        _ => null,
    };
}
