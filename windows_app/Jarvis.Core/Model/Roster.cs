using System.Text.Json.Nodes;
using Jarvis.Core.Link;

namespace Jarvis.Core.Model;

public sealed record RosterRow(string Name, string Detail, bool Online, bool Header, string Symbol, string? Image);

/// The tray menu's top half (jc-client's `roster` request).
public sealed record Roster(string Server, bool Connected, IReadOnlyList<RosterRow> Rows)
{
    public string StatusLine => Server.Length == 0 ? "Not paired"
        : Connected ? $"Connected to {Server}" : $"Reconnecting to {Server}…";

    public static Roster FromJson(JsonObject json) => new(
        J.S(json["server"]), J.B(json["connected"]),
        J.Arr(json["rows"]).Select(r => new RosterRow(J.S(r["name"]), J.S(r["detail"]), J.B(r["online"]), J.B(r["header"]),
            J.S(r["symbol"]), J.StrOrNull(r["image"]))).ToList());
}
