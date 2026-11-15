using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Jarvis.Core.Link;

namespace Jarvis.Core.Holo;

/// The direct receiver (port of `HoloLanReceiver`): a tiny HTTP server on a random port that
/// takes `POST /holo-drop` with `X-Holo-Token` (one of the tokens it advertised through Jarvis)
/// and `X-Holo-Meta` (base64 JSON of the drop's fields); the body is the bytes, or JSON for a
/// link or text. Replies `{ok, outcome}` once the drop has landed. The PC binds `0.0.0.0` (and
/// only once the firewall rule exists); tests bind loopback.
public sealed class HoloLanServer : IDisposable
{
    public const int MaxHead = HoloHttp.MaxHead, InlineCap = 2 * 1024 * 1024;
    public const long FileCap = 16L * 1024 * 1024 * 1024;
    /// A connection that sends nothing for this long is dropped.
    public static readonly TimeSpan Idle = TimeSpan.FromSeconds(30);

    private readonly object _lock = new();
    private readonly TimeProvider _time;
    private readonly string _tempRoot;
    private readonly List<(string Token, DateTimeOffset Until)> _tokens = new();
    private TcpListener? _listener;
    private CancellationTokenSource? _cts;

    public HoloLanServer(TimeProvider? time = null, string? tempRoot = null)
    {
        _time = time ?? TimeProvider.System;
        _tempRoot = tempRoot ?? HoloTemp.DefaultRoot;
    }

    /// Lands the drop: its fields, the bytes' temp file (null for a link or text), the JSON body.
    /// The temp file's folder is deleted once this returns, so the handler moves what it keeps.
    public Func<JsonObject, string?, JsonObject, Task<HoloOutcome>>? OnDrop { get; set; }

    public int? Port { get; private set; }

    public bool Running { get { lock (_lock) return _listener != null; } }

    /// Starts listening (once) and answers the port.
    public int Start(IPAddress? bind = null)
    {
        lock (_lock)
        {
            if (_listener != null && Port is { } p) return p;
            var l = new TcpListener(bind ?? IPAddress.Any, 0);
            l.Start();
            _listener = l;
            _cts = new CancellationTokenSource();
            Port = ((IPEndPoint)l.LocalEndpoint).Port;
            var ct = _cts.Token;
            _ = Task.Run(() => AcceptLoop(l, ct));
            return Port.Value;
        }
    }

    public void Stop()
    {
        TcpListener? l;
        CancellationTokenSource? cts;
        lock (_lock)
        {
            l = _listener;
            cts = _cts;
            _listener = null;
            _cts = null;
            Port = null;
            _tokens.Clear();
        }
        cts?.Cancel();
        try { l?.Stop(); } catch (SocketException) { }
        cts?.Dispose();
    }

    public void Dispose() => Stop();

    /// A fresh token, good for `validFor`; the older ones stay good until their own time runs
    /// out (a sender may have just read the last advert).
    public string NewToken(TimeSpan validFor)
    {
        var token = Convert.ToHexString(RandomNumberGenerator.GetBytes(24)).ToLowerInvariant();
        lock (_lock)
        {
            var now = _time.GetUtcNow();
            _tokens.RemoveAll(t => t.Until <= now);
            _tokens.Add((token, now + validFor));
        }
        return token;
    }

    public bool Accepts(string? token)
    {
        if (token == null) return false;
        lock (_lock)
        {
            var now = _time.GetUtcNow();
            return _tokens.Any(t => t.Until > now && HoloHttp.SameToken(t.Token, token));
        }
    }

    private async Task AcceptLoop(TcpListener listener, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            TcpClient c;
            try { c = await listener.AcceptTcpClientAsync(ct).ConfigureAwait(false); }
            catch (Exception e) when (e is OperationCanceledException or SocketException or ObjectDisposedException) { return; }
            _ = Task.Run(() => ServeAsync(c, ct), CancellationToken.None);
        }
    }

    private async Task ServeAsync(TcpClient client, CancellationToken stop)
    {
        string? folder = null;
        using (client)
        {
            try
            {
                var stream = client.GetStream();
                using var idle = CancellationTokenSource.CreateLinkedTokenSource(stop);
                async Task<int> ReadAsync(byte[] buf, int offset, int count)
                {
                    idle.CancelAfter(Idle);
                    return await stream.ReadAsync(buf.AsMemory(offset, count), idle.Token).ConfigureAwait(false);
                }
                async Task ReplyAsync(int status, JsonObject json)
                {
                    var bytes = HoloHttp.Response(status, json);
                    await stream.WriteAsync(bytes, stop).ConfigureAwait(false);
                    await stream.FlushAsync(stop).ConfigureAwait(false);
                    client.Client.Shutdown(SocketShutdown.Send);
                }
                JsonObject Err(string why) => new() { ["ok"] = false, ["error"] = why };

                // The head.
                var buffer = new byte[MaxHead + 1];
                var filled = 0;
                int? end;
                while ((end = HoloHttp.HeadEnd(buffer, filled)) == null)
                {
                    if (filled >= buffer.Length) { await ReplyAsync(400, Err("head too large")); return; }
                    var n = await ReadAsync(buffer, filled, buffer.Length - filled);
                    if (n <= 0) return;
                    filled += n;
                }
                var head = HoloHttp.Parse(buffer.AsSpan(0, end.Value));
                if (head == null) { await ReplyAsync(400, Err("bad request")); return; }
                if (head.Path != "/holo-drop") { await ReplyAsync(404, Err("not found")); return; }
                if (head.Method != "POST") { await ReplyAsync(405, Err("POST only")); return; }
                if (!Accepts(head.Headers.GetValueOrDefault("x-holo-token"))) { await ReplyAsync(401, Err("bad token")); return; }
                if (head.ContentLength is not { } length || length < 0) { await ReplyAsync(411, Err("Content-Length required")); return; }
                var fields = HoloWire.DecodeMeta(head.Headers.GetValueOrDefault("x-holo-meta")) ?? new JsonObject();
                var inlineKind = (HoloKinds.Parse(J.S(fields["kind"])) ?? HoloKind.File).Inline();
                if (length > (inlineKind ? InlineCap : FileCap)) { await ReplyAsync(413, Err("too large")); return; }

                // The body: into memory for a link or text, else streamed to a temp file.
                Stream sink;
                string? file = null;
                if (inlineKind)
                {
                    sink = new MemoryStream();
                }
                else
                {
                    folder = Path.Combine(_tempRoot, HoloTemp.Prefix + "lan-" + Guid.NewGuid().ToString("N"));
                    try
                    {
                        Directory.CreateDirectory(folder);
                        file = Path.Combine(folder, "payload");
                        sink = new FileStream(file, FileMode.CreateNew, FileAccess.Write, FileShare.None, 81920, useAsync: true);
                    }
                    catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                    {
                        await ReplyAsync(500, Err("can't write"));
                        return;
                    }
                }
                await using (sink)
                {
                    if (head.Headers.TryGetValue("expect", out var expect) && expect.Equals("100-continue", StringComparison.OrdinalIgnoreCase))
                        await stream.WriteAsync("HTTP/1.1 100 Continue\r\n\r\n"u8.ToArray(), stop).ConfigureAwait(false);
                    var remaining = length;
                    var rest = (int)Math.Min(filled - end.Value, remaining);
                    if (rest > 0)
                    {
                        await sink.WriteAsync(buffer.AsMemory(end.Value, rest), stop).ConfigureAwait(false);
                        remaining -= rest;
                    }
                    var chunk = new byte[256 * 1024];
                    while (remaining > 0)
                    {
                        var n = await ReadAsync(chunk, 0, (int)Math.Min(chunk.Length, remaining));
                        if (n <= 0) return;   // the sender gave up
                        await sink.WriteAsync(chunk.AsMemory(0, n), stop).ConfigureAwait(false);
                        remaining -= n;
                    }
                    await sink.FlushAsync(stop).ConfigureAwait(false);
                }
                var inline = new JsonObject();
                if (inlineKind)
                {
                    try { inline = JsonNode.Parse(((MemoryStream)sink).ToArray()) as JsonObject ?? new JsonObject(); }
                    catch (JsonException) { }
                }

                // Land it (no idle timer: the receiver may be showing a prompt).
                HoloOutcome outcome;
                try { outcome = OnDrop is { } h ? await h(fields, file, inline).ConfigureAwait(false) : HoloOutcome.Failed; }
                catch (Exception) { outcome = HoloOutcome.Failed; }
                var failed = outcome == HoloOutcome.Failed;
                DeleteFolder(folder);
                folder = null;
                await ReplyAsync(failed ? 500 : 200, new JsonObject { ["ok"] = !failed, ["outcome"] = outcome.Wire });
            }
            catch (Exception e) when (e is IOException or SocketException or OperationCanceledException or ObjectDisposedException)
            {
                // The link broke or went idle: nothing landed, nothing to answer.
            }
            finally
            {
                DeleteFolder(folder);
            }
        }
    }

    private static void DeleteFolder(string? folder)
    {
        if (folder == null) return;
        try { if (Directory.Exists(folder)) Directory.Delete(folder, true); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}
