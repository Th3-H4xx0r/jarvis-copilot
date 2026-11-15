using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;

namespace Jarvis.Core.Link;

/// The C1 loopback link: read the endpoint file, connect, send `{"auth":"<token>"}` and nothing
/// else until jc-client's `hello` arrives (2 s), then today's newline JSON. Anything else (a stale
/// file pointing at a stranger's port) is closed and retried with backoff, re-reading the file.
public sealed class JcLink : IJcLink, IAsyncDisposable
{
    public const string DownError = "Jarvis isn't running on this PC";
    public const string DroppedError = "the link dropped";
    public const string TimedOutError = "timed out";
    public static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(15);
    public static readonly TimeSpan HelloTimeout = TimeSpan.FromSeconds(2);
    public static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(2);

    private readonly string _path;
    private readonly TimeProvider _time;
    private readonly Backoff _backoff = new();
    private readonly SemaphoreSlim _write = new(1, 1);
    private readonly ConcurrentDictionary<int, TaskCompletionSource<JsonObject>> _pending = new();
    private readonly CancellationTokenSource _stop = new();
    private readonly object _startLock = new();
    private Task? _loop;
    private NetworkStream? _stream;
    private int _nextId;
    private volatile bool _connected;

    public JcLink(string endpointPath, TimeProvider? time = null)
    {
        _path = endpointPath;
        _time = time ?? TimeProvider.System;
    }

    public bool Connected => _connected;
    public event Action<JsonObject>? Message;
    public event Action<bool>? ConnectionChanged;

    public void Start()
    {
        lock (_startLock)
        {
            _loop ??= Task.Run(() => LoopAsync(_stop.Token));
        }
    }

    public async Task<JsonObject> RequestAsync(JsonObject body, TimeSpan? timeout = null, CancellationToken ct = default)
    {
        var stream = _stream;
        if (!_connected || stream == null) return Fail(DownError);
        var id = Interlocked.Increment(ref _nextId);
        var msg = (JsonObject)body.DeepClone();
        msg["id"] = id;
        var tcs = new TaskCompletionSource<JsonObject>(TaskCreationOptions.RunContinuationsAsynchronously);
        _pending[id] = tcs;
        var bytes = Encoding.UTF8.GetBytes(msg.ToJsonString() + "\n");
        try
        {
            await _write.WaitAsync(ct).ConfigureAwait(false);
            try { await stream.WriteAsync(bytes, ct).ConfigureAwait(false); }
            finally { _write.Release(); }
        }
        catch (OperationCanceledException)
        {
            _pending.TryRemove(id, out _);
            return Fail("cancelled");
        }
        catch (Exception)
        {
            _pending.TryRemove(id, out _);
            return Fail(DroppedError);
        }

        using var delayCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var delay = Task.Delay(timeout ?? DefaultTimeout, _time, delayCts.Token);
        var done = await Task.WhenAny(tcs.Task, delay).ConfigureAwait(false);
        delayCts.Cancel();
        if (done == tcs.Task) return await tcs.Task.ConfigureAwait(false);
        _pending.TryRemove(id, out _);
        return Fail(ct.IsCancellationRequested ? "cancelled" : TimedOutError);
    }

    private static JsonObject Fail(string error) => new() { ["ok"] = false, ["error"] = error };

    private async Task LoopAsync(CancellationToken stop)
    {
        while (!stop.IsCancellationRequested)
        {
            var info = EndpointFile.Read(_path);
            if (info != null)
            {
                try { await SessionAsync(info, stop).ConfigureAwait(false); }
                catch (OperationCanceledException) when (stop.IsCancellationRequested) { return; }
                catch (Exception) { /* fall through to backoff */ }
            }
            try { await Task.Delay(_backoff.Next(), _time, stop).ConfigureAwait(false); }
            catch (OperationCanceledException) { return; }
        }
    }

    /// One connection's life. Returns (or throws) when it ends.
    private async Task SessionAsync(EndpointInfo info, CancellationToken stop)
    {
        using var client = new TcpClient(AddressFamily.InterNetwork) { NoDelay = true };
        using (var connectCts = CancellationTokenSource.CreateLinkedTokenSource(stop))
        {
            connectCts.CancelAfter(ConnectTimeout);
            await client.ConnectAsync(IPAddress.Loopback, info.Port, connectCts.Token).ConfigureAwait(false);
        }
        var stream = client.GetStream();
        var auth = new JsonObject { ["auth"] = info.Token };
        await stream.WriteAsync(Encoding.UTF8.GetBytes(auth.ToJsonString() + "\n"), stop).ConfigureAwait(false);

        var lines = new LineBuffer();
        var chunk = new byte[65536];
        var helloSeen = false;
        using var helloCts = CancellationTokenSource.CreateLinkedTokenSource(stop);
        using var helloTimer = _time.CreateTimer(_ => { try { helloCts.Cancel(); } catch (ObjectDisposedException) { } },
            null, HelloTimeout, Timeout.InfiniteTimeSpan);
        try
        {
            while (true)
            {
                int n;
                try
                {
                    n = await stream.ReadAsync(chunk, helloSeen ? stop : helloCts.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (!stop.IsCancellationRequested)
                {
                    return;   // no hello in time: not jc-client (or a stuck one); close and back off
                }
                if (n <= 0) return;
                foreach (var msg in lines.Push(chunk.AsSpan(0, n)))
                {
                    var type = J.S(msg["type"]);
                    if (!helloSeen)
                    {
                        if (type != "hello") continue;
                        helloSeen = true;
                        helloTimer.Change(Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
                        _stream = stream;
                        _connected = true;
                        _backoff.Reset();
                        ConnectionChanged?.Invoke(true);
                        Message?.Invoke(msg);
                        continue;
                    }
                    if (type == "reply" && msg["id"] is JsonValue idv && idv.TryGetValue<int>(out var id))
                    {
                        if (_pending.TryRemove(id, out var tcs)) tcs.TrySetResult(msg);
                        continue;
                    }
                    Message?.Invoke(msg);
                }
            }
        }
        finally
        {
            var wasUp = _connected && ReferenceEquals(_stream, stream);
            _connected = false;
            _stream = null;
            foreach (var key in _pending.Keys.ToList())
            {
                if (_pending.TryRemove(key, out var tcs)) tcs.TrySetResult(Fail(DroppedError));
            }
            if (wasUp) ConnectionChanged?.Invoke(false);
        }
    }

    public async ValueTask DisposeAsync()
    {
        _stop.Cancel();
        try { _stream?.Close(); } catch { }
        var loop = _loop;
        if (loop != null)
        {
            try { await loop.ConfigureAwait(false); } catch { }
        }
        _stop.Dispose();
    }
}
