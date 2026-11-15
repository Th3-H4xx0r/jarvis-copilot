using System.IO.Compression;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;
using Jarvis.Core.Http;
using Jarvis.Core.Link;

namespace Jarvis.Core.Holo;

/// What a send did (port of `HoloSender.Sent`).
public sealed class HoloSent
{
    /// Server drop ids (to wait on their landing).
    public List<string> Ids { get; } = new();
    /// Landed already (the direct path answers with the outcome).
    public HoloOutcome? Outcome { get; set; }
    /// Why a direct drop didn't land.
    public string? Error { get; set; }
    /// Records of direct drops (already answered here, so their landed frame isn't shown again).
    public List<string> DirectIds { get; } = new();
}

/// Straight to a receiver on the same network (`POST {lan.url}/holo-drop`), no server in the way
/// (port of `HoloDirect`). A short probe first (any HTTP answer to `GET {lan}/holo-drop` means
/// it's there), then the real POST with a long timeout: the phone may be importing into Photos,
/// and giving up early would send the same file again through Jarvis.
public static class HoloDirect
{
    public enum Kind { Landed, Refused, Unreachable }

    public readonly record struct Result(Kind Kind, HoloOutcome? Outcome = null, string? Error = null)
    {
        public static readonly Result Unreachable = new(Kind.Unreachable);
    }

    public static readonly TimeSpan ProbeTimeout = TimeSpan.FromSeconds(1.5);

    public static Uri? Endpoint(HoloLan lan) =>
        Uri.TryCreate(lan.Url.Trim('/') + "/holo-drop", UriKind.Absolute, out var u) ? u : null;

    /// Any HTTP reply, whatever its status, means the receiver is listening.
    public static async Task<bool> ProbeAsync(ApiClient client, HoloLan lan, TimeProvider time, TimeSpan? timeout = null)
    {
        if (!lan.Usable(time.GetUtcNow()) || Endpoint(lan) is not { } u) return false;
        using var cts = new CancellationTokenSource(timeout ?? ProbeTimeout);
        try
        {
            await using var body = await client.DownloadAsync(u.AbsoluteUri, cts.Token).ConfigureAwait(false);
            return true;
        }
        catch (ApiException e) { return e.Status > 0; }
        catch (Exception e) when (e is HttpRequestException or OperationCanceledException or IOException) { return false; }
    }

    /// What a receiver's reply to the POST means. 4xx = turned away before anything happened
    /// (safe to send through Jarvis); a 200 with ok, or anything else = it acted on it.
    public static Result Verdict(int status, JsonObject body)
    {
        if (status == 200 && J.B(body["ok"])) return new Result(Kind.Landed, HoloOutcome.Parse(J.S(body["outcome"])) ?? HoloOutcome.Shown);
        if (status is >= 400 and < 500) return Result.Unreachable;
        var why = J.S(body["error"]);
        return new Result(Kind.Refused, null, why.Length == 0 ? "it couldn't take it" : why);
    }

    public static async Task<Result> SendAsync(ApiClient client, HoloLan lan, JsonObject fields, string? file, JsonObject? inline,
        TimeProvider time, TimeSpan? probeTimeout = null)
    {
        if (!lan.Usable(time.GetUtcNow()) || Endpoint(lan) is not { } u || !await ProbeAsync(client, lan, time, probeTimeout).ConfigureAwait(false))
            return Result.Unreachable;
        var headers = new Dictionary<string, string> { ["X-Holo-Token"] = lan.Token, ["X-Holo-Meta"] = HoloWire.Meta(fields) };
        HttpContent content;
        FileStream? stream = null;
        if (file != null)
        {
            try { stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read, 81920, useAsync: true); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return new Result(Kind.Refused, null, e.Message); }
            content = new StreamContent(stream);
            content.Headers.ContentType = MediaTypeHeaderValue.Parse(J.S(fields["mime"], "application/octet-stream"));
        }
        else
        {
            content = new StringContent((inline ?? new JsonObject()).ToJsonString(), Encoding.UTF8, "application/json");
        }
        try
        {
            var reply = await client.PostAbsoluteAsync(u, content, headers, file == null ? TimeSpan.FromSeconds(30) : TimeSpan.FromHours(6))
                .ConfigureAwait(false);
            return Verdict(200, reply);
        }
        catch (ApiException e)
        {
            // Status 0: the link broke after a good probe, so Jarvis may take it.
            return e.Status == 0 ? Result.Unreachable : Verdict(e.Status, new JsonObject { ["error"] = e.Error });
        }
        finally
        {
            if (stream != null) await stream.DisposeAsync().ConfigureAwait(false);
            content.Dispose();
        }
    }
}

/// Sends what the PC picked to one device (port of `HoloSender`): directly over the LAN when
/// the device listens there and answers the probe within 1.5 s, else through Jarvis (inline for
/// a link or text, an upload for a file). A direct drop is still recorded on the server with
/// `delivered_direct` and the receiver's outcome, so history has it.
public sealed class HoloSender
{
    private readonly HoloDropApi _api;
    private readonly ApiClient _lan;
    private readonly bool _tryDirect;
    private readonly TimeProvider _time;
    private readonly string _tempRoot;

    public HoloSender(HoloDropApi api, ApiClient? lan = null, bool tryDirect = true, TimeProvider? time = null, string? tempRoot = null)
    {
        _api = api;
        _lan = lan ?? api.Client;
        _tryDirect = tryDirect;
        _time = time ?? TimeProvider.System;
        _tempRoot = tempRoot ?? HoloTemp.DefaultRoot;
    }

    /// The direct path's outcome, or null when it went through Jarvis (its landing comes later).
    public async Task<HoloOutcome?> SendAsync(HoloItem item, HoloDevice to, HoloAction action, HoloPosition? at = null) =>
        (await SendDetailedAsync(item, to, action, at).ConfigureAwait(false)).Outcome;

    public async Task<HoloSent> SendDetailedAsync(HoloItem item, HoloDevice to, HoloAction action, HoloPosition? at = null)
    {
        var sent = new HoloSent();
        switch (item)
        {
            case HoloLinkItem l:
                await InlineAsync(HoloKind.Link, l.Url, null, l.Title, to, action, at, sent).ConfigureAwait(false);
                break;
            case HoloTextItem t:
                await InlineAsync(HoloKind.Text, null, t.Value, null, to, action, at, sent).ConfigureAwait(false);
                break;
            case HoloFilesItem f:
                foreach (var file in f.Paths) await FileAsync(file, to, action, at, sent).ConfigureAwait(false);
                break;
        }
        return sent;
    }

    private async Task FileAsync(string file, HoloDevice to, HoloAction action, HoloPosition? at, HoloSent sent)
    {
        var upload = Uploadable(file, _tempRoot);
        try
        {
            var kind = HoloKinds.ForFile(upload);
            var name = Path.GetFileName(upload);
            var mime = HoloKinds.Mime(upload);
            if (_tryDirect && to.Lan is { } lan)
            {
                var result = await HoloDirect.SendAsync(_lan, lan, HoloWire.DirectFields(kind, name, mime, action: action, position: at),
                    upload, null, _time).ConfigureAwait(false);
                if (Record(result, sent) is { } outcome)
                {
                    // Recorded for history; never stored or sent again.
                    await RecordDirectAsync(HoloWire.InlineDrop(kind, to.Id, action: action, position: at, direct: true,
                        name: name, mime: mime, outcome: outcome), sent).ConfigureAwait(false);
                    return;
                }
            }
            if (await _api.UploadAsync(upload, kind, to.Id, action, at, name).ConfigureAwait(false) is { } d) sent.Ids.Add(d.Id);
        }
        finally
        {
            if (upload != file)
            {
                try { Directory.Delete(Path.GetDirectoryName(upload)!, true); }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            }
        }
    }

    private async Task InlineAsync(HoloKind kind, string? url, string? text, string? title, HoloDevice to, HoloAction action,
        HoloPosition? at, HoloSent sent)
    {
        if (_tryDirect && to.Lan is { } lan)
        {
            var body = new JsonObject();
            if (url != null) body["url"] = url;
            if (text != null) body["text"] = text;
            var result = await HoloDirect.SendAsync(_lan, lan, HoloWire.DirectFields(kind, text: text, url: url, title: title,
                action: action, position: at), null, body, _time).ConfigureAwait(false);
            if (Record(result, sent) is { } outcome)
            {
                await RecordDirectAsync(HoloWire.InlineDrop(kind, to.Id, text, url, action, at, title, direct: true, outcome: outcome), sent)
                    .ConfigureAwait(false);
                return;
            }
        }
        if (await _api.SendInlineAsync(HoloWire.InlineDrop(kind, to.Id, text, url, action, at, title)).ConfigureAwait(false) is { } d)
            sent.Ids.Add(d.Id);
    }

    private async Task RecordDirectAsync(JsonObject body, HoloSent sent)
    {
        try
        {
            if (await _api.SendInlineAsync(body).ConfigureAwait(false) is { } d) sent.DirectIds.Add(d.Id);
        }
        catch (HoloFailure) { }   // history only: it already landed
    }

    /// A direct send's result into `sent`: the outcome when it reached the receiver (landed or
    /// not), null when Jarvis should take it instead.
    private static HoloOutcome? Record(HoloDirect.Result result, HoloSent sent)
    {
        switch (result.Kind)
        {
            case HoloDirect.Kind.Landed:
                sent.Outcome = Worse(sent.Outcome, result.Outcome!);
                return result.Outcome;
            case HoloDirect.Kind.Refused:
                sent.Outcome = HoloOutcome.Failed;
                sent.Error = result.Error;
                return HoloOutcome.Failed;
            default:
                return null;
        }
    }

    /// A folder goes as a zip (in its own `HoloDrop-zip-*` temp folder); a file goes as is.
    public static string Uploadable(string path, string? tempRoot = null)
    {
        if (!Directory.Exists(path)) return path;
        var dest = Path.Combine(tempRoot ?? HoloTemp.DefaultRoot, HoloTemp.Prefix + "zip-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dest);
        var name = Path.GetFileName(Path.TrimEndingDirectorySeparator(path));
        var zip = Path.Combine(dest, (name.Length == 0 ? "Folder" : name) + ".zip");
        ZipFile.CreateFromDirectory(path, zip, CompressionLevel.Fastest, includeBaseDirectory: true);
        return zip;
    }

    /// Several files landing: the line names the least complete outcome.
    public static HoloOutcome Worse(HoloOutcome? a, HoloOutcome b)
    {
        if (a == null) return b;
        if (a == HoloOutcome.Failed || b == HoloOutcome.Failed) return HoloOutcome.Failed;
        return a == b ? a : b;
    }
}
