using System.Text.Json.Nodes;
using Jarvis.Core.Http;
using Jarvis.Core.Link;

namespace Jarvis.Core.Holo;

public enum HoloFailureKind { Off, TooLarge, NotReachable, Server }

/// Why a Holo Drop call failed (port of `HoloFailure`): 409 = switched off, 413 = too big.
public sealed class HoloFailure : Exception
{
    public HoloFailureKind Kind { get; }
    public int Status { get; }
    public string Text { get; }

    public HoloFailure(HoloFailureKind kind, int status = 0, string text = "") : base(Describe(kind, status, text))
    {
        Kind = kind;
        Status = status;
        Text = text;
    }

    private static string Describe(HoloFailureKind kind, int status, string text) => kind switch
    {
        HoloFailureKind.Off => "Holo Drop is off",
        HoloFailureKind.TooLarge => "Too big to send through Jarvis",
        HoloFailureKind.NotReachable => "Jarvis isn't reachable",
        _ => text.Length == 0 ? $"The server said {status}" : text,
    };

    public static HoloFailure From(ApiException e) => e.Status switch
    {
        409 => new HoloFailure(HoloFailureKind.Off, 409),
        413 => new HoloFailure(HoloFailureKind.TooLarge, 413),
        0 => new HoloFailure(HoloFailureKind.NotReachable),
        _ => new HoloFailure(HoloFailureKind.Server, e.Status, e.Error),
    };
}

/// Holo Drop's calls to the Jarvis server (port of `HoloDropAPI`), over jc-client's loopback
/// proxy through `ApiClient`, which adds the paired session.
public sealed class HoloDropApi
{
    public ApiClient Client { get; }

    public HoloDropApi(ApiClient client) => Client = client;

    private const string B = HoloWire.Base;

    private static async Task<JsonObject> Call(Func<Task<JsonObject>> call)
    {
        try { return await call().ConfigureAwait(false); }
        catch (ApiException e) { throw HoloFailure.From(e); }
        catch (HttpRequestException) { throw new HoloFailure(HoloFailureKind.NotReachable); }
        catch (IOException) { throw new HoloFailure(HoloFailureKind.NotReachable); }
    }

    public async Task<IReadOnlyList<HoloDevice>> DevicesAsync() =>
        HoloDevice.List(await Call(() => Client.GetAsync(B + "/devices", TimeSpan.FromSeconds(8))).ConfigureAwait(false));

    public async Task<HoloDropRecord?> SendInlineAsync(JsonObject body)
    {
        var reply = await Call(() => Client.PostAsync(B + "/drops", body, TimeSpan.FromSeconds(20))).ConfigureAwait(false);
        return HoloDropRecord.FromJson(J.Obj(reply["drop"]));
    }

    /// Streams the file from disk (big videos never sit in memory).
    public async Task<HoloDropRecord?> UploadAsync(string file, HoloKind kind, string target, HoloAction? action,
        HoloPosition? position = null, string? name = null)
    {
        var mime = HoloKinds.Mime(file);
        var path = HoloWire.UploadPath(kind, target, name ?? Path.GetFileName(file), mime, action, position);
        await using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read, 81920, useAsync: true);
        var reply = await Call(() => Client.UploadAsync(path, stream, mime, TimeSpan.FromSeconds(600))).ConfigureAwait(false);
        return HoloDropRecord.FromJson(J.Obj(reply["drop"]));
    }

    public async Task<HoloDropRecord?> DropAsync(string id)
    {
        var reply = await Call(() => Client.GetAsync(B + "/drops/" + Uri.EscapeDataString(id), TimeSpan.FromSeconds(8))).ConfigureAwait(false);
        var drop = J.Obj(reply["drop"]);
        return HoloDropRecord.FromJson(drop.Count == 0 ? reply : drop);
    }

    /// The drop's bytes, downloaded to a temporary file under `tempRoot` (streamed to disk).
    public async Task<string> ContentAsync(string id, string tempRoot)
    {
        var folder = Path.Combine(tempRoot, HoloTemp.Prefix + "dl-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        var file = Path.Combine(folder, "payload");
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(600));
        try
        {
            await using var body = await Client.DownloadAsync(B + "/drops/" + Uri.EscapeDataString(id) + "/content", cts.Token).ConfigureAwait(false);
            await using var output = new FileStream(file, FileMode.CreateNew, FileAccess.Write, FileShare.None, 81920, useAsync: true);
            await body.CopyToAsync(output, cts.Token).ConfigureAwait(false);
            return file;
        }
        catch (ApiException e)
        {
            Discard(folder);
            throw HoloFailure.From(e);
        }
        catch (Exception e) when (e is HttpRequestException or IOException or OperationCanceledException)
        {
            Discard(folder);
            throw new HoloFailure(HoloFailureKind.NotReachable);
        }
    }

    private static void Discard(string folder)
    {
        try { Directory.Delete(folder, true); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    public async Task LandedAsync(string id, HoloOutcome outcome, string? error = null)
    {
        if (id.Length == 0) return;
        try
        {
            await Client.PostAsync(B + "/drops/" + Uri.EscapeDataString(id) + "/landed", HoloWire.Landed(outcome, error),
                TimeSpan.FromSeconds(20)).ConfigureAwait(false);
        }
        catch (ApiException) { }
    }

    public async Task<IReadOnlyList<HoloDropRecord>> PendingAsync()
    {
        var reply = await Call(() => Client.GetAsync(B + "/pending", TimeSpan.FromSeconds(10))).ConfigureAwait(false);
        return J.Arr(reply["drops"]).Select(HoloDropRecord.FromJson).OfType<HoloDropRecord>().ToList();
    }

    public Task AdvertiseLanAsync(string url, string token, DateTimeOffset expires) =>
        Call(() => Client.PostAsync(B + "/lan", HoloWire.LanAdvert(url, token, expires), TimeSpan.FromSeconds(10)));

    /// Withdraws the LAN advert. ApiClient has no DELETE (the Mac sends `DELETE /lan`), so this
    /// posts an advert that expired at the epoch: the server's `lan_for` then hides it the same way.
    public async Task ClearLanAsync()
    {
        try
        {
            await Client.PostAsync(B + "/lan", new JsonObject { ["url"] = "", ["token"] = "", ["expires"] = 1 },
                TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        }
        catch (ApiException) { }
    }

    public async Task AnswerScreenAsync(string request, JsonObject report)
    {
        try
        {
            await Client.PostAsync(B + "/screen/" + Uri.EscapeDataString(request), report, TimeSpan.FromSeconds(3)).ConfigureAwait(false);
        }
        catch (ApiException) { }
    }

    /// Holo Drop's switch from `/api/power`: null when the server has no such row (no Holo Drop
    /// there). Throws when it can't be read (unknown counts as on).
    public async Task<bool?> PowerEnabledAsync() =>
        HoloEnabled(await Call(() => Client.GetAsync("/api/power", TimeSpan.FromSeconds(10))).ConfigureAwait(false));

    public static bool? HoloEnabled(JsonObject reply)
    {
        var row = J.Arr(reply["integrations"]).FirstOrDefault(r => J.S(r["id"]) == "holo-drop");
        if (row == null) return null;
        return row["enabled"] == null || J.B(row["enabled"]);
    }

    /// Wait (polling every 600 ms) until the drop lands or `timeout` passes.
    public async Task<HoloDropRecord?> WaitLandedAsync(string id, TimeSpan timeout, CancellationToken ct = default)
    {
        var until = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < until && !ct.IsCancellationRequested)
        {
            try { await Task.Delay(600, ct).ConfigureAwait(false); }
            catch (OperationCanceledException) { return null; }
            try
            {
                if (await DropAsync(id).ConfigureAwait(false) is { } d && (d.State is "landed" or "failed" || d.Outcome.Length > 0)) return d;
            }
            catch (HoloFailure) { }
        }
        return null;
    }
}
