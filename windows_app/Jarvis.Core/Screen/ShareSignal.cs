using System.Text.Json.Nodes;
using Jarvis.Core.Link;

namespace Jarvis.Core.Screen;

/// A signalling message from a viewer (the iPhone/web viewer offers; the PC answers).
public abstract record ShareInbound(string Viewer)
{
    public sealed record Offer(string Viewer, string Sdp) : ShareInbound(Viewer);
    public sealed record Candidate(string Viewer, string Cand, int MLine, string? Mid) : ShareInbound(Viewer);
    public sealed record Bye(string Viewer) : ShareInbound(Viewer);
}

/// The Mac's signalling shapes, unchanged (ScreenShareSession.swift), so every viewer works.
public static class ShareSignal
{
    public static JsonObject Answer(string sdp, string viewer) =>
        new() { ["type"] = "answer", ["sdp"] = sdp, ["viewer"] = viewer };

    public static JsonObject Candidate(string cand, int mline, string? mid, string viewer)
    {
        var c = new JsonObject { ["candidate"] = cand, ["sdpMLineIndex"] = mline };
        if (mid != null) c["sdpMid"] = mid;
        return new JsonObject { ["type"] = "candidate", ["candidate"] = c, ["viewer"] = viewer };
    }

    /// What's posted: the body plus `from: "mac"` (the PC uses the Mac's sharer role).
    public static JsonObject Outbound(JsonObject body)
    {
        var m = (JsonObject)body.DeepClone();
        m["from"] = "mac";
        return m;
    }

    /// One long-poll answer: the viewers' messages after `seq`, the new cursor, and whether the
    /// share ended (status "ended", or the server said 404/410 through `_status`).
    public static (int Seq, IReadOnlyList<ShareInbound> Inbound, bool Ended) Batch(JsonObject reply, int seq)
    {
        var inbound = new List<ShareInbound>();
        foreach (var m in J.Arr(reply["messages"]))
        {
            seq = Math.Max(seq, J.I(m["seq"]));
            if (Parse(m) is { } i) inbound.Add(i);
        }
        var status = J.I(reply["_status"]);
        return (seq, inbound, J.S(reply["status"]) == "ended" || status is 404 or 410);
    }

    public sealed record IceServer(IReadOnlyList<string> Urls, string? Username, string? Credential);

    /// `GET /api/screen/ice` → its servers (urls as a string or a list), else the default STUN.
    public static IReadOnlyList<IceServer> IceServers(JsonObject? reply)
    {
        var o = new List<IceServer>();
        foreach (var s in J.Arr(reply?["ice_servers"]))
        {
            var urls = s["urls"] is JsonArray a ? a.Select(u => J.S(u)).Where(u => u.Length > 0).ToList()
                : J.S(s["urls"]) is { Length: > 0 } one ? new List<string> { one } : new List<string>();
            if (urls.Count == 0) continue;
            o.Add(new IceServer(urls, J.StrOrNull(s["username"]), J.StrOrNull(s["credential"])));
        }
        if (o.Count == 0) o.Add(new IceServer(new[] { ShareSelection.DefaultStun }, null, null));
        return o;
    }

    /// Only messages from a viewer count; our own echoes and unknown types are null.
    public static ShareInbound? Parse(JsonObject msg)
    {
        if (J.S(msg["from"]) != "viewer") return null;
        var viewer = J.S(msg["viewer"]);
        switch (J.S(msg["type"]))
        {
            case "offer":
                return new ShareInbound.Offer(viewer, J.S(msg["sdp"]));
            case "candidate":
            {
                var c = J.Obj(msg["candidate"]);
                return new ShareInbound.Candidate(viewer, J.S(c["candidate"]), J.I(c["sdpMLineIndex"]), J.StrOrNull(c["sdpMid"]));
            }
            case "bye":
                return new ShareInbound.Bye(viewer);
            default:
                return null;
        }
    }
}

/// A viewer's candidates that arrive before its offer: held (≤64 per viewer, ≤16 viewers) until
/// the offer makes its peer, so a fast viewer's first candidates aren't lost.
public sealed class EarlyCandidates
{
    public const int PerViewer = 64;
    public const int MaxViewers = 16;

    private readonly List<(string Viewer, List<ShareInbound.Candidate> Items)> _held = new();

    public int ViewerCount => _held.Count;

    public void Hold(ShareInbound.Candidate c)
    {
        var i = _held.FindIndex(h => h.Viewer == c.Viewer);
        if (i < 0)
        {
            _held.Add((c.Viewer, new List<ShareInbound.Candidate>()));
            i = _held.Count - 1;
        }
        if (_held[i].Items.Count < PerViewer) _held[i].Items.Add(c);
        // A viewer that never offers (it left at once): drop the oldest other viewer.
        while (_held.Count > MaxViewers)
        {
            var stale = _held.FindIndex(h => h.Viewer != c.Viewer);
            _held.RemoveAt(stale);
        }
    }

    public IReadOnlyList<ShareInbound.Candidate> Take(string viewer)
    {
        var i = _held.FindIndex(h => h.Viewer == viewer);
        if (i < 0) return Array.Empty<ShareInbound.Candidate>();
        var items = _held[i].Items;
        _held.RemoveAt(i);
        return items;
    }

    public void Drop(string viewer) => _held.RemoveAll(h => h.Viewer == viewer);

    public void Clear() => _held.Clear();
}
