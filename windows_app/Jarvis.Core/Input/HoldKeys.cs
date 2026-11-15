using Jarvis.Core.Model;

namespace Jarvis.Core.Input;

/// The keys that can be held (push-to-talk, Flow): RightAlt, RightCtrl, F13–F24. Raw Input
/// reports the left/right variants, so these are the exact virtual keys.
public static class HoldKeys
{
    public static readonly IReadOnlyList<string> Choices =
        new[] { "RightAlt", "RightCtrl" }.Concat(Enumerable.Range(13, 12).Select(n => $"F{n}")).ToList();

    public static uint? Vk(string name) => name switch
    {
        "RightAlt" => 0xA5,     // VK_RMENU
        "RightCtrl" => 0xA3,    // VK_RCONTROL
        _ when name.Length is 3 && name[0] == 'F' && int.TryParse(name[1..], out var n) && n is >= 13 and <= 24 => (uint)(0x70 + n - 1),
        _ => null,
    };

    public static string Display(string name) => name switch
    {
        "RightAlt" => "Right Alt",
        "RightCtrl" => "Right Ctrl",
        "" => "Off",
        _ => name,
    };

    /// The push-to-talk key must differ from the Flow key (one key, one job).
    public static string? Problem(string talkKey, string flowKey, bool flowOn) =>
        talkKey.Length > 0 && flowOn && talkKey == flowKey ? $"{Display(talkKey)} is already the Flow key." : null;
}

/// Next/previous session for the shortcuts: walks the sorted list, wrapping, by key.
public sealed class SessionCursor
{
    public string? Key { get; private set; }

    public AgentSession? Current(IReadOnlyList<AgentSession> sessions) =>
        sessions.FirstOrDefault(s => s.Key == Key) ?? sessions.FirstOrDefault();

    public AgentSession? Move(IReadOnlyList<AgentSession> sessions, int by)
    {
        if (sessions.Count == 0) { Key = null; return null; }
        var i = sessions.ToList().FindIndex(s => s.Key == Key);
        i = i < 0 ? (by > 0 ? 0 : sessions.Count - 1) : ((i + by) % sessions.Count + sessions.Count) % sessions.Count;
        Key = sessions[i].Key;
        return sessions[i];
    }
}
