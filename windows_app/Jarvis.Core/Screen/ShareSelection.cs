using System.Text.Json.Nodes;
using Jarvis.Core.Link;

namespace Jarvis.Core.Screen;

/// Which shares are this PC's (cross-plan (d)): it lists with its own device id and keeps only
/// shares whose `device_id` is that id, never a Mac's.
public static class ShareSelection
{
    /// A "glasses" share is this PC asking the iPhone for the glasses' video (the Jarvis Glasses
    /// camera, GlassesCameraService): nothing to capture, so it's never one of these.
    public static IReadOnlyList<(string Id, string Reason)> Mine(JsonObject sharesReply, string deviceId) =>
        J.Arr(sharesReply["shares"])
            .Where(s => J.S(s["status"]) != "ended" && J.S(s["id"]).Length > 0 && J.S(s["device_id"]) == deviceId
                && J.S(s["reason"]) != "glasses")
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
    /// The largest frame sent: a 1440p / 1600p monitor goes out pixel for pixel (text stays
    /// sharp, like the Mac's share); anything bigger (4K) is fitted inside 2560×1440.
    public const int MaxW = 2560, MaxH = 1600, FitW = 2560, FitH = 1440;

    /// The frame for a `w`×`h` display: native when it fits, else inside 2560×1440 with the
    /// aspect kept; both sides even (the VP8/I420 encoder needs that).
    public static (int W, int H) Fit(int w, int h)
    {
        if (w <= 0 || h <= 0) return (2, 2);
        var scale = w <= MaxW && h <= MaxH ? 1.0 : Math.Min(1.0, Math.Min((double)FitW / w, (double)FitH / h));
        var fw = (int)Math.Floor(w * scale) & ~1;
        var fh = (int)Math.Floor(h * scale) & ~1;
        return (Math.Max(2, fw), Math.Max(2, fh));
    }
}

/// The VP8 encoder's settings for a frame size (Vp8Encoder): ~0.06 bits per pixel at 30 fps,
/// between 2.5 and 10 Mbps (1440p ≈ 6.6 Mbps, 1080p ≈ 3.7 Mbps); up to 8 threads but never more
/// than half the cores; libvpx's realtime speed -6; a keyframe at least every 4 s.
public sealed record Vp8Settings(uint Kbps, uint Threads, int CpuUsed, uint KeyEvery)
{
    public static Vp8Settings For(int w, int h, int cores)
    {
        var kbps = (uint)Math.Clamp(Math.Round((double)w * h * 30 * 0.06 / 1000), 2500, 10_000);
        var threads = (uint)Math.Clamp(cores / 2, 1, 8);
        return new Vp8Settings(kbps, threads, -6, 120);
    }
}
