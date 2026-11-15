using System.Text.Json.Nodes;
using Jarvis.Core.Link;

namespace Jarvis.Core.Screen;

/// Which shares are this PC's (cross-plan (d)): it lists with its own device id and keeps only
/// shares whose `device_id` is that id, never a Mac's.
public static class ShareSelection
{
    public static IReadOnlyList<(string Id, string Reason)> Mine(JsonObject sharesReply, string deviceId) =>
        J.Arr(sharesReply["shares"])
            .Where(s => J.S(s["status"]) != "ended" && J.S(s["id"]).Length > 0 && J.S(s["device_id"]) == deviceId)
            .Select(s => (J.S(s["id"]), J.S(s["reason"], "anytime")))
            .ToList();

    public static string ListPath(string deviceId) =>
        $"/api/screen/shares?active=1&from=mac&device={Uri.EscapeDataString(deviceId)}";

    public static string SignalPath(string id, int after) =>
        $"/api/screen/shares/{Uri.EscapeDataString(id)}/signal?for=mac&after={after}&wait=25";

    public static string StopPath(string id) => $"/api/screen/shares/{Uri.EscapeDataString(id)}/stop";

    public static string PostPath(string id) => $"/api/screen/shares/{Uri.EscapeDataString(id)}/signal";

    public const string IcePath = "/api/screen/ice";

    public const string DefaultStun = "stun:stun.l.google.com:19302";

    /// Only task shares record a replay (uploaded when the share ends).
    public static bool RecordsReplay(string reason) => reason == "task";
}

public static class FrameSize
{
    /// Fitted inside 1920×1080, aspect kept, both sides even (the VP8/I420 encoder needs that).
    public static (int W, int H) Fit(int w, int h)
    {
        if (w <= 0 || h <= 0) return (2, 2);
        var scale = Math.Min(1.0, Math.Min(1920.0 / w, 1080.0 / h));
        var fw = (int)Math.Floor(w * scale) & ~1;
        var fh = (int)Math.Floor(h * scale) & ~1;
        return (Math.Max(2, fw), Math.Max(2, fh));
    }
}
