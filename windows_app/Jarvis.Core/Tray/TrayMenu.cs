using System.Text.Json.Nodes;
using Jarvis.Core.Model;
using Jarvis.Core.State;

namespace Jarvis.Core.Tray;

public enum TrayCommand { OpenIsland, HoloDrop, Recap, Settings, KeepAwake, RecordCall, Repair, Logs, Restart, Quit }

public sealed record TrayItem(string Label, TrayCommand? Command = null, bool Enabled = true, bool Header = false,
    bool Separator = false, bool? Checked = null, bool Online = false, string Detail = "")
{
    public static readonly TrayItem Line = new("", Separator: true);
}

/// The tray's right-click menu (the Mac menu bar's): status, roster rows, then actions. Built
/// fresh each time it opens, after the roster is refreshed.
public static class TrayMenu
{
    public static IReadOnlyList<TrayItem> Build(Roster? roster, bool connected, bool keepAwake, bool recording)
    {
        var items = new List<TrayItem>
        {
            new(roster?.StatusLine ?? (connected ? "Connected" : "Jarvis isn't running on this PC"), Enabled: false, Header: true),
        };
        if (roster != null)
            foreach (var r in roster.Rows)
                items.Add(new TrayItem(r.Name, Enabled: false, Header: r.Header, Online: r.Online, Detail: r.Detail));
        items.Add(TrayItem.Line);
        items.Add(new("Open the island", TrayCommand.OpenIsland));
        items.Add(new("Holo Drop…", TrayCommand.HoloDrop, Enabled: connected));
        items.Add(new("Weekly recap", TrayCommand.Recap, Enabled: connected));
        items.Add(new(recording ? "Stop recording the call" : "Record a call", TrayCommand.RecordCall, Enabled: connected));
        items.Add(new("Keep PC awake", TrayCommand.KeepAwake, Enabled: connected, Checked: keepAwake));
        items.Add(new("Settings", TrayCommand.Settings));
        items.Add(TrayItem.Line);
        items.Add(new("Re-pair", TrayCommand.Repair));
        items.Add(new("Logs", TrayCommand.Logs));
        items.Add(new("Restart Jarvis service", TrayCommand.Restart));
        items.Add(new("Quit", TrayCommand.Quit));
        return items;
    }

    /// The commands jc-client does itself (`{"type":"tray","action":…}`).
    public static string? LinkAction(TrayCommand c) => c switch
    {
        TrayCommand.Repair => "repair",
        TrayCommand.Logs => "logs",
        TrayCommand.Restart => "restart",
        _ => null,
    };

    /// Runs a jc-client tray action; null when the command is the app's own.
    public static Task<JsonObject>? RunLinkAction(TrayCommand c, AppState state) =>
        LinkAction(c) is { } action ? state.TrayAsync(action) : null;
}
