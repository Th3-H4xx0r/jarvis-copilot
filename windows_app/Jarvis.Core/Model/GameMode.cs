using System.Text.Json.Nodes;
using Jarvis.Core.Link;

namespace Jarvis.Core.Model;

/// jc-client's game mode (C3): on while a fullscreen window is in front or an anti-cheat game runs.
public sealed record GameMode(bool On, string Reason, bool AntiCheat)
{
    public static readonly GameMode Off = new(false, "", false);

    /// Reads `{on, reason, anticheat}` (the hello's `game_mode` or the broadcast itself).
    public static GameMode FromJson(JsonNode? node)
    {
        if (node is not JsonObject o) return Off;
        return new GameMode(J.B(o["on"]), J.S(o["reason"]), J.B(o["anticheat"]));
    }
}
